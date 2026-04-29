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

import * as admin from "firebase-admin";

const db = admin.firestore();

interface PushPayload {
  userId: string;
  title: string;
  body: string;
  data?: Record<string, string>;
}

export async function sendPushNotification(
  payload: PushPayload
): Promise<void> {
  try {
    const userDoc = await db.doc(`users/${payload.userId}`).get();
    const tokens = userDoc.data()?.fcmTokens as string[] | undefined;

    if (!tokens || tokens.length === 0) {
      console.log(`[Push] No FCM tokens for user ${payload.userId}`);
      return;
    }

    // Channel routing on Android — session_request lands on the
    // max-importance channel so OEM heads-up banners + sound fire
    // even when the priest's app is backgrounded under aggressive
    // battery managers.
    const isSessionRequest = payload.data?.type === "session_request";
    const channelId = isSessionRequest
      ? "gospel_vox_sessions"
      : "gospel_vox_default";

    const message: admin.messaging.MulticastMessage = {
      tokens: tokens,
      notification: {
        title: payload.title,
        body: payload.body,
      },
      data: payload.data ?? {},
      android: {
        priority: "high",
        notification: {
          channelId: channelId,
          priority: "max",
          defaultSound: true,
        },
      },
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

    console.log(
      `[Push] Sent to ${payload.userId}: ` +
        `${response.successCount} success, ` +
        `${response.failureCount} failures`
    );

    // Stale-token cleanup. FCM returns these specific error codes
    // for tokens that will never succeed again — keeping them in
    // Firestore wastes a multicast slot on every future push.
    if (response.failureCount > 0) {
      const staleTokens: string[] = [];

      response.responses.forEach((resp, idx) => {
        if (!resp.success) {
          const errorCode = resp.error?.code;
          if (
            errorCode === "messaging/invalid-registration-token" ||
            errorCode === "messaging/registration-token-not-registered"
          ) {
            staleTokens.push(tokens[idx]);
          }
        }
      });

      if (staleTokens.length > 0) {
        await db.doc(`users/${payload.userId}`).update({
          fcmTokens: admin.firestore.FieldValue.arrayRemove(...staleTokens),
        });
        console.log(
          `[Push] Removed ${staleTokens.length} stale tokens ` +
            `for ${payload.userId}`
        );
      }
    }
  } catch (error) {
    // Never re-throw — a push failure must not roll back the calling
    // CF. The notification doc was already written; the user will see
    // it in the in-app inbox even if the OS-level push never fires.
    console.error(`[Push] Error sending to ${payload.userId}:`, error);
  }
}
