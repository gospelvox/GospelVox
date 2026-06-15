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

import * as admin from "firebase-admin";

import {sendPushNotification} from "../notifications/sendPush";

const db = admin.firestore();

interface ConnectionFailedPayload {
  // Session doc data, already loaded by the caller. Reads userId,
  // priestId, type, userName, priestName.
  session: admin.firestore.DocumentData;
  // Doc id of the session, stamped on the notification for deep-link
  // + debugging.
  sessionId: string;
}

export async function notifyConnectionFailed(
  payload: ConnectionFailedPayload
): Promise<void> {
  const {session, sessionId} = payload;
  const userId = session.userId as string | undefined;
  const priestId = session.priestId as string | undefined;

  const sessionType = (session.type as string | undefined) ?? "chat";
  // "call" reads naturally for voice; "chat" for everything else.
  const label = sessionType === "voice" ? "call" : "chat";
  const priestName =
    (session.priestName as string | undefined) ?? "the speaker";
  const userName = (session.userName as string | undefined) ?? "the user";

  const userBody =
    `Your ${label} with ${priestName} couldn't connect. ` +
    "You were not charged.";
  const priestBody =
    `Your ${label} with ${userName} couldn't connect — ` +
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
    await sendPushNotification({
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
    await sendPushNotification({
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
