"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.endSession = void 0;
const https_1 = require("firebase-functions/v2/https");
const admin = require("firebase-admin");
const constants_1 = require("../config/constants");
const sendPush_1 = require("../notifications/sendPush");
const connection_1 = require("./connection");
const notifyConnectionFailed_1 = require("./notifyConnectionFailed");
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
    var _a, _b, _c, _d, _e, _f, _g, _h, _j, _k, _l, _m, _o, _p, _q, _r, _s, _t, _u, _v, _w, _x, _y, _z, _0;
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
    // Idempotent fast-path: session already settled long ago. Re-fetch
    // the user doc so the returned newBalance reflects any other writes
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
    // CONCURRENCY CLAIM — settle exactly once. Two calls can race here:
    // when a call ends, one side taps End (→ endSession) AND leaving
    // the Agora channel makes the other side's onUserOffline fire
    // (→ endSession too). Both could read status="active" before
    // either finishes, each run the round-up, and DOUBLE-charge the
    // user + DOUBLE-push both sides. This transaction lets only ONE
    // call win the active→settling flip; the loser falls through to the
    // read-only summary path and never bills or notifies again. Leaves
    // every non-active status (declined/expired/cancelled/pending)
    // untouched — only an active session is settle-able here.
    const claimed = await db.runTransaction(async (tx) => {
        const snap = await tx.get(sessionRef);
        const s = snap.data();
        if (!s)
            return false;
        if (s.status !== "active" || s.settling === true)
            return false;
        tx.update(sessionRef, { settling: true });
        return true;
    });
    if (!claimed) {
        // Another call already settled (or is settling) this session.
        // Return the latest summary without billing or notifying again.
        const freshSnap = await sessionRef.get();
        const fresh = (_h = freshSnap.data()) !== null && _h !== void 0 ? _h : session;
        const userSnap = await db.doc(`users/${fresh.userId}`).get();
        return {
            durationMinutes: Number((_j = fresh.durationMinutes) !== null && _j !== void 0 ? _j : 0),
            totalCharged: Number((_k = fresh.totalCharged) !== null && _k !== void 0 ? _k : 0),
            priestEarnings: Number((_l = fresh.priestEarnings) !== null && _l !== void 0 ? _l : 0),
            newBalance: Number((_o = (_m = userSnap.data()) === null || _m === void 0 ? void 0 : _m.coinBalance) !== null && _o !== void 0 ? _o : 0),
        };
    }
    const rate = Number((_p = session.ratePerMinute) !== null && _p !== void 0 ? _p : 10);
    const commission = Number((_q = session.commissionPercent) !== null && _q !== void 0 ? _q : 20);
    let finalDuration = Number((_r = session.durationMinutes) !== null && _r !== void 0 ? _r : 0);
    let finalTotalCharged = Number((_s = session.totalCharged) !== null && _s !== void 0 ? _s : 0);
    let finalPriestEarnings = Number((_t = session.priestEarnings) !== null && _t !== void 0 ? _t : 0);
    // CONNECTION GATE — only sessions that reached a confirmed
    // two-way connection may be charged. If this is null the call
    // never connected: skip the minimum charge AND the round-up
    // below, and settle with 0 cost / 0 commission. connectedEpochMs
    // is also the billing epoch for the round-up — partial minutes
    // are measured from the real connection, never from the priest's
    // "Accept" tap.
    const connectedEpochMs = (0, connection_1.connectionEpochMs)(session);
    // Minimum 1 minute for any active session where no billing tick
    // has run yet. If the user genuinely can't afford that one
    // minute we skip — the CF already flipped them to balance_zero
    // via billingTick in that case, so we wouldn't reach here.
    if (session.status === "active" &&
        finalDuration === 0 &&
        connectedEpochMs !== null) {
        const userRef = db.doc(`users/${session.userId}`);
        const userSnap = await userRef.get();
        const currentBalance = Number((_v = (_u = userSnap.data()) === null || _u === void 0 ? void 0 : _u.coinBalance) !== null && _v !== void 0 ? _v : 0);
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
    // Round-up rule: any partial minute beyond the completed
    // billingTick minutes gets charged as a full extra minute.
    // Matches the telecom-style estimate the End Call sheet
    // already shows the user (currentCost uses .ceil()) and is
    // fair to priests who are otherwise unpaid for 0–59 seconds
    // of work on every session. Gated on balance — if the user
    // can't afford the rollup, they get the partial minute free
    // rather than going negative.
    //
    // Cap the billable window at the user's LAST PROOF OF PRESENCE,
    // never at "now". The user's client refreshes lastHeartbeat
    // every 30s (and on every billingTick); when their app dies it
    // freezes. Measuring the round-up up to lastHeartbeat (+ one
    // heartbeat interval of grace) guarantees a user is never billed
    // for time after they vanished — even if the priest leaves the
    // call open and taps End minutes later. On a live call the
    // heartbeat is always fresh, so this cap equals "now" and normal
    // billing is unchanged.
    const HEARTBEAT_GRACE_MS = 45 * 1000;
    const lastHeartbeatMs = (_w = session.lastHeartbeat) === null || _w === void 0 ? void 0 : _w.toMillis();
    const billableUntilMs = lastHeartbeatMs ?
        Math.min(Date.now(), lastHeartbeatMs + HEARTBEAT_GRACE_MS) :
        Date.now();
    if (session.status === "active" && connectedEpochMs !== null) {
        const elapsedSec = Math.max(0, Math.floor((billableUntilMs - connectedEpochMs) / 1000));
        const totalMinutesUsed = Math.ceil(elapsedSec / 60);
        const unbilledMinutes = totalMinutesUsed - finalDuration;
        if (unbilledMinutes > 0) {
            const userRef = db.doc(`users/${session.userId}`);
            const userSnap = await userRef.get();
            const currentBalance = Number((_y = (_x = userSnap.data()) === null || _x === void 0 ? void 0 : _x.coinBalance) !== null && _y !== void 0 ? _y : 0);
            const affordableMinutes = Math.min(unbilledMinutes, Math.floor(currentBalance / rate));
            if (affordableMinutes > 0) {
                const priestEarning = Math.floor(rate * (1 - commission / 100));
                const totalCharge = affordableMinutes * rate;
                const totalPriestEarning = affordableMinutes * priestEarning;
                const priestRef = db.doc(`priests/${session.priestId}`);
                const batch = db.batch();
                batch.update(userRef, {
                    coinBalance: admin.firestore.FieldValue.increment(-totalCharge),
                });
                batch.update(priestRef, {
                    walletBalance: admin.firestore.FieldValue.increment(totalPriestEarning),
                    totalEarnings: admin.firestore.FieldValue.increment(totalPriestEarning),
                });
                const txRef = db.collection("wallet_transactions").doc();
                batch.set(txRef, {
                    userId: session.userId,
                    type: "session_charge",
                    sessionId: sessionId,
                    coins: -totalCharge,
                    description: `${session.type} session — partial-minute rollup`,
                    createdAt: admin.firestore.FieldValue.serverTimestamp(),
                });
                await batch.commit();
                finalDuration += affordableMinutes;
                finalTotalCharged += totalCharge;
                finalPriestEarnings += totalPriestEarning;
            }
        }
    }
    await sessionRef.update(Object.assign({ status: "completed", endedAt: admin.firestore.FieldValue.serverTimestamp(), durationMinutes: finalDuration, totalCharged: finalTotalCharged, priestEarnings: finalPriestEarnings, endedBy: uid === session.userId ? "user" : "priest", 
        // Clear the concurrency claim now that we're terminal.
        settling: admin.firestore.FieldValue.delete() }, (connectedEpochMs === null ? { endReason: "connection_failed" } : {})));
    // Bump the priest's session count on the priest doc so the
    // dashboard stat reflects this session immediately, without
    // waiting for an aggregation job. Also clear isBusy — the
    // session system owns isBusy (acceptSession sets it true,
    // we clear it here) so the user-feed reflection of "this
    // priest is busy" drops the moment the session ends, no
    // matter who ended it.
    await db.doc(`priests/${session.priestId}`).update({
        totalSessions: admin.firestore.FieldValue.increment(1),
        isBusy: false,
    });
    const finalUserSnap = await db.doc(`users/${session.userId}`).get();
    const finalUserBalance = Number((_0 = (_z = finalUserSnap.data()) === null || _z === void 0 ? void 0 : _z.coinBalance) !== null && _0 !== void 0 ? _0 : 0);
    // Never-connected call ended by a party (e.g. the priest's 60s
    // remote-join timer firing): send the clear "couldn't connect, no
    // charge" copy instead of a "Session Complete · 0 min" summary,
    // then return. finalDuration / totals are all 0 here.
    if (connectedEpochMs === null) {
        await (0, notifyConnectionFailed_1.notifyConnectionFailed)({ session: session, sessionId: sessionId });
        return {
            durationMinutes: finalDuration,
            totalCharged: finalTotalCharged,
            priestEarnings: finalPriestEarnings,
            newBalance: finalUserBalance,
        };
    }
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