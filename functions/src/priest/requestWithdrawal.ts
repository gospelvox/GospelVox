// Priest withdrawal — creates a "pending" withdrawal request, no
// actual bank transfer happens here.
//
// Why "pending" not "completed":
//   The CF debits walletBalance and writes a withdrawal record, but
//   the real bank payout (Razorpay X / manual transfer) happens
//   downstream. The admin payout dashboard (Week 5) flips status
//   to "paid" once the money has actually moved. Calling this
//   "completed" before that would mean lying to priests about where
//   their money is.
//
// Idempotency:
//   The client passes a clientRequestId on every call. We dedupe on
//   it before doing any work — if the same id has already produced
//   a withdrawal, we return the existing record instead of debiting
//   again. Protects against SDK-level retries and unstable networks
//   between the Flutter app and the CF runtime.
//
// Structured errors:
//   We surface failures via HttpsError(code, message, details). The
//   `details.reason` token is the contract the Flutter side
//   string-switches on — keep these stable across deploys.

import {onCall, HttpsError} from "firebase-functions/v2/https";
import * as admin from "firebase-admin";
import {REGION} from "../config/constants";

const db = admin.firestore();

// Limit on the idempotency token. Long enough to fit a UUID v4
// (36) or a Firestore auto-id (20); short enough to reject garbage
// payloads that try to bloat the index.
const MAX_CLIENT_REQUEST_ID_LEN = 64;

export const requestWithdrawal = onCall(
  {region: REGION},
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Must be logged in");
    }

    const uid = request.auth.uid;
    const {amount, clientRequestId} = request.data as {
      amount?: number;
      clientRequestId?: string;
    };

    if (
      typeof amount !== "number" ||
      !Number.isFinite(amount) ||
      amount <= 0 ||
      !Number.isInteger(amount)
    ) {
      throw new HttpsError(
        "invalid-argument",
        "Amount must be a positive integer",
        {reason: "invalid_amount"},
      );
    }

    if (
      typeof clientRequestId !== "string" ||
      clientRequestId.length === 0 ||
      clientRequestId.length > MAX_CLIENT_REQUEST_ID_LEN
    ) {
      throw new HttpsError(
        "invalid-argument",
        "Missing or invalid request id",
        {reason: "invalid_request_id"},
      );
    }

    // ── Idempotency check ──
    // Done before reading the priest doc so a duplicate call short-
    // circuits with minimal work. We don't filter by priestId on
    // the query (single-field indexes are auto-created; composite
    // would need a manual index) — instead we re-check ownership
    // in code after the fetch.
    const dedupeSnap = await db
      .collection("withdrawals")
      .where("clientRequestId", "==", clientRequestId)
      .limit(1)
      .get();

    if (!dedupeSnap.empty) {
      const existing = dedupeSnap.docs[0];
      const existingData = existing.data();
      if (existingData.priestId !== uid) {
        // Same id submitted by a different priest — almost certainly
        // an attempt to forge an idempotency hit.
        throw new HttpsError(
          "permission-denied",
          "Request id conflict",
          {reason: "request_id_conflict"},
        );
      }
      // Return the original result rather than recharging. We re-
      // read the priest doc so the returned balance reflects any
      // settlement writes that happened after the original call.
      const priestSnap = await db.doc(`priests/${uid}`).get();
      const balance = Number(priestSnap.data()?.walletBalance ?? 0);
      return {
        withdrawalId: existing.id,
        newBalance: balance,
        amount: Number(existingData.amount ?? 0),
        deduplicated: true,
      };
    }

    const priestRef = db.doc(`priests/${uid}`);
    const priestDoc = await priestRef.get();

    if (!priestDoc.exists) {
      throw new HttpsError(
        "not-found",
        "Priest profile not found",
        {reason: "priest_not_found"},
      );
    }

    const priestData = priestDoc.data() ?? {};

    if (priestData.status !== "approved" || !priestData.isActivated) {
      throw new HttpsError(
        "failed-precondition",
        "Account must be approved and activated",
        {reason: "account_inactive"},
      );
    }

    const bankAccountName = priestData.bankAccountName as string | undefined;
    const bankAccountNumber = priestData.bankAccountNumber as
      | string
      | undefined;
    const bankIfscCode = priestData.bankIfscCode as string | undefined;

    if (!bankAccountName || !bankAccountNumber || !bankIfscCode) {
      throw new HttpsError(
        "failed-precondition",
        "Bank details are required for withdrawals",
        {reason: "no_bank_details"},
      );
    }

    const settingsDoc = await db.doc("app_config/settings").get();
    const minAmount = Number(
      settingsDoc.data()?.minWithdrawalAmount ?? 100,
    );

    if (amount < minAmount) {
      throw new HttpsError(
        "failed-precondition",
        `Minimum withdrawal is ₹${minAmount}`,
        {reason: "below_minimum", minAmount},
      );
    }

    const currentBalance = Number(priestData.walletBalance ?? 0);
    if (currentBalance < amount) {
      throw new HttpsError(
        "failed-precondition",
        "Insufficient balance",
        {reason: "insufficient_balance"},
      );
    }

    // ── Atomic withdrawal: balance debit, totals bump, audit row,
    //    notification, and the withdrawal doc itself. Either every-
    //    thing writes or nothing does.
    const batch = db.batch();

    batch.update(priestRef, {
      walletBalance: admin.firestore.FieldValue.increment(-amount),
      // Maintained on the priest doc so the wallet page can show
      // lifetime "Withdrawn" without scanning the transaction list.
      totalWithdrawn: admin.firestore.FieldValue.increment(amount),
    });

    const withdrawalRef = db.collection("withdrawals").doc();
    batch.set(withdrawalRef, {
      priestId: uid,
      amount: amount,
      // "pending" until the admin payout dashboard flips it to
      // "paid" after sending the actual bank transfer. "blocked"
      // is the fraud-block path; rejected by manual review.
      status: "pending",
      clientRequestId: clientRequestId,
      bankAccountName,
      bankAccountNumber,
      bankIfscCode,
      bankName: priestData.bankName ?? "",
      upiId: priestData.upiId ?? "",
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
    });

    const txRef = db.collection("wallet_transactions").doc();
    batch.set(txRef, {
      userId: uid,
      type: "withdrawal",
      coins: -amount,
      description: `Withdrawal to ${priestData.bankName ?? "bank"}`,
      withdrawalId: withdrawalRef.id,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
    });

    const notifRef = db.collection("notifications").doc();
    batch.set(notifRef, {
      userId: uid,
      type: "withdrawal_requested",
      title: "Withdrawal Requested",
      // Honest copy: the request is in the queue, not en route to
      // the bank yet. The "Withdrawal Processed" notification
      // lands separately when the admin marks the payout paid.
      body:
        `Your withdrawal request of ₹${amount} has been ` +
        "submitted. It will be processed within 1-3 business days.",
      isRead: false,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
    });

    await batch.commit();

    const newBalance = currentBalance - amount;

    return {
      withdrawalId: withdrawalRef.id,
      newBalance: newBalance,
      amount: amount,
      deduplicated: false,
    };
  },
);
