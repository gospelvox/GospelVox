// Priest's reply to a single session review.
//
// One reply per rated session. Editable for 24 hours after first
// write, then locked — matches the Airbnb host-reply pattern. We
// enforce both windows here (server is the only writer the rules
// will accept) so a tampered client cannot bypass the cap.
//
// Notification: the user who left the review gets a single push
// when the priest's reply lands. Edits within the 24h window do NOT
// re-notify — a noisier loop than the product wants.

import {onCall, HttpsError} from "firebase-functions/v2/https";
import * as admin from "firebase-admin";
import {REGION} from "../config/constants";
import {sendPushNotification} from "../notifications/sendPush";

const db = admin.firestore();

const REPLY_MAX_CHARS = 300;
const EDIT_WINDOW_HOURS = 24;

export const replyToReview = onCall(
  {region: REGION},
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Must be logged in");
    }

    const priestUid = request.auth.uid;
    const data = request.data ?? {};
    const sessionId = data.sessionId as string | undefined;
    const rawText = data.text as string | undefined;

    if (!sessionId || typeof sessionId !== "string") {
      throw new HttpsError("invalid-argument", "Missing sessionId");
    }
    if (typeof rawText !== "string") {
      throw new HttpsError("invalid-argument", "Missing reply text");
    }

    const text = rawText.trim();
    if (text.length === 0) {
      throw new HttpsError(
        "invalid-argument",
        "Reply cannot be empty. Add a few words or skip."
      );
    }
    if (text.length > REPLY_MAX_CHARS) {
      throw new HttpsError(
        "invalid-argument",
        `Reply must be ${REPLY_MAX_CHARS} characters or fewer.`
      );
    }

    const sessionRef = db.doc(`sessions/${sessionId}`);
    const sessionSnap = await sessionRef.get();

    if (!sessionSnap.exists) {
      throw new HttpsError("not-found", "Session not found");
    }

    const session = sessionSnap.data()!;

    if (session.priestId !== priestUid) {
      throw new HttpsError(
        "permission-denied",
        "You can only reply to your own sessions"
      );
    }

    // No rating = nothing to reply to. The reviews page only shows
    // rated sessions; this is a defensive backstop for a client that
    // somehow calls in with an unrated sessionId.
    const rating = session.userRating as number | undefined;
    if (rating === undefined || rating === null) {
      throw new HttpsError(
        "failed-precondition",
        "You can only reply once the user has rated this session"
      );
    }

    const existingReply = session.priestReply as
      | {
          text?: string;
          createdAt?: admin.firestore.Timestamp;
          updatedAt?: admin.firestore.Timestamp;
        }
      | undefined;

    const isEdit = existingReply !== undefined && existingReply !== null;

    if (isEdit) {
      const createdAt = existingReply?.createdAt;
      const createdAtDate = createdAt?.toDate();
      if (!createdAtDate) {
        // Shouldn't happen — if there's an existing reply, createdAt
        // was set in the same write. Treat absence as already-locked.
        throw new HttpsError(
          "failed-precondition",
          "This reply can no longer be edited."
        );
      }
      const hoursSinceCreated =
        (Date.now() - createdAtDate.getTime()) / (1000 * 60 * 60);
      if (hoursSinceCreated > EDIT_WINDOW_HOURS) {
        throw new HttpsError(
          "failed-precondition",
          `Replies can only be edited within ${EDIT_WINDOW_HOURS} hours of posting.`
        );
      }
    }

    const now = admin.firestore.FieldValue.serverTimestamp();

    // We deliberately keep the createdAt stamp stable across edits so
    // the 24h window measures from FIRST publish, not last edit. An
    // edit only refreshes `updatedAt`.
    const reply: Record<string, unknown> = {
      text,
      updatedAt: now,
      authorId: priestUid,
    };
    if (!isEdit) {
      reply.createdAt = now;
    }

    await sessionRef.update({priestReply: reply});

    // Inbox + push only on the FIRST publish. Edits shouldn't re-ping
    // the user — that's the standard professional-app behaviour and
    // matches what the product confirmed.
    if (!isEdit) {
      const userId = session.userId as string;
      const priestName =
        (session.priestName as string | undefined) ?? "Your speaker";
      const priestPhotoUrl =
        (session.priestPhotoUrl as string | undefined) ?? "";
      const notifTitle = `${priestName} replied to your review`;
      // Preview keeps under ~100 chars so the FCM heads-up banner
      // renders cleanly across OEM-themed Android lock screens.
      const preview =
        text.length > 100 ? `${text.substring(0, 97)}…` : text;

      try {
        await db.collection("notifications").add({
          userId,
          type: "priest_reply",
          title: notifTitle,
          body: preview,
          sessionId,
          priestId: priestUid,
          priestName,
          priestPhotoUrl,
          isRead: false,
          createdAt: now,
        });
      } catch (err) {
        console.error(
          `[replyToReview] Inbox write failed for ${userId}:`,
          err
        );
      }

      try {
        await sendPushNotification({
          userId,
          title: notifTitle,
          body: preview,
          data: {
            type: "priest_reply",
            route: `/user/priest/${priestUid}`,
            sessionId,
            priestId: priestUid,
          },
        });
      } catch {
        // sendPushNotification already logs internally.
      }
    }

    return {success: true, isEdit};
  }
);
