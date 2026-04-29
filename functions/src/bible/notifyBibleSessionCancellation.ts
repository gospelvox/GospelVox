import {onCall, HttpsError} from "firebase-functions/v2/https";
import * as admin from "firebase-admin";
import {REGION} from "../config/constants";
import {sendPushNotification} from "../notifications/sendPush";

const db = admin.firestore();

// Server-side fanout for "the priest cancelled this Bible session"
// pushes. The priest's client is responsible for two things during
// a cancel:
//   (a) flipping bible_sessions/{id}.status to "cancelled" and
//   (b) writing the per-user notification docs to /notifications.
//
// Both are direct Firestore writes from the priest's client because
// V1 trades server-side rigour for shipping speed (W6 will move the
// whole flow into a single CF). The OS-level push fanout, however,
// genuinely needs a CF: sendPushNotification reads users/{uid}.fcmTokens,
// which clients can't fan-read across other users.
//
// Defences in this CF:
//   1. Caller must be authenticated.
//   2. Caller must be the priest who owns the session — a stranger
//      cannot trigger pushes for someone else's session.
//   3. Session must already be in the "cancelled" state. Without
//      this gate, a priest could spam the cancel-pushes any time
//      they want by repeatedly calling this CF.
//
// Notification doc writes are NOT done here (the client did them).
// We only emit the OS pushes. Errors from individual sends are
// swallowed inside sendPushNotification, so a single bad token
// can't sink the whole fanout.
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
    const title = String(session.title ?? "Bible Session");
    const body =
      `${priestName} has cancelled "${title}". ` +
      "Check out other upcoming sessions!";

    // Fan out in parallel — sendPushNotification is internally
    // best-effort (logs and swallows errors per user), so a slow
    // or stale token on one user doesn't block the rest.
    let attempted = 0;
    await Promise.all(
      activeRegs.map(async (doc) => {
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

    return {attempted};
  },
);
