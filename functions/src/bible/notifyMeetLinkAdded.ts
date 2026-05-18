import {onCall, HttpsError} from "firebase-functions/v2/https";
import * as admin from "firebase-admin";
import {REGION} from "../config/constants";
import {sendPushNotification} from "../notifications/sendPush";

const db = admin.firestore();

// 200 keeps batches well below the 500-op Firestore limit and caps
// concurrent FCM calls to a level that works in the default memory
// tier without thrashing. Matches the cancellation fanout sizing.
const FANOUT_CHUNK_SIZE = 200;

// Called by the priest's client immediately after `updateMeetingLink`
// succeeds. Fans an in-app inbox doc + OS push out to every active
// registrant so paid users know the link is finally available and
// registered-not-paid users see a new reason to convert.
//
// Defences:
//   • Caller must be authenticated.
//   • Caller must own the session.
//   • The fanout runs unconditionally — the repository only calls
//     this CF when `link` was actually set (non-empty), so a "link
//     cleared" priest action does NOT trigger the CF.
export const notifyMeetLinkAdded = onCall(
  {region: REGION},
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Must be logged in");
    }

    const callerUid = request.auth.uid;
    const {sessionId} = request.data as {sessionId?: string};

    if (!sessionId || typeof sessionId !== "string") {
      throw new HttpsError("invalid-argument", "sessionId required");
    }

    const sessionDoc = await db.doc(`bible_sessions/${sessionId}`).get();
    if (!sessionDoc.exists) {
      throw new HttpsError("not-found", "Session not found");
    }

    const session = sessionDoc.data() ?? {};
    if (session.priestId !== callerUid) {
      throw new HttpsError(
        "permission-denied",
        "You don't own this session",
      );
    }

    const sessionTitle = String(session.title ?? "Bible Session");
    const priestName = String(session.priestName ?? "The speaker");

    const regsSnap = await db
      .collection(`bible_sessions/${sessionId}/registrations`)
      .get();
    const activeRegs = regsSnap.docs.filter(
      (d) => d.data().status !== "cancelled",
    );

    const inboxBody =
      `${priestName} has shared the meeting link for "${sessionTitle}". ` +
      "See you there!";
    const pushBody = `${priestName} shared the link for "${sessionTitle}"`;

    let attempted = 0;

    for (let i = 0; i < activeRegs.length; i += FANOUT_CHUNK_SIZE) {
      const chunk = activeRegs.slice(i, i + FANOUT_CHUNK_SIZE);

      const batch = db.batch();
      for (const reg of chunk) {
        const notifRef = db.collection("notifications").doc();
        batch.set(notifRef, {
          userId: reg.id,
          type: "bible_session_link_added",
          title: "📖 Meeting Link Ready",
          body: inboxBody,
          sessionId,
          data: {sessionId},
          isRead: false,
          createdAt: admin.firestore.FieldValue.serverTimestamp(),
        });
      }
      try {
        await batch.commit();
      } catch (err) {
        // Best-effort once we're mid-fanout. The link is already
        // saved on the session doc, so even if the inbox writes
        // partially fail, the pushes below still surface the news
        // and the user can refresh the detail page.
        console.error(
          "[notifyMeetLinkAdded] notif batch failed for " +
            `${sessionId} (chunk start=${i}):`,
          err,
        );
      }

      await Promise.all(
        chunk.map(async (doc) => {
          attempted++;
          await sendPushNotification({
            userId: doc.id,
            title: "📖 Meeting Link Ready",
            body: pushBody,
            data: {
              type: "bible_session_link_added",
              sessionId,
              route: `/bible/detail/${sessionId}`,
            },
          });
        }),
      );
    }

    return {attempted};
  },
);
