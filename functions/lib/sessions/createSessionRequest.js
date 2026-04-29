"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.createSessionRequest = void 0;
const https_1 = require("firebase-functions/v2/https");
const admin = require("firebase-admin");
const constants_1 = require("../config/constants");
const sendPush_1 = require("../notifications/sendPush");
const db = admin.firestore();
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
    var _a, _b, _c, _d, _e, _f, _g, _h, _j, _k, _l, _m, _o;
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
    // 3. Affordability — at least one minute's worth
    if (coinBalance < ratePerMinute) {
        throw new https_1.HttpsError("failed-precondition", "insufficient-balance");
    }
    // 4. Priest exists, is online, and isn't busy
    const priestSnap = await db.doc(`priests/${priestId}`).get();
    if (!priestSnap.exists) {
        throw new https_1.HttpsError("not-found", "Speaker not found");
    }
    const priestData = (_h = priestSnap.data()) !== null && _h !== void 0 ? _h : {};
    if (!priestData.isOnline) {
        throw new https_1.HttpsError("failed-precondition", "priest-offline");
    }
    if (priestData.isBusy === true) {
        throw new https_1.HttpsError("failed-precondition", "priest-busy");
    }
    // 5. Priest already mid-session? Block so two users can't call
    //    the same priest at once.
    const activeSessions = await db
        .collection("sessions")
        .where("priestId", "==", priestId)
        .where("status", "==", "active")
        .limit(1)
        .get();
    if (!activeSessions.empty) {
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
    // 7. Finally, create the session doc. All denormalised display
    //    fields come from the already-fetched priest + user snaps
    //    so the UI can render both ends without a second read.
    const sessionRef = db.collection("sessions").doc();
    await sessionRef.set({
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
        userName: (_j = userData.displayName) !== null && _j !== void 0 ? _j : "",
        userPhotoUrl: (_k = userData.photoUrl) !== null && _k !== void 0 ? _k : "",
        priestName: (_l = priestData.fullName) !== null && _l !== void 0 ? _l : "",
        priestPhotoUrl: (_m = priestData.photoUrl) !== null && _m !== void 0 ? _m : "",
        priestDenomination: (_o = priestData.denomination) !== null && _o !== void 0 ? _o : "",
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
        lastHeartbeat: admin.firestore.FieldValue.serverTimestamp(),
    });
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