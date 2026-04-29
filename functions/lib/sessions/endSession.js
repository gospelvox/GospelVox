"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.endSession = void 0;
const https_1 = require("firebase-functions/v2/https");
const admin = require("firebase-admin");
const constants_1 = require("../config/constants");
const sendPush_1 = require("../notifications/sendPush");
const db = admin.firestore();
// Settles a session. Either party may call it — the CF checks
// participation and is idempotent: if the session is already
// completed it just returns the existing summary, so a duplicate
// call (e.g. both sides tap End at the same time) doesn't double-
// charge the user.
//
// Minimum-charge rule: if the session went active but no billing
// tick ever ran (priest accepted and someone ended within the first
// minute), we still bill one full minute. This matches the product
// contract stated on the priest profile page.
exports.endSession = (0, https_1.onCall)({ region: constants_1.REGION }, async (request) => {
    var _a, _b, _c, _d, _e, _f, _g, _h, _j, _k, _l, _m, _o, _p, _q, _r;
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
    const uid = request.auth.uid;
    if (uid !== session.userId && uid !== session.priestId) {
        throw new https_1.HttpsError("permission-denied", "Not a participant in this session");
    }
    // Idempotent path: session is already completed. Re-fetch the
    // user doc so the returned newBalance reflects any other writes
    // (e.g. a coin purchase) that happened since the session ended.
    if (session.status === "completed") {
        const userSnap = await db.doc(`users/${session.userId}`).get();
        return {
            durationMinutes: Number((_c = session.durationMinutes) !== null && _c !== void 0 ? _c : 0),
            totalCharged: Number((_d = session.totalCharged) !== null && _d !== void 0 ? _d : 0),
            priestEarnings: Number((_e = session.priestEarnings) !== null && _e !== void 0 ? _e : 0),
            newBalance: Number((_g = (_f = userSnap.data()) === null || _f === void 0 ? void 0 : _f.coinBalance) !== null && _g !== void 0 ? _g : 0),
        };
    }
    const rate = Number((_h = session.ratePerMinute) !== null && _h !== void 0 ? _h : 10);
    const commission = Number((_j = session.commissionPercent) !== null && _j !== void 0 ? _j : 20);
    let finalDuration = Number((_k = session.durationMinutes) !== null && _k !== void 0 ? _k : 0);
    let finalTotalCharged = Number((_l = session.totalCharged) !== null && _l !== void 0 ? _l : 0);
    let finalPriestEarnings = Number((_m = session.priestEarnings) !== null && _m !== void 0 ? _m : 0);
    // Minimum 1 minute for any active session where no billing tick
    // has run yet. If the user genuinely can't afford that one
    // minute we skip — the CF already flipped them to balance_zero
    // via billingTick in that case, so we wouldn't reach here.
    if (session.status === "active" && finalDuration === 0) {
        const userRef = db.doc(`users/${session.userId}`);
        const userSnap = await userRef.get();
        const currentBalance = Number((_p = (_o = userSnap.data()) === null || _o === void 0 ? void 0 : _o.coinBalance) !== null && _p !== void 0 ? _p : 0);
        if (currentBalance >= rate) {
            const priestEarning = Math.floor(rate * (1 - commission / 100));
            const priestRef = db.doc(`priests/${session.priestId}`);
            const batch = db.batch();
            batch.update(userRef, {
                coinBalance: admin.firestore.FieldValue.increment(-rate),
            });
            batch.update(priestRef, {
                walletBalance: admin.firestore.FieldValue.increment(priestEarning),
                totalEarnings: admin.firestore.FieldValue.increment(priestEarning),
            });
            const txRef = db.collection("wallet_transactions").doc();
            batch.set(txRef, {
                userId: session.userId,
                type: "session_charge",
                sessionId: sessionId,
                coins: -rate,
                description: `${session.type} session — minimum charge`,
                createdAt: admin.firestore.FieldValue.serverTimestamp(),
            });
            await batch.commit();
            finalDuration = 1;
            finalTotalCharged += rate;
            finalPriestEarnings += priestEarning;
        }
    }
    await sessionRef.update({
        status: "completed",
        endedAt: admin.firestore.FieldValue.serverTimestamp(),
        durationMinutes: finalDuration,
        totalCharged: finalTotalCharged,
        priestEarnings: finalPriestEarnings,
        endedBy: uid === session.userId ? "user" : "priest",
    });
    // Bump the priest's session count on the priest doc so the
    // dashboard stat reflects this session immediately, without
    // waiting for an aggregation job.
    await db.doc(`priests/${session.priestId}`).update({
        totalSessions: admin.firestore.FieldValue.increment(1),
    });
    const finalUserSnap = await db.doc(`users/${session.userId}`).get();
    const finalUserBalance = Number((_r = (_q = finalUserSnap.data()) === null || _q === void 0 ? void 0 : _q.coinBalance) !== null && _r !== void 0 ? _r : 0);
    // Drop in-app inbox entries for both sides BEFORE pushing. The
    // notification doc is the source of truth — push is best-effort
    // delivery, but the inbox needs the record either way so users
    // can review past sessions from the notifications page.
    //
    // Title is "Session Complete" (vs "Session Ended" used by the
    // watchdog for abnormal termination) — the title alone tells the
    // user whether the session ended cleanly or was timed out.
    const notifBatch = db.batch();
    const userNotifRef = db.collection("notifications").doc();
    notifBatch.set(userNotifRef, {
        userId: session.userId,
        type: "session_ended",
        title: "Session Complete",
        body: `Your ${session.type} session lasted ${finalDuration} min. ` +
            `${finalTotalCharged} coins used. ` +
            `Wallet balance: ${finalUserBalance} coins.`,
        sessionId: sessionId,
        isRead: false,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    const priestNotifRef = db.collection("notifications").doc();
    notifBatch.set(priestNotifRef, {
        userId: session.priestId,
        type: "session_ended",
        title: "Session Complete",
        body: `Your ${session.type} session lasted ${finalDuration} min. ` +
            `₹${finalPriestEarnings} added to your wallet.`,
        sessionId: sessionId,
        isRead: false,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    await notifBatch.commit();
    // Push both sides so each party knows the session is settled —
    // matters most when one side ended the call from a different
    // surface and the other is still on the in-call screen.
    await (0, sendPush_1.sendPushNotification)({
        userId: session.userId,
        title: "Session Complete",
        body: `Your ${session.type} session lasted ${finalDuration} min. ` +
            `${finalTotalCharged} coins used. ` +
            `Balance: ${finalUserBalance} coins.`,
        data: {
            type: "session_ended",
            sessionId: sessionId,
            route: "/user",
        },
    });
    await (0, sendPush_1.sendPushNotification)({
        userId: session.priestId,
        title: "Session Complete",
        body: `Your ${session.type} session lasted ${finalDuration} min. ` +
            `₹${finalPriestEarnings} added to your wallet.`,
        data: {
            type: "session_ended",
            sessionId: sessionId,
            route: "/priest",
        },
    });
    return {
        durationMinutes: finalDuration,
        totalCharged: finalTotalCharged,
        priestEarnings: finalPriestEarnings,
        newBalance: finalUserBalance,
    };
});
//# sourceMappingURL=endSession.js.map