"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.billingTick = void 0;
const https_1 = require("firebase-functions/v2/https");
const admin = require("firebase-admin");
const constants_1 = require("../config/constants");
const db = admin.firestore();
// Deducts one minute's worth of coins from the user and credits the
// priest's share. Called by the USER'S client every 60s while the
// session is active — never by the priest, to avoid double-billing.
//
// All mutations land in a single batch so a partial failure can't
// leave the user debited without the priest credited (or vice
// versa). The wallet_transactions write is part of the same batch
// so the ledger always agrees with the wallet.
//
// Returns `shouldEnd: true` when the user can no longer afford
// another minute — the client treats that as the authoritative
// signal to stop its local timers and navigate to the summary.
exports.billingTick = (0, https_1.onCall)({ region: constants_1.REGION }, async (request) => {
    var _a, _b, _c, _d, _e, _f, _g, _h, _j, _k, _l, _m, _o;
    if (!request.auth) {
        throw new https_1.HttpsError("unauthenticated", "Must be logged in");
    }
    const sessionId = (_a = request.data) === null || _a === void 0 ? void 0 : _a.sessionId;
    if (!sessionId) {
        throw new https_1.HttpsError("invalid-argument", "Missing sessionId");
    }
    const sessionRef = db.doc(`sessions/${sessionId}`);
    const sessionSnap = await sessionRef.get();
    if (!sessionSnap.exists) {
        throw new https_1.HttpsError("not-found", "Session not found");
    }
    const session = (_b = sessionSnap.data()) !== null && _b !== void 0 ? _b : {};
    // Only the user in this session may trigger billing. This is
    // belt-and-braces — the client restricts billing to user-side
    // already, but a compromised client shouldn't be able to bill
    // on behalf of someone else.
    if (request.auth.uid !== session.userId) {
        throw new https_1.HttpsError("permission-denied", "Only the session user can trigger billing");
    }
    // If the session is already terminal we short-circuit with the
    // existing totals. Lets the client observe shouldEnd=true and
    // stop ticking instead of repeatedly hitting this CF.
    if (session.status !== "active") {
        return {
            remainingBalance: 0,
            totalCharged: Number((_c = session.totalCharged) !== null && _c !== void 0 ? _c : 0),
            durationMinutes: Number((_d = session.durationMinutes) !== null && _d !== void 0 ? _d : 0),
            shouldEnd: true,
        };
    }
    const rate = Number((_e = session.ratePerMinute) !== null && _e !== void 0 ? _e : 10);
    const commission = Number((_f = session.commissionPercent) !== null && _f !== void 0 ? _f : 20);
    // Math.floor so integer-only coin accounting never leaks a
    // fractional coin to the priest. The commission pool absorbs
    // the rounding remainder.
    const priestEarningPerMinute = Math.floor(rate * (1 - commission / 100));
    const userRef = db.doc(`users/${session.userId}`);
    const userSnap = await userRef.get();
    const currentBalance = Number((_h = (_g = userSnap.data()) === null || _g === void 0 ? void 0 : _g.coinBalance) !== null && _h !== void 0 ? _h : 0);
    // Not enough coins for another minute — settle the session
    // right here. We still return the current totals so the client
    // renders the correct final state without a second round trip.
    if (currentBalance < rate) {
        await sessionRef.update({
            status: "completed",
            endedAt: admin.firestore.FieldValue.serverTimestamp(),
            endReason: "balance_zero",
        });
        return {
            remainingBalance: currentBalance,
            totalCharged: Number((_j = session.totalCharged) !== null && _j !== void 0 ? _j : 0),
            durationMinutes: Number((_k = session.durationMinutes) !== null && _k !== void 0 ? _k : 0),
            shouldEnd: true,
        };
    }
    const priestRef = db.doc(`priests/${session.priestId}`);
    const newDuration = Number((_l = session.durationMinutes) !== null && _l !== void 0 ? _l : 0) + 1;
    const newTotalCharged = Number((_m = session.totalCharged) !== null && _m !== void 0 ? _m : 0) + rate;
    const newPriestEarnings = Number((_o = session.priestEarnings) !== null && _o !== void 0 ? _o : 0) + priestEarningPerMinute;
    const batch = db.batch();
    batch.update(userRef, {
        coinBalance: admin.firestore.FieldValue.increment(-rate),
    });
    batch.update(priestRef, {
        walletBalance: admin.firestore.FieldValue.increment(priestEarningPerMinute),
        totalEarnings: admin.firestore.FieldValue.increment(priestEarningPerMinute),
    });
    batch.update(sessionRef, {
        durationMinutes: newDuration,
        totalCharged: newTotalCharged,
        priestEarnings: newPriestEarnings,
        lastHeartbeat: admin.firestore.FieldValue.serverTimestamp(),
    });
    // Ledger entry for the wallet screen. `-rate` convention matches
    // the coin-purchase flow so the history list can render both
    // credits and debits the same way.
    const txRef = db.collection("wallet_transactions").doc();
    batch.set(txRef, {
        userId: session.userId,
        type: "session_charge",
        sessionId: sessionId,
        coins: -rate,
        description: `${session.type} session — minute ${newDuration}`,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    await batch.commit();
    const newBalance = currentBalance - rate;
    return {
        remainingBalance: newBalance,
        totalCharged: newTotalCharged,
        durationMinutes: newDuration,
        // If the user can't afford another minute we tell the client
        // to wind down now, rather than waiting for the next tick.
        shouldEnd: newBalance < rate,
    };
});
//# sourceMappingURL=billingTick.js.map