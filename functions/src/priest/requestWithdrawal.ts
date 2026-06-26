// Priest withdrawal — creates a "pending" withdrawal request, no
// actual bank transfer happens here.
//
// Why "pending" not "completed":
//   The CF debits walletBalance and writes a withdrawal record, but
//   the real bank payout (Razorpay X / manual transfer) happens
//   downstream. The admin payout dashboard flips status to "paid"
//   once the money has actually moved.
//
// Concurrency safety:
//   The balance read + debit + withdrawal write happen inside a
//   Firestore transaction. Two concurrent requests can no longer
//   both pass the "enough balance?" check and both deduct — the
//   transaction sees a serial view of the priest doc, so the
//   second one re-reads the already-debited balance and either
//   debits correctly or rejects with insufficient_balance.
//
// Idempotency:
//   The client passes a clientRequestId on every call. We use it as
//   the deterministic doc id for the withdrawal record, so the dedup
//   check is a single transactional `tx.get(withdrawalRef)`. If the
//   same id has already produced a withdrawal, we return the
//   existing record instead of debiting again — protects against
//   SDK-level retries and unstable networks.
//
// Structured errors:
//   We surface failures via HttpsError(code, message, details). The
//   `details.reason` token is the contract the Flutter side
//   string-switches on — keep these stable across deploys.

import {onCall, HttpsError} from "firebase-functions/v2/https";
import * as admin from "firebase-admin";
import {REGION} from "../config/constants";
import {sendPushNotification} from "../notifications/sendPush";
import {notifyAdmins} from "../admin/notifyAdmins";

const db = admin.firestore();

// Limit on the idempotency token. Long enough to fit a UUID v4
// (36) or a Firestore auto-id (20); short enough to reject garbage
// payloads that try to bloat the index.
const MAX_CLIENT_REQUEST_ID_LEN = 64;
// Restrict the token to characters that are safe as a Firestore
// doc id and that match the formats we actually generate / accept
// (Firestore auto-ids are base62; UUIDs add `-`). Stops a hostile
// caller from feeding us `/`, `..`, or other path-breaking input.
const CLIENT_REQUEST_ID_REGEX = /^[A-Za-z0-9_-]+$/;

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
      clientRequestId.length > MAX_CLIENT_REQUEST_ID_LEN ||
      !CLIENT_REQUEST_ID_REGEX.test(clientRequestId)
    ) {
      throw new HttpsError(
        "invalid-argument",
        "Missing or invalid request id",
        {reason: "invalid_request_id"},
      );
    }

    // Settings (the admin-tunable minimum) are read outside the
    // transaction because they don't need to be atomic with the
    // balance debit — the minimum is stable per deploy and pulling it
    // inside the txn would force the txn to retry on any unrelated
    // settings write.
    //
    // Reads `minWithdrawal` — the SAME key the admin Settings screen
    // and the seed write. (Previously this read `minWithdrawalAmount`,
    // which nothing ever wrote, so the admin/seed value was ignored
    // and this silently fell back to the default.)
    const settingsDoc = await db.doc("app_config/settings").get();
    const minAmount = Number(
      settingsDoc.data()?.minWithdrawal ?? 1000,
    );

    if (amount < minAmount) {
      throw new HttpsError(
        "failed-precondition",
        `Minimum withdrawal is ₹${minAmount}`,
        {reason: "below_minimum", minAmount},
      );
    }

    const priestRef = db.doc(`priests/${uid}`);
    // The withdrawal doc id IS the clientRequestId. That turns the
    // dedup check into a single tx.get on a known ref — fully
    // transactional, no "where" query needed inside the txn.
    const withdrawalRef = db.doc(`withdrawals/${clientRequestId}`);

    // Pre-allocate ids for the audit-log writes so we can stamp them
    // into the transaction without an `await` inside the txn body.
    const txRef = db.collection("wallet_transactions").doc();
    const notifRef = db.collection("notifications").doc();

    type TxResult = {
      withdrawalId: string;
      newBalance: number;
      amount: number;
      deduplicated: boolean;
      // Priest display name, carried out of the transaction so the
      // post-commit admin notification can name who requested the
      // payout without a second read. Only set on the fresh path.
      priestName?: string;
    };

    const txResult = await db.runTransaction<TxResult>(async (tx) => {
      // ALL reads come first — Firestore transactions require it.
      const [existingWithdrawal, priestDoc] = await Promise.all([
        tx.get(withdrawalRef),
        tx.get(priestRef),
      ]);

      // ── Idempotency hit ──
      // The same clientRequestId already produced a withdrawal.
      // Return the existing record + fresh balance instead of
      // recharging. Cross-priest replay attempts are rejected here
      // (same id, different owner = forgery).
      if (existingWithdrawal.exists) {
        const existingData = existingWithdrawal.data() ?? {};
        if (existingData.priestId !== uid) {
          throw new HttpsError(
            "permission-denied",
            "Request id conflict",
            {reason: "request_id_conflict"},
          );
        }
        const balance = Number(priestDoc.data()?.walletBalance ?? 0);
        return {
          withdrawalId: existingWithdrawal.id,
          newBalance: balance,
          amount: Number(existingData.amount ?? 0),
          deduplicated: true,
        };
      }

      // ── Validation against the freshly-read priest doc ──
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

      const bankAccountName =
        priestData.bankAccountName as string | undefined;
      const bankAccountNumber =
        priestData.bankAccountNumber as string | undefined;
      const bankIfscCode = priestData.bankIfscCode as string | undefined;
      // Cross-border routing identifiers — one family is populated per
      // account (see the priest BankDetails model).
      const bankRoutingNumber =
        priestData.bankRoutingNumber as string | undefined;
      const bankSortCode = priestData.bankSortCode as string | undefined;
      const bankIban = priestData.bankIban as string | undefined;
      const bankSwiftBic = priestData.bankSwiftBic as string | undefined;

      // Country-aware payout-destination check. A valid destination is
      // any recognised routing pair: India account+IFSC, US
      // account+routing, UK account+sort code, IBAN+SWIFT (Europe/GCC),
      // or account+SWIFT (international). India's original requirement
      // (account + IFSC) is one of these, so existing India priests are
      // completely unaffected — this only ADMITS the other countries.
      const hasDestination = Boolean(
        (bankIban && bankSwiftBic) ||
        (bankAccountNumber && bankIfscCode) ||
        (bankAccountNumber && bankRoutingNumber) ||
        (bankAccountNumber && bankSortCode) ||
        (bankAccountNumber && bankSwiftBic),
      );

      if (!bankAccountName || !hasDestination) {
        throw new HttpsError(
          "failed-precondition",
          "Bank details are required for withdrawals",
          {reason: "no_bank_details"},
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

      // ── All writes — transactional, all-or-nothing. ──
      tx.update(priestRef, {
        walletBalance: admin.firestore.FieldValue.increment(-amount),
        // Maintained on the priest doc so the wallet page can show
        // lifetime "Withdrawn" without scanning the transaction list.
        totalWithdrawn: admin.firestore.FieldValue.increment(amount),
      });

      tx.set(withdrawalRef, {
        priestId: uid,
        amount: amount,
        // "pending" until the admin payout dashboard flips it to
        // "paid" after sending the actual bank transfer. "blocked"
        // is the fraud-block path; rejected by manual review.
        status: "pending",
        clientRequestId: clientRequestId,
        // Snapshot the destination so admin payouts (and the priest's
        // status screen) read from the withdrawal doc itself, immune to
        // later edits/deletes of the priest's saved bank details. All
        // fields coalesce to "" — for an IBAN-country account the plain
        // account number / IFSC are undefined, and Firestore rejects an
        // undefined field value.
        bankAccountName: bankAccountName ?? "",
        bankAccountNumber: bankAccountNumber ?? "",
        bankIfscCode: bankIfscCode ?? "",
        bankName: priestData.bankName ?? "",
        // Account type (checking/savings) — required by US/UK ACH-style
        // payouts, so the admin's payout sheet needs it.
        bankAccountType: priestData.bankAccountType ?? "",
        upiId: priestData.upiId ?? "",
        // Cross-border snapshot — country + currency for display, and
        // whichever routing identifiers this account uses so the admin
        // can build the bank's payout sheet.
        bankCountry: priestData.bankCountry ?? "IN",
        currency: priestData.bankCurrency ?? "",
        bankRoutingNumber: bankRoutingNumber ?? "",
        bankSortCode: bankSortCode ?? "",
        bankIban: bankIban ?? "",
        bankSwiftBic: bankSwiftBic ?? "",
        // Contact for the admin — prefer the bank-contact fields, fall
        // back to the priest's registration phone/email.
        bankContactPhone:
          priestData.bankContactPhone ?? priestData.phone ?? "",
        bankContactEmail:
          priestData.bankContactEmail ?? priestData.email ?? "",
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
      });

      tx.set(txRef, {
        userId: uid,
        type: "withdrawal",
        coins: -amount,
        description: `Withdrawal to ${priestData.bankName ?? "bank"}`,
        withdrawalId: withdrawalRef.id,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
      });

      tx.set(notifRef, {
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

      return {
        withdrawalId: withdrawalRef.id,
        newBalance: currentBalance - amount,
        amount: amount,
        deduplicated: false,
        priestName:
          (priestData.fullName as string | undefined) ||
          bankAccountName ||
          "A speaker",
      };
    });

    // Push the priest so the request lands as an OS notification —
    // useful when the admin batch-processes payouts hours later and
    // the priest backgrounded the wallet screen. Outside the txn so
    // a push failure can't roll back the (already-committed) debit.
    // Skipped on the dedup path because the original call already
    // pushed when it first landed.
    if (!txResult.deduplicated) {
      try {
        await sendPushNotification({
          userId: uid,
          title: "Withdrawal Submitted",
          body:
            `₹${amount} withdrawal is being processed. ` +
            "You'll be notified when it's sent to your bank.",
          data: {
            type: "withdrawal_processed",
            route: "/priest/wallet",
          },
        });
      } catch (_) {
        // Push is best-effort; the in-app notification doc above is
        // the authoritative receipt.
      }

      // Alert every admin that a new payout is waiting in their queue.
      // Outside the txn so it can't roll back the committed debit, and
      // wrapped in its OWN try/catch so the throw-safety is explicit at
      // the call site — a future change inside notifyAdmins can never
      // surface as a caller error after the money already moved. Skipped
      // on the dedup path so a retried client call doesn't re-ping the
      // admins; keyed on the withdrawal id so retries converge on one
      // alert.
      try {
        await notifyAdmins({
          type: "admin_new_withdrawal",
          title: "New withdrawal request",
          body:
            `${txResult.priestName ?? "A speaker"} requested ` +
            `₹${txResult.amount} — review the payout queue.`,
          route: "/admin/withdrawals",
          dedupeKey: txResult.withdrawalId,
          data: {withdrawalId: txResult.withdrawalId},
        });
      } catch (e) {
        console.error("[requestWithdrawal] admin notify failed", e);
      }
    }

    return txResult;
  },
);
