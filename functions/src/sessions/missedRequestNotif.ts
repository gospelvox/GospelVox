// Shared helper for notifying a priest about a missed request —
// either the user-side 60s countdown firing expireSessionRequest,
// or the watchdog 5-minute cron sweeping up stuck pending sessions
// where the cubit's CF call never landed.
//
// Both paths produce identical notifications + push, so the bodies
// are colocated here. The function is a pure write — caller is
// responsible for already having marked the session expired so a
// crash between the status flip and this helper can't double-notify.

import * as admin from "firebase-admin";

import {sendPushNotification} from "../notifications/sendPush";

const db = admin.firestore();

interface MissedRequestPayload {
  // Session doc data, already loaded by the caller. We only read
  // priestId / userId / userName / userPhotoUrl / type from it.
  session: admin.firestore.DocumentData;
  // Doc id of the session the user tried to start. Stamped on the
  // notification so admins debugging a "missing notif" report can
  // grep back to the source.
  sessionId: string;
}

export async function notifyPriestMissedRequest(
  payload: MissedRequestPayload
): Promise<void> {
  const {session, sessionId} = payload;
  const priestId = session.priestId as string | undefined;
  if (!priestId) return;

  const userName = (session.userName as string | undefined) ?? "A user";
  const userPhotoUrl =
    (session.userPhotoUrl as string | undefined) ?? "";
  const sessionType =
    (session.type as string | undefined) ?? "chat";
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
    requesterId: session.userId ?? "",
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
  await sendPushNotification({
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
