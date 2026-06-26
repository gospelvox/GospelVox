"use strict";
// When a priest CORRECTS their bank details, propagate the fix to any
// of their ON-HOLD withdrawals so the admin actually sees the change.
//
// The problem this solves:
//   A withdrawal snapshots the bank details at request time. If the
//   admin puts it on hold ("wrong account number") and the priest then
//   fixes their bank details, that edit only touches priests/{uid} —
//   the on-hold withdrawal still carries the OLD snapshot and is still
//   "on_hold", so the admin has no signal and, if they look, sees the
//   stale account. The priest "corrected and submitted" but nothing
//   changed on the admin side.
//
// What this does on a bank-field change:
//   • re-snapshots the corrected bank/contact fields onto every
//     on_hold withdrawal of that priest, and
//   • moves them back to "pending" so they re-enter the admin's Pending
//     queue (the clear signal that they're fixed and ready to retry).
//   Money stays debited throughout (on_hold never refunded), so nothing
//   about the balance changes — only where it will be sent.
//
// No notification fires: onWithdrawalStatus ignores the ->pending
// transition, which is correct (the priest already knows they fixed it).
Object.defineProperty(exports, "__esModule", { value: true });
exports.onPriestBankDetailsChanged = void 0;
const firestore_1 = require("firebase-functions/v2/firestore");
const admin = require("firebase-admin");
const constants_1 = require("../config/constants");
const db = admin.firestore();
// Fields whose change should trigger a re-snapshot.
const WATCHED = [
    "bankAccountName", "bankAccountNumber", "bankIfscCode", "bankName",
    "bankAccountType", "bankRoutingNumber", "bankSortCode", "bankIban",
    "bankSwiftBic", "bankCountry", "bankCurrency", "upiId",
    "bankContactPhone", "bankContactEmail", "phone", "email",
];
exports.onPriestBankDetailsChanged = (0, firestore_1.onDocumentUpdated)({ document: "priests/{priestId}", region: constants_1.REGION }, async (event) => {
    var _a, _b, _c, _d, _e, _f, _g, _h, _j, _k, _l, _m, _o, _p, _q, _r, _s, _t;
    const before = (_a = event.data) === null || _a === void 0 ? void 0 : _a.before.data();
    const after = (_b = event.data) === null || _b === void 0 ? void 0 : _b.after.data();
    if (!before || !after)
        return;
    // Cheap early-out for the (frequent) non-bank priest updates.
    const changed = WATCHED.some((f) => before[f] !== after[f]);
    if (!changed)
        return;
    const priestId = event.params.priestId;
    // Single-field query (no composite index); filter status in code.
    const snap = await db
        .collection("withdrawals")
        .where("priestId", "==", priestId)
        .get();
    const onHold = snap.docs.filter((d) => d.data().status === "on_hold");
    if (onHold.length === 0)
        return;
    // The corrected snapshot — same shape requestWithdrawal writes.
    const snapshot = {
        bankAccountName: (_c = after.bankAccountName) !== null && _c !== void 0 ? _c : "",
        bankAccountNumber: (_d = after.bankAccountNumber) !== null && _d !== void 0 ? _d : "",
        bankIfscCode: (_e = after.bankIfscCode) !== null && _e !== void 0 ? _e : "",
        bankName: (_f = after.bankName) !== null && _f !== void 0 ? _f : "",
        bankAccountType: (_g = after.bankAccountType) !== null && _g !== void 0 ? _g : "",
        bankRoutingNumber: (_h = after.bankRoutingNumber) !== null && _h !== void 0 ? _h : "",
        bankSortCode: (_j = after.bankSortCode) !== null && _j !== void 0 ? _j : "",
        bankIban: (_k = after.bankIban) !== null && _k !== void 0 ? _k : "",
        bankSwiftBic: (_l = after.bankSwiftBic) !== null && _l !== void 0 ? _l : "",
        bankCountry: (_m = after.bankCountry) !== null && _m !== void 0 ? _m : "IN",
        currency: (_o = after.bankCurrency) !== null && _o !== void 0 ? _o : "",
        upiId: (_p = after.upiId) !== null && _p !== void 0 ? _p : "",
        bankContactPhone: (_r = (_q = after.bankContactPhone) !== null && _q !== void 0 ? _q : after.phone) !== null && _r !== void 0 ? _r : "",
        bankContactEmail: (_t = (_s = after.bankContactEmail) !== null && _s !== void 0 ? _s : after.email) !== null && _t !== void 0 ? _t : "",
    };
    const batch = db.batch();
    for (const doc of onHold) {
        batch.update(doc.ref, Object.assign(Object.assign({}, snapshot), { 
            // Back into the admin queue, with the hold cleared.
            status: "pending", onHoldReason: admin.firestore.FieldValue.delete(), resubmittedAt: admin.firestore.FieldValue.serverTimestamp() }));
    }
    await batch.commit();
});
//# sourceMappingURL=onPriestBankDetailsChanged.js.map