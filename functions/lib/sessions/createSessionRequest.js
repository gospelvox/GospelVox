"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.createSessionRequest = void 0;
const https_1 = require("firebase-functions/v2/https");
const admin = require("firebase-admin");
const constants_1 = require("../config/constants");
const sendPush_1 = require("../notifications/sendPush");
const db = admin.firestore();
// Helper invoked when we reject a request because the priest is
// already busy (mid-session). The priest didn't see the request,
// but the user's intent was real, so we still want it to surface
// on the priest's missed-requests page after their current session
// ends. Mirrors the shape that notifyPriestMissedRequest writes
// for expired sessions, minus the session-bound fields (there's
// no session doc to anchor to — the request was rejected before
// creation). Push is intentionally skipped: the priest is busy
// right now, no point waking them mid-session.
async function writeBusyMissedRequest(args) {
    try {
        const action = args.type === "voice" ? "call" : "chat with";
        await db.collection("notifications").add({
            userId: args.priestId,
            type: "missed_request",
            title: "Missed Request",
            body: `${args.requesterName} tried to ${action} you while you ` +
                "were in another session",
            requesterId: args.requesterId,
            requesterName: args.requesterName,
            requesterPhotoUrl: args.requesterPhotoUrl,
            sessionType: args.type,
            // No sessionId — there is no session doc; this notification
            // is purely the intent record.
            isRead: false,
            createdAt: admin.firestore.FieldValue.serverTimestamp(),
        });
    }
    catch (e) {
        // Swallow — failing to write the missed-request notification
        // shouldn't change the user-facing error from this CF, which
        // is "priest-busy" regardless. The intent record is best-effort.
        console.error("[createSessionRequest] busy-miss write failed:", e);
    }
}
// Creates a pending session between a user and a priest. This is
// the ONLY entry point for session creation — the Flutter client
// never writes to the sessions collection directly, because we need
// to atomically:
//   • lock the per-minute rate from app_config (so later admin rate
//     edits can't retro-bill)
//   • verify the user has at least one minute's worth of coins
//   • verify the priest is actually online and not already busy
//   • verify the user doesn't already have a pending request
//     (otherwise a rapid double-tap could spawn two sessions)
//
// The function also writes a notification doc so the priest's
// sendNotification CF can wake up their push channel in parallel.
exports.createSessionRequest = (0, https_1.onCall)({ region: constants_1.REGION }, async (request) => {
    var _a, _b, _c, _d, _e, _f, _g, _h, _j, _k, _l, _m, _o, _p, _q, _r, _s, _t, _u, _v;
    if (!request.auth) {
        throw new https_1.HttpsError("unauthenticated", "Must be logged in");
    }
    const uid = request.auth.uid;
    const data = (_a = request.data) !== null && _a !== void 0 ? _a : {};
    const priestId = data.priestId;
    const type = data.type;
    if (!priestId || !type) {
        throw new https_1.HttpsError("invalid-argument", "Missing priestId or type");
    }
    if (type !== "chat" && type !== "voice") {
        throw new https_1.HttpsError("invalid-argument", "Type must be 'chat' or 'voice'");
    }
    if (priestId === uid) {
        throw new https_1.HttpsError("invalid-argument", "Cannot request a session with yourself");
    }
    // 1. User + balance
    const userSnap = await db.doc(`users/${uid}`).get();
    if (!userSnap.exists) {
        throw new https_1.HttpsError("not-found", "User not found");
    }
    const userData = (_b = userSnap.data()) !== null && _b !== void 0 ? _b : {};
    const coinBalance = Number((_c = userData.coinBalance) !== null && _c !== void 0 ? _c : 0);
    // 2. Rates + commission (locked into the doc so admin edits
    //    after this moment can't rewrite what the user owes)
    const settingsSnap = await db.doc("app_config/settings").get();
    const settings = (_d = settingsSnap.data()) !== null && _d !== void 0 ? _d : {};
    const ratePerMinute = type === "chat"
        ? Number((_e = settings.chatRatePerMinute) !== null && _e !== void 0 ? _e : 10)
        : Number((_f = settings.voiceRatePerMinute) !== null && _f !== void 0 ? _f : 15);
    const commissionPercent = Number((_g = settings.commissionPercent) !== null && _g !== void 0 ? _g : 20);
    // Minimum balance gate — user must have enough coins for at
    // least N minutes of conversation. Prevents the "session ends
    // 30 seconds in" frustration the previous one-minute floor
    // allowed. Configurable from the admin settings doc; defaults
    // to 5 to match the AstroTalk-style "5-minute minimum" pattern
    // users expect from this category.
    const minSessionMinutes = Number((_h = settings.minSessionMinutes) !== null && _h !== void 0 ? _h : 5);
    const minRequiredBalance = ratePerMinute * minSessionMinutes;
    // 3. Affordability — at least the minimum-minutes floor
    if (coinBalance < minRequiredBalance) {
        throw new https_1.HttpsError("failed-precondition", "insufficient-balance");
    }
    // 4. Priest exists, is online, and isn't busy
    const priestSnap = await db.doc(`priests/${priestId}`).get();
    if (!priestSnap.exists) {
        throw new https_1.HttpsError("not-found", "Speaker not found");
    }
    const priestData = (_j = priestSnap.data()) !== null && _j !== void 0 ? _j : {};
    if (!priestData.isOnline) {
        // No missed-request write here — the priest deliberately
        // chose to be offline (or the watchdog flipped them so via
        // stale heartbeat). Surfacing every offline-priest tap as
        // a missed-request would spam them when they come back.
        throw new https_1.HttpsError("failed-precondition", "priest-offline");
    }
    // Priest is teaching a live Bible session — block the ring so
    // they aren't disturbed mid-Google-Meet. The lock has TWO
    // independent signals and we trust BOTH:
    //
    //   1. liveBibleSessionId — set atomically by startBibleSession.
    //      Cleared by completeBibleSession (manual) AND the
    //      bibleSessionReminders auto-complete cron.
    //
    //   2. bibleSessionLockedUntil — a wall-clock deadline
    //      (startedAt + durationMinutes + 15min). Acts as the
    //      self-healing guard: if every CF that's supposed to
    //      clear the field fails, once this timestamp passes the
    //      gate treats the priest as released anyway.
    //
    // The user still gets a missed-request notification so the
    // priest sees who tried to reach them while they were teaching
    // — same intent-capture semantics as priest-busy.
    const lockedSessionId = priestData.liveBibleSessionId;
    if (typeof lockedSessionId === "string" &&
        lockedSessionId.length > 0) {
        const lockedUntilTs = priestData.bibleSessionLockedUntil;
        const lockedUntil = lockedUntilTs === null || lockedUntilTs === void 0 ? void 0 : lockedUntilTs.toDate();
        const stillLocked = !lockedUntil || lockedUntil.getTime() > Date.now();
        if (stillLocked) {
            await writeBusyMissedRequest({
                priestId: priestId,
                requesterId: uid,
                requesterName: (_k = userData.displayName) !== null && _k !== void 0 ? _k : "",
                requesterPhotoUrl: (_l = userData.photoUrl) !== null && _l !== void 0 ? _l : "",
                type: type,
            });
            throw new https_1.HttpsError("failed-precondition", "priest-in-bible-session");
        }
    }
    if (priestData.isBusy === true) {
        await writeBusyMissedRequest({
            priestId: priestId,
            requesterId: uid,
            requesterName: (_m = userData.displayName) !== null && _m !== void 0 ? _m : "",
            requesterPhotoUrl: (_o = userData.photoUrl) !== null && _o !== void 0 ? _o : "",
            type: type,
        });
        throw new https_1.HttpsError("failed-precondition", "priest-busy");
    }
    // 5. Priest already mid-session? Block so two users can't call
    //    the same priest at once. Same intent-capture as the
    //    isBusy branch above — the priest is mid-session and
    //    shouldn't be interrupted, but the user's tap was real.
    const activeSessions = await db
        .collection("sessions")
        .where("priestId", "==", priestId)
        .where("status", "==", "active")
        .limit(1)
        .get();
    if (!activeSessions.empty) {
        await writeBusyMissedRequest({
            priestId: priestId,
            requesterId: uid,
            requesterName: (_p = userData.displayName) !== null && _p !== void 0 ? _p : "",
            requesterPhotoUrl: (_q = userData.photoUrl) !== null && _q !== void 0 ? _q : "",
            type: type,
        });
        throw new https_1.HttpsError("failed-precondition", "priest-busy");
    }
    // 6. Reconcile any prior pending requests from this user.
    //    Rule: tapping Chat again always wins — we expire whatever
    //    came before and create a fresh session. This trades the
    //    "rapid double-tap dedupe" (which the UI prevents anyway
    //    by pushing a single waiting route) for a vastly better
    //    recovery story when the client's cancel didn't land
    //    (app killed, Firestore rules rejected, etc.).
    const pendingRequests = await db
        .collection("sessions")
        .where("userId", "==", uid)
        .where("status", "==", "pending")
        .get();
    if (!pendingRequests.empty) {
        const cleanupBatch = db.batch();
        for (const doc of pendingRequests.docs) {
            cleanupBatch.update(doc.ref, {
                status: "expired",
                endedAt: admin.firestore.FieldValue.serverTimestamp(),
                endReason: "superseded_by_new_request",
            });
        }
        await cleanupBatch.commit();
        console.log(`[createSessionRequest] Expired ${pendingRequests.size} ` +
            `prior pending session(s) for user ${uid}`);
    }
    // 7. Finally, create the session doc AND mark the priest busy
    //    in a single atomic batch. Setting isBusy at request time
    //    (not at accept time) is what gives the user feed correct
    //    phone-call semantics: the moment user A starts dialling
    //    priest B, user C trying to dial B sees them as Busy and
    //    is blocked at step 4 above. Without this, B looks Online
    //    to C until B taps Accept, allowing concurrent rings.
    //    The cleanup is handled by onSessionTerminal, which clears
    //    isBusy whenever the session reaches any terminal status.
    const sessionRef = db.collection("sessions").doc();
    const createBatch = db.batch();
    createBatch.set(sessionRef, {
        userId: uid,
        priestId: priestId,
        type: type,
        status: "pending",
        ratePerMinute: ratePerMinute,
        commissionPercent: commissionPercent,
        userBalance: coinBalance,
        durationMinutes: 0,
        totalCharged: 0,
        priestEarnings: 0,
        userName: (_r = userData.displayName) !== null && _r !== void 0 ? _r : "",
        userPhotoUrl: (_s = userData.photoUrl) !== null && _s !== void 0 ? _s : "",
        priestName: (_t = priestData.fullName) !== null && _t !== void 0 ? _t : "",
        priestPhotoUrl: (_u = priestData.photoUrl) !== null && _u !== void 0 ? _u : "",
        priestDenomination: (_v = priestData.denomination) !== null && _v !== void 0 ? _v : "",
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
        lastHeartbeat: admin.firestore.FieldValue.serverTimestamp(),
    });
    createBatch.update(db.doc(`priests/${priestId}`), {
        isBusy: true,
    });
    await createBatch.commit();
    // 8. Drop a notification for the priest. sendNotification reads
    //    this collection and dispatches the push; keeping it as a
    //    separate write so this CF stays fast on the critical path.
    await db.collection("notifications").add({
        userId: priestId,
        type: "session_request",
        title: `New ${type} request`,
        body: `${userData.displayName || "A user"} wants to ${type === "chat" ? "chat with" : "call"} you`,
        sessionId: sessionRef.id,
        isRead: false,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    // 9. Push the priest's device(s) so they hear the request even
    //    if their app is backgrounded. Best-effort — sendPush
    //    swallows its own failures so this never blocks return.
    //
    //    Route is "/priest" (the dashboard) NOT "/priest/incoming".
    //    The incoming-request page requires a SessionModel passed via
    //    extras — a notification tap can only carry string data, so
    //    navigating directly would land on the "Session unavailable"
    //    placeholder. The dashboard's pending-request stream listener
    //    detects the same session and auto-routes to /priest/incoming
    //    with the full hydrated model.
    await (0, sendPush_1.sendPushNotification)({
        userId: priestId,
        title: `New ${type} request`,
        body: `${userData.displayName || "A user"} wants to ${type === "chat" ? "chat with" : "call"} you`,
        data: {
            type: "session_request",
            sessionId: sessionRef.id,
            route: "/priest",
        },
    });
    return { sessionId: sessionRef.id };
});
//# sourceMappingURL=createSessionRequest.js.map