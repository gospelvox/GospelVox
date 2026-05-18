import {onCall, HttpsError} from "firebase-functions/v2/https";
import * as admin from "firebase-admin";
import {REGION} from "../config/constants";
import {sendPushNotification} from "../notifications/sendPush";

const db = admin.firestore();

// Server-side fanout for "the priest cancelled this Bible session".
// The priest's client is responsible for ONE thing during a cancel —
// flipping bible_sessions/{id}.status to "cancelled" — and then it
// invokes this CF, which owns both fanout halves:
//
//   1. In-app inbox: a /notifications doc per active registrant.
//      Firestore rules deny client-side `notifications.create`
//      (correctly — clients shouldn't be able to write notifications
//      addressed to other users), so this MUST be done with the
//      Admin SDK or the inbox stays empty. V1 was shipping with the
//      inbox empty because the priest's client was attempting these
//      writes and silently failing.
//
//   2. OS-level pushes: sendPushNotification reads users/{uid}.fcmTokens
//      which clients can't fan-read across other users either.
//
// Defences:
//   • Caller must be authenticated.
//   • Caller must be the priest who owns the session.
//   • Session must already be in "cancelled" state (so a malicious
//     priest can't spam the fanout by hammering this endpoint).
//
// Fanout shape: chunked into FANOUT_CHUNK_SIZE-sized rounds. Each
// round commits one Firestore batch (well under the 500-op limit)
// and runs its pushes in parallel. Rounds are sequential so that a
// 5,000-attendee session doesn't open 5,000 concurrent FCM sockets
// or blow the function's memory budget.

// 200 keeps batches well below the 500-op Firestore limit and caps
// concurrent FCM calls to a level that works in the default 256MiB
// memory tier without thrashing.
const FANOUT_CHUNK_SIZE = 200;

export const notifyBibleSessionCancellation = onCall(
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
    if (session.status !== "cancelled") {
      throw new HttpsError(
        "failed-precondition",
        "Session is not cancelled — refusing to send cancellation pushes",
      );
    }

    // Read all registrations and filter in code rather than via a
    // status whereIn — avoids depending on a Firestore composite
    // index, and the cancellation-fanout volume per session is
    // small enough that filtering server-side is cheap.
    const regsSnap = await db
      .collection(`bible_sessions/${sessionId}/registrations`)
      .get();
    const activeRegs = regsSnap.docs.filter(
      (d) => d.data().status !== "cancelled",
    );

    const priestName = String(session.priestName ?? "The speaker");
    const sessionTitle = String(session.title ?? "Bible Session");
    const body =
      `${priestName} has cancelled "${sessionTitle}". ` +
      "Check out other upcoming sessions!";

    let attempted = 0;

    // Each round:
    //   (a) commits one batch of /notifications docs (in-app inbox
    //       — the source of truth; survives even if pushes fail)
    //   (b) fans out OS-level pushes in parallel for the same chunk
    // Rounds are awaited sequentially so concurrency is bounded by
    // FANOUT_CHUNK_SIZE rather than total registrant count.
    for (let i = 0; i < activeRegs.length; i += FANOUT_CHUNK_SIZE) {
      const chunk = activeRegs.slice(i, i + FANOUT_CHUNK_SIZE);

      const batch = db.batch();
      for (const reg of chunk) {
        const notifRef = db.collection("notifications").doc();
        batch.set(notifRef, {
          userId: reg.id,
          type: "bible_session_cancelled",
          title: "Session cancelled",
          body,
          data: {sessionId},
          isRead: false,
          createdAt: admin.firestore.FieldValue.serverTimestamp(),
        });
      }
      try {
        await batch.commit();
      } catch (err) {
        // Best-effort once we're mid-fanout: the priest's cancel
        // call returns success either way, and the OS pushes below
        // still fire so users at least see the cancellation banner.
        console.error(
          "[notifyBibleSessionCancellation] notif batch failed for " +
            `${sessionId} (chunk start=${i}):`,
          err,
        );
      }

      await Promise.all(
        chunk.map(async (doc) => {
          attempted++;
          await sendPushNotification({
            userId: doc.id,
            title: "Session cancelled",
            body,
            data: {
              type: "bible_session_cancelled",
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
