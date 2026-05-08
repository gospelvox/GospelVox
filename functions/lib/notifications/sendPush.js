"use strict";
// Internal helper that sends an FCM multicast push to every device
// registered for a user. NOT a callable — exists only to be invoked
// from inside other Cloud Functions after they've written a
// notification doc to Firestore.
//
// Contract:
//   • The notification doc in Firestore is the source of truth.
//   • Push delivery is best-effort. Any failure here is logged and
//     swallowed so the calling CF still returns success — losing a
//     push is recoverable (the in-app inbox still shows it), losing
//     the notification doc is not.
//   • Stale tokens (user uninstalled, token expired) are removed
//     from users/{uid}.fcmTokens automatically so future sends
//     don't keep paying the round-trip on dead tokens.
Object.defineProperty(exports, "__esModule", { value: true });
exports.sendPushNotification = sendPushNotification;
const admin = require("firebase-admin");
const db = admin.firestore();
async function sendPushNotification(payload) {
    var _a, _b, _c;
    try {
        const userDoc = await db.doc(`users/${payload.userId}`).get();
        const tokens = (_a = userDoc.data()) === null || _a === void 0 ? void 0 : _a.fcmTokens;
        if (!tokens || tokens.length === 0) {
            console.log(`[Push] No FCM tokens for user ${payload.userId}`);
            return;
        }
        // Channel routing on Android — session_request lands on the
        // max-importance channel so OEM heads-up banners + sound fire
        // even when the priest's app is backgrounded under aggressive
        // battery managers.
        //
        // Channel id is bumped to gospel_vox_sessions_v2 for session
        // requests because Android caches channel settings on first
        // create — a priest who installed before sound/vibrate were
        // wired correctly is permanently stuck with a silent channel
        // unless we route them to a fresh channel id. v2 is the
        // current channel; the old gospel_vox_sessions still exists
        // on legacy installs but is no longer targeted.
        const isSessionRequest = ((_b = payload.data) === null || _b === void 0 ? void 0 : _b.type) === "session_request";
        const channelId = isSessionRequest
            ? "gospel_vox_sessions_v2"
            : "gospel_vox_default";
        // session_request uses notification+data (NOT data-only) for
        // OEM compatibility. Samsung / Xiaomi / Realme aggressively
        // block data-only FCM messages from waking a killed app — the
        // background isolate never runs, the priest never sees the
        // call, and the request silently expires.
        //
        // Notification+data is the well-behaved shape: when the app is
        // killed the OS-rendered notification is shown reliably across
        // every device. The trade-off is we lose Accept/Decline action
        // buttons (FCM-level notifications don't carry custom actions),
        // but tapping the body still launches the app onto the dashboard
        // where the existing pending-request stream routes to the full
        // /priest/incoming UI.
        //
        // Foreground messages remain unaffected — the dashboard's
        // pending-request Firestore stream is the source of truth while
        // the app is open. The system notification just adds a tray
        // entry that mirrors what the priest already sees on screen.
        //
        // 60-second TTL on session_request so a queued message arriving
        // after the request already expired in Firestore is dropped at
        // the FCM gateway instead of waking the priest with a stale
        // "Asha is calling" banner. Other types use FCM's default 4-week
        // TTL.
        //
        // Lock-screen rendering: the Admin SDK doesn't expose
        // android.notification.full_screen_intent, so we can't request a
        // true call-style activity from here. Instead we max out every
        // FCM-level lever the SDK does support — priority=max,
        // visibility=public, defaultVibrateTimings — and pair them with
        // an Importance.max channel on the device. Together those
        // produce a heads-up banner over the lock screen with sound +
        // vibrate, which is the practical equivalent on most OEMs even
        // without the dedicated full-screen UI. The trade-off is
        // intentional: trustworthy delivery on every device beats a
        // fancy lock-screen activity that fires on 60% of them.
        const ttlMillis = isSessionRequest ? 60 * 1000 : undefined;
        const androidNotification = Object.assign({ channelId: channelId, priority: "max", defaultSound: true }, (isSessionRequest ? {
            defaultVibrateTimings: true,
            visibility: "public",
        } : {}));
        const message = {
            tokens: tokens,
            notification: {
                title: payload.title,
                body: payload.body,
            },
            data: (_c = payload.data) !== null && _c !== void 0 ? _c : {},
            android: Object.assign(Object.assign({ priority: "high" }, (ttlMillis !== undefined ? { ttl: ttlMillis } : {})), { notification: androidNotification }),
            apns: {
                payload: {
                    aps: {
                        alert: {
                            title: payload.title,
                            body: payload.body,
                        },
                        badge: 1,
                        sound: "default",
                        contentAvailable: true,
                    },
                },
            },
        };
        const response = await admin.messaging().sendEachForMulticast(message);
        console.log(`[Push] Sent to ${payload.userId}: ` +
            `${response.successCount} success, ` +
            `${response.failureCount} failures`);
        // Stale-token cleanup. FCM returns these specific error codes
        // for tokens that will never succeed again — keeping them in
        // Firestore wastes a multicast slot on every future push.
        if (response.failureCount > 0) {
            const staleTokens = [];
            response.responses.forEach((resp, idx) => {
                var _a;
                if (!resp.success) {
                    const errorCode = (_a = resp.error) === null || _a === void 0 ? void 0 : _a.code;
                    if (errorCode === "messaging/invalid-registration-token" ||
                        errorCode === "messaging/registration-token-not-registered") {
                        staleTokens.push(tokens[idx]);
                    }
                }
            });
            if (staleTokens.length > 0) {
                await db.doc(`users/${payload.userId}`).update({
                    fcmTokens: admin.firestore.FieldValue.arrayRemove(...staleTokens),
                });
                console.log(`[Push] Removed ${staleTokens.length} stale tokens ` +
                    `for ${payload.userId}`);
            }
        }
    }
    catch (error) {
        // Never re-throw — a push failure must not roll back the calling
        // CF. The notification doc was already written; the user will see
        // it in the in-app inbox even if the OS-level push never fires.
        console.error(`[Push] Error sending to ${payload.userId}:`, error);
    }
}
//# sourceMappingURL=sendPush.js.map