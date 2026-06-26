"use strict";
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
Object.defineProperty(exports, "__esModule", { value: true });
exports.requestWithdrawal = void 0;
const https_1 = require("firebase-functions/v2/https");
const admin = require("firebase-admin");
const constants_1 = require("../config/constants");
const sendPush_1 = require("../notifications/sendPush");
const notifyAdmins_1 = require("../admin/notifyAdmins");
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
exports.requestWithdrawal = (0, https_1.onCall)({ region: constants_1.REGION }, async (request) => {
    var _a, _b, _c;
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
        clientRequestId.length > MAX_CLIENT_REQUEST_ID_LEN ||
        !CLIENT_REQUEST_ID_REGEX.test(clientRequestId)) {
        throw new https_1.HttpsError("invalid-argument", "Missing or invalid request id", { reason: "invalid_request_id" });
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
    const minAmount = Number((_b = (_a = settingsDoc.data()) === null || _a === void 0 ? void 0 : _a.minWithdrawal) !== null && _b !== void 0 ? _b : 1000);
    if (amount < minAmount) {
        throw new https_1.HttpsError("failed-precondition", `Minimum withdrawal is ₹${minAmount}`, { reason: "below_minimum", minAmount });
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
    const txResult = await db.runTransaction(async (tx) => {
        var _a, _b, _c, _d, _e, _f, _g, _h, _j, _k, _l, _m, _o, _p, _q, _r;
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
            const existingData = (_a = existingWithdrawal.data()) !== null && _a !== void 0 ? _a : {};
            if (existingData.priestId !== uid) {
                throw new https_1.HttpsError("permission-denied", "Request id conflict", { reason: "request_id_conflict" });
            }
            const balance = Number((_c = (_b = priestDoc.data()) === null || _b === void 0 ? void 0 : _b.walletBalance) !== null && _c !== void 0 ? _c : 0);
            return {
                withdrawalId: existingWithdrawal.id,
                newBalance: balance,
                amount: Number((_d = existingData.amount) !== null && _d !== void 0 ? _d : 0),
                deduplicated: true,
            };
        }
        // ── Validation against the freshly-read priest doc ──
        if (!priestDoc.exists) {
            throw new https_1.HttpsError("not-found", "Priest profile not found", { reason: "priest_not_found" });
        }
        const priestData = (_e = priestDoc.data()) !== null && _e !== void 0 ? _e : {};
        if (priestData.status !== "approved" || !priestData.isActivated) {
            throw new https_1.HttpsError("failed-precondition", "Account must be approved and activated", { reason: "account_inactive" });
        }
        const bankAccountName = priestData.bankAccountName;
        const bankAccountNumber = priestData.bankAccountNumber;
        const bankIfscCode = priestData.bankIfscCode;
        // Cross-border routing identifiers — one family is populated per
        // account (see the priest BankDetails model).
        const bankRoutingNumber = priestData.bankRoutingNumber;
        const bankSortCode = priestData.bankSortCode;
        const bankIban = priestData.bankIban;
        const bankSwiftBic = priestData.bankSwiftBic;
        // Country-aware payout-destination check. A valid destination is
        // any recognised routing pair: India account+IFSC, US
        // account+routing, UK account+sort code, IBAN+SWIFT (Europe/GCC),
        // or account+SWIFT (international). India's original requirement
        // (account + IFSC) is one of these, so existing India priests are
        // completely unaffected — this only ADMITS the other countries.
        const hasDestination = Boolean((bankIban && bankSwiftBic) ||
            (bankAccountNumber && bankIfscCode) ||
            (bankAccountNumber && bankRoutingNumber) ||
            (bankAccountNumber && bankSortCode) ||
            (bankAccountNumber && bankSwiftBic));
        if (!bankAccountName || !hasDestination) {
            throw new https_1.HttpsError("failed-precondition", "Bank details are required for withdrawals", { reason: "no_bank_details" });
        }
        const currentBalance = Number((_f = priestData.walletBalance) !== null && _f !== void 0 ? _f : 0);
        if (currentBalance < amount) {
            throw new https_1.HttpsError("failed-precondition", "Insufficient balance", { reason: "insufficient_balance" });
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
            bankAccountName: bankAccountName !== null && bankAccountName !== void 0 ? bankAccountName : "",
            bankAccountNumber: bankAccountNumber !== null && bankAccountNumber !== void 0 ? bankAccountNumber : "",
            bankIfscCode: bankIfscCode !== null && bankIfscCode !== void 0 ? bankIfscCode : "",
            bankName: (_g = priestData.bankName) !== null && _g !== void 0 ? _g : "",
            // Account type (checking/savings) — required by US/UK ACH-style
            // payouts, so the admin's payout sheet needs it.
            bankAccountType: (_h = priestData.bankAccountType) !== null && _h !== void 0 ? _h : "",
            upiId: (_j = priestData.upiId) !== null && _j !== void 0 ? _j : "",
            // Cross-border snapshot — country + currency for display, and
            // whichever routing identifiers this account uses so the admin
            // can build the bank's payout sheet.
            bankCountry: (_k = priestData.bankCountry) !== null && _k !== void 0 ? _k : "IN",
            currency: (_l = priestData.bankCurrency) !== null && _l !== void 0 ? _l : "",
            bankRoutingNumber: bankRoutingNumber !== null && bankRoutingNumber !== void 0 ? bankRoutingNumber : "",
            bankSortCode: bankSortCode !== null && bankSortCode !== void 0 ? bankSortCode : "",
            bankIban: bankIban !== null && bankIban !== void 0 ? bankIban : "",
            bankSwiftBic: bankSwiftBic !== null && bankSwiftBic !== void 0 ? bankSwiftBic : "",
            // Contact for the admin — prefer the bank-contact fields, fall
            // back to the priest's registration phone/email.
            bankContactPhone: (_o = (_m = priestData.bankContactPhone) !== null && _m !== void 0 ? _m : priestData.phone) !== null && _o !== void 0 ? _o : "",
            bankContactEmail: (_q = (_p = priestData.bankContactEmail) !== null && _p !== void 0 ? _p : priestData.email) !== null && _q !== void 0 ? _q : "",
            createdAt: admin.firestore.FieldValue.serverTimestamp(),
        });
        tx.set(txRef, {
            userId: uid,
            type: "withdrawal",
            coins: -amount,
            description: `Withdrawal to ${(_r = priestData.bankName) !== null && _r !== void 0 ? _r : "bank"}`,
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
            body: `Your withdrawal request of ₹${amount} has been ` +
                "submitted. It will be processed within 1-3 business days.",
            isRead: false,
            createdAt: admin.firestore.FieldValue.serverTimestamp(),
        });
        return {
            withdrawalId: withdrawalRef.id,
            newBalance: currentBalance - amount,
            amount: amount,
            deduplicated: false,
            priestName: priestData.fullName ||
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
            await (0, sendPush_1.sendPushNotification)({
                userId: uid,
                title: "Withdrawal Submitted",
                body: `₹${amount} withdrawal is being processed. ` +
                    "You'll be notified when it's sent to your bank.",
                data: {
                    type: "withdrawal_processed",
                    route: "/priest/wallet",
                },
            });
        }
        catch (_) {
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
            await (0, notifyAdmins_1.notifyAdmins)({
                type: "admin_new_withdrawal",
                title: "New withdrawal request",
                body: `${(_c = txResult.priestName) !== null && _c !== void 0 ? _c : "A speaker"} requested ` +
                    `₹${txResult.amount} — review the payout queue.`,
                route: "/admin/withdrawals",
                dedupeKey: txResult.withdrawalId,
                data: { withdrawalId: txResult.withdrawalId },
            });
        }
        catch (e) {
            console.error("[requestWithdrawal] admin notify failed", e);
        }
    }
    return txResult;
});
//# sourceMappingURL=requestWithdrawal.js.map