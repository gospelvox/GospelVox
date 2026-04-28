"use strict";
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
Object.defineProperty(exports, "__esModule", { value: true });
exports.requestWithdrawal = void 0;
const https_1 = require("firebase-functions/v2/https");
const admin = require("firebase-admin");
const constants_1 = require("../config/constants");
const db = admin.firestore();
// Limit on the idempotency token. Long enough to fit a UUID v4
// (36) or a Firestore auto-id (20); short enough to reject garbage
// payloads that try to bloat the index.
const MAX_CLIENT_REQUEST_ID_LEN = 64;
exports.requestWithdrawal = (0, https_1.onCall)({ region: constants_1.REGION }, async (request) => {
    var _a, _b, _c, _d, _e, _f, _g, _h, _j, _k;
    if (!request.auth) {
        throw new https_1.HttpsError("unauthenticated", "Must be logged in");
    }
    const uid = request.auth.uid;
    const { amount, clientRequestId } = request.data;
    if (typeof amount !== "number" ||
        !Number.isFinite(amount) ||
        amount <= 0 ||
        !Number.isInteger(amount)) {
        throw new https_1.HttpsError("invalid-argument", "Amount must be a positive integer", { reason: "invalid_amount" });
    }
    if (typeof clientRequestId !== "string" ||
        clientRequestId.length === 0 ||
        clientRequestId.length > MAX_CLIENT_REQUEST_ID_LEN) {
        throw new https_1.HttpsError("invalid-argument", "Missing or invalid request id", { reason: "invalid_request_id" });
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
            throw new https_1.HttpsError("permission-denied", "Request id conflict", { reason: "request_id_conflict" });
        }
        // Return the original result rather than recharging. We re-
        // read the priest doc so the returned balance reflects any
        // settlement writes that happened after the original call.
        const priestSnap = await db.doc(`priests/${uid}`).get();
        const balance = Number((_b = (_a = priestSnap.data()) === null || _a === void 0 ? void 0 : _a.walletBalance) !== null && _b !== void 0 ? _b : 0);
        return {
            withdrawalId: existing.id,
            newBalance: balance,
            amount: Number((_c = existingData.amount) !== null && _c !== void 0 ? _c : 0),
            deduplicated: true,
        };
    }
    const priestRef = db.doc(`priests/${uid}`);
    const priestDoc = await priestRef.get();
    if (!priestDoc.exists) {
        throw new https_1.HttpsError("not-found", "Priest profile not found", { reason: "priest_not_found" });
    }
    const priestData = (_d = priestDoc.data()) !== null && _d !== void 0 ? _d : {};
    if (priestData.status !== "approved" || !priestData.isActivated) {
        throw new https_1.HttpsError("failed-precondition", "Account must be approved and activated", { reason: "account_inactive" });
    }
    const bankAccountName = priestData.bankAccountName;
    const bankAccountNumber = priestData.bankAccountNumber;
    const bankIfscCode = priestData.bankIfscCode;
    if (!bankAccountName || !bankAccountNumber || !bankIfscCode) {
        throw new https_1.HttpsError("failed-precondition", "Bank details are required for withdrawals", { reason: "no_bank_details" });
    }
    const settingsDoc = await db.doc("app_config/settings").get();
    const minAmount = Number((_f = (_e = settingsDoc.data()) === null || _e === void 0 ? void 0 : _e.minWithdrawalAmount) !== null && _f !== void 0 ? _f : 100);
    if (amount < minAmount) {
        throw new https_1.HttpsError("failed-precondition", `Minimum withdrawal is ₹${minAmount}`, { reason: "below_minimum", minAmount });
    }
    const currentBalance = Number((_g = priestData.walletBalance) !== null && _g !== void 0 ? _g : 0);
    if (currentBalance < amount) {
        throw new https_1.HttpsError("failed-precondition", "Insufficient balance", { reason: "insufficient_balance" });
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
        bankName: (_h = priestData.bankName) !== null && _h !== void 0 ? _h : "",
        upiId: (_j = priestData.upiId) !== null && _j !== void 0 ? _j : "",
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    const txRef = db.collection("wallet_transactions").doc();
    batch.set(txRef, {
        userId: uid,
        type: "withdrawal",
        coins: -amount,
        description: `Withdrawal to ${(_k = priestData.bankName) !== null && _k !== void 0 ? _k : "bank"}`,
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
        body: `Your withdrawal request of ₹${amount} has been ` +
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
});
//# sourceMappingURL=requestWithdrawal.js.map