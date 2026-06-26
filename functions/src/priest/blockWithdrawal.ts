// Admin "block & refund" — moved server-side so the refund is SAFE.
//
// Why this exists (vs the old client batch write):
//   The client batch did a blind `walletBalance += amount` with no
//   check on the current status. Two taps / two devices / a reload
//   between taps could refund the same payout twice, and a paid
//   withdrawal could be refunded after the money had already been
//   wired. Rules whitelist FIELDS, not status transitions, so they
//   can't prevent it. This function runs the whole thing in a
//   transaction that:
//     • is IDEMPOTENT — a second call sees status === "blocked" and
//       refunds nothing (kills the double-refund);
//     • REJECTS blocking a "paid" payout (can't claw back sent money);
//     • writes the offsetting `wallet_transactions` refund row so the
//       priest's ledger reconciles with their balance (the old path
//       refunded the balance but left a one-sided debit in history).
//
// The priest notification is sent by the onWithdrawalStatus trigger
// reacting to status -> blocked, so this function doesn't notify.

import {onCall, HttpsError} from "firebase-functions/v2/https";
import * as admin from "firebase-admin";
import {REGION} from "../config/constants";

const db = admin.firestore();

export const blockWithdrawal = onCall(
  {region: REGION},
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Must be logged in");
    }
    const callerUid = request.auth.uid;

    // Admin gate — mirror the Firestore rules' isAdmin() (users/{uid}
    // role == 'admin'). The function uses the admin SDK (rules bypassed),
    // so this check is the authority for who may refund.
    const callerDoc = await db.doc(`users/${callerUid}`).get();
    if (callerDoc.data()?.role !== "admin") {
      throw new HttpsError(
        "permission-denied",
        "Admin access required",
        {reason: "not_admin"},
      );
    }

    const {withdrawalId} = request.data as {withdrawalId?: string};
    if (typeof withdrawalId !== "string" || withdrawalId.length === 0) {
      throw new HttpsError(
        "invalid-argument",
        "Missing withdrawalId",
        {reason: "invalid_withdrawal_id"},
      );
    }

    const withdrawalRef = db.doc(`withdrawals/${withdrawalId}`);
    // Pre-allocate the refund ledger row id so the write sits inside the
    // transaction without an await in the txn body.
    const refundTxRef = db.collection("wallet_transactions").doc();

    type Result = {blocked: boolean; alreadyBlocked: boolean; amount: number};

    const result = await db.runTransaction<Result>(async (tx) => {
      const snap = await tx.get(withdrawalRef);
      if (!snap.exists) {
        throw new HttpsError(
          "not-found",
          "Withdrawal not found",
          {reason: "not_found"},
        );
      }
      const w = snap.data() ?? {};
      const status = w.status as string;

      // ── Idempotency: already blocked → no second refund. ──
      if (status === "blocked") {
        return {blocked: false, alreadyBlocked: true, amount: 0};
      }
      // ── Can't claw back money that was already sent. ──
      if (status === "paid") {
        throw new HttpsError(
          "failed-precondition",
          "Cannot block a payout that was already sent",
          {reason: "already_paid"},
        );
      }

      const priestId = w.priestId as string;
      const amount = Number(w.amount ?? 0);
      const priestRef = db.doc(`priests/${priestId}`);

      tx.update(withdrawalRef, {
        status: "blocked",
        blockedAt: admin.firestore.FieldValue.serverTimestamp(),
        blockedBy: callerUid,
      });
      tx.update(priestRef, {
        walletBalance: admin.firestore.FieldValue.increment(amount),
        // Back out the lifetime "withdrawn" total that requestWithdrawal
        // incremented when the payout was requested.
        totalWithdrawn: admin.firestore.FieldValue.increment(-amount),
      });
      // Offsetting ledger row so the priest's history reconciles with
      // their balance (a +amount credit mirrors the -amount debit).
      tx.set(refundTxRef, {
        userId: priestId,
        type: "withdrawal_refund",
        coins: amount,
        description: "Withdrawal cancelled — refund",
        withdrawalId: withdrawalId,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
      });

      return {blocked: true, alreadyBlocked: false, amount};
    });

    return result;
  },
);
