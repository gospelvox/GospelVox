"use strict";
// Shared helper: tell BOTH sides that a session never reached a real
// connection and therefore nobody was charged. Used everywhere a
// connection_failed settlement happens — billingTick (connect grace
// expired), the watchdog (abandoned before connecting), and
// endSession (a party ended a call that never connected). Keeping the
// copy in one place guarantees the user and priest always see the
// same clear, friendly "couldn't connect — no charge" message instead
// of a confusing "0 min / 0 coins" summary.
//
// Pure write; the caller has already flipped the session to its
// terminal state. Fires at most once per session because each caller
// only reaches it on the single transition into the terminal state.
Object.defineProperty(exports, "__esModule", { value: true });
exports.notifyConnectionFailed = notifyConnectionFailed;
const admin = require("firebase-admin");
const sendPush_1 = require("../notifications/sendPush");
const db = admin.firestore();
async function notifyConnectionFailed(payload) {
    var _a, _b, _c;
    const { session, sessionId } = payload;
    const userId = session.userId;
    const priestId = session.priestId;
    const sessionType = (_a = session.type) !== null && _a !== void 0 ? _a : "chat";
    // "call" reads naturally for voice; "chat" for everything else.
    const label = sessionType === "voice" ? "call" : "chat";
    const priestName = (_b = session.priestName) !== null && _b !== void 0 ? _b : "the speaker";
    const userName = (_c = session.userName) !== null && _c !== void 0 ? _c : "the user";
    const userBody = `Your ${label} with ${priestName} couldn't connect. ` +
        "You were not charged.";
    const priestBody = `Your ${label} with ${userName} couldn't connect — ` +
        "no charge was made.";
    // Inbox docs first (source of truth), then best-effort push.
    const batch = db.batch();
    if (userId) {
        const userNotifRef = db.collection("notifications").doc();
        batch.set(userNotifRef, {
            userId: userId,
            type: "connection_failed",
            title: "Couldn't Connect",
            body: userBody,
            sessionId: sessionId,
            isRead: false,
            createdAt: admin.firestore.FieldValue.serverTimestamp(),
        });
    }
    if (priestId) {
        const priestNotifRef = db.collection("notifications").doc();
        batch.set(priestNotifRef, {
            userId: priestId,
            type: "connection_failed",
            title: "Couldn't Connect",
            body: priestBody,
            sessionId: sessionId,
            isRead: false,
            createdAt: admin.firestore.FieldValue.serverTimestamp(),
        });
    }
    await batch.commit();
    if (userId) {
        await (0, sendPush_1.sendPushNotification)({
            userId: userId,
            title: "Couldn't Connect",
            body: userBody,
            data: {
                type: "connection_failed",
                sessionId: sessionId,
                route: "/user",
            },
        }).catch(() => {
            // Push is best-effort; the inbox doc already landed.
        });
    }
    if (priestId) {
        await (0, sendPush_1.sendPushNotification)({
            userId: priestId,
            title: "Couldn't Connect",
            body: priestBody,
            data: {
                type: "connection_failed",
                sessionId: sessionId,
                route: "/priest",
            },
        }).catch(() => {
            // Push is best-effort; the inbox doc already landed.
        });
    }
}
//# sourceMappingURL=notifyConnectionFailed.js.map