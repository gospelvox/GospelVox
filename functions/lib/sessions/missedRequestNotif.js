"use strict";
// Shared helper for notifying a priest about a missed request —
// either the user-side 60s countdown firing expireSessionRequest,
// or the watchdog 5-minute cron sweeping up stuck pending sessions
// where the cubit's CF call never landed.
//
// Both paths produce identical notifications + push, so the bodies
// are colocated here. The function is a pure write — caller is
// responsible for already having marked the session expired so a
// crash between the status flip and this helper can't double-notify.
Object.defineProperty(exports, "__esModule", { value: true });
exports.notifyPriestMissedRequest = notifyPriestMissedRequest;
const admin = require("firebase-admin");
const sendPush_1 = require("../notifications/sendPush");
const db = admin.firestore();
async function notifyPriestMissedRequest(payload) {
    var _a, _b, _c, _d;
    const { session, sessionId } = payload;
    const priestId = session.priestId;
    if (!priestId)
        return;
    const userName = (_a = session.userName) !== null && _a !== void 0 ? _a : "A user";
    const userPhotoUrl = (_b = session.userPhotoUrl) !== null && _b !== void 0 ? _b : "";
    const sessionType = (_c = session.type) !== null && _c !== void 0 ? _c : "chat";
    const action = sessionType === "voice" ? "call" : "chat with";
    const body = `${userName} tried to ${action} you`;
    // Inbox doc — picked up by the priest's notifications page and
    // the dashboard's unread-badge query. requesterId/Name/PhotoUrl
    // are stored separately from the user-message convention so the
    // priest's inbox renderer can show the user's avatar without
    // confusing the "priest sent message to user" flow that uses
    // priestId/priestName/priestPhotoUrl.
    await db.collection("notifications").add({
        userId: priestId,
        type: "missed_request",
        title: "Missed Request",
        body: body,
        requesterId: (_d = session.userId) !== null && _d !== void 0 ? _d : "",
        requesterName: userName,
        requesterPhotoUrl: userPhotoUrl,
        sessionType: sessionType,
        sessionId: sessionId,
        isRead: false,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    // Push delivery — best effort. The inbox doc is the source of
    // truth; a missing push just means the priest sees the missed
    // request next time they open the app rather than as a banner.
    await (0, sendPush_1.sendPushNotification)({
        userId: priestId,
        title: "Missed Request",
        body: body,
        data: {
            type: "missed_request",
            // Deep link straight to My Users so a tap lands them where
            // they can act on the missed request — message the user back.
            route: "/priest/my-users",
            sessionId: sessionId,
        },
    }).catch(() => {
        // sendPushNotification logs internally; swallow so the caller
        // still returns success even if FCM is briefly unreachable.
    });
}
//# sourceMappingURL=missedRequestNotif.js.map