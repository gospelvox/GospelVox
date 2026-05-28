// Priest's reply to a single review.
//
// Handles BOTH review sources:
//   • Chat / voice — review lives on sessions/{sessionId}. This is
//     the original path; clients that pass only {sessionId, text}
//     still hit it unchanged.
//   • Bible session — review lives on
//     bible_sessions/{bibleSessionId}/registrations/{regId}. Selected
//     by passing source="bible" with bibleSessionId + regId. The reply
//     shape, 24h edit window, mirror onto priests/{uid}.recentReviews,
//     and user push notification are identical to the session path —
//     priests get a single reply UX regardless of source.
//
// One reply per rated review. Editable for 24 hours after first
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

// Shape of a stored reply on either the session or the bible
// registration doc — same fields in both places so the read paths
// downstream don't need to branch.
type StoredReply = {
  text?: string;
  createdAt?: admin.firestore.Timestamp;
  updatedAt?: admin.firestore.Timestamp;
};

export const replyToReview = onCall(
  {region: REGION},
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Must be logged in");
    }

    const priestUid = request.auth.uid;
    const data = request.data ?? {};
    const rawText = data.text as string | undefined;
    // `source` is the dispatcher. Legacy clients omit it entirely and
    // we treat them as session-source for back-compat — that's the
    // path the chat/voice review page has always taken.
    const source =
      (data.source as string | undefined) === "bible" ? "bible" : "session";

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

    // ── Resolve target doc, owner check, rating check, dedupe key.

    let targetRef: FirebaseFirestore.DocumentReference;
    let targetSnap: FirebaseFirestore.DocumentSnapshot;
    let recipientUserId: string;
    let priestName: string;
    let priestPhotoUrl: string;
    // Key the mirror onto priests/{uid}.recentReviews uses to find
    // this review's entry: the flat sessionId for chat/voice, the
    // sentinel "bible_<sid>_<regId>" for bible (matches what the
    // onBibleSessionRated CF writes).
    let mirrorKey: string;
    // Used in push payload route + notification metadata.
    let pushSessionId: string;
    let route: string;

    if (source === "bible") {
      const bibleSessionId = data.bibleSessionId as string | undefined;
      const regId = data.regId as string | undefined;
      if (!bibleSessionId || typeof bibleSessionId !== "string") {
        throw new HttpsError("invalid-argument", "Missing bibleSessionId");
      }
      if (!regId || typeof regId !== "string") {
        throw new HttpsError("invalid-argument", "Missing regId");
      }

      // Owner check: the parent bible session has to belong to this
      // priest. We could read the registration first and then load
      // the parent, but a single parent-doc read up front rejects
      // unauthorised callers faster.
      const parentRef = db.doc(`bible_sessions/${bibleSessionId}`);
      const parentSnap = await parentRef.get();
      if (!parentSnap.exists) {
        throw new HttpsError("not-found", "Bible session not found");
      }
      const parentData = parentSnap.data() ?? {};
      if (parentData.priestId !== priestUid) {
        throw new HttpsError(
          "permission-denied",
          "You can only reply to reviews on your own bible sessions"
        );
      }

      targetRef = db.doc(
        `bible_sessions/${bibleSessionId}/registrations/${regId}`
      );
      targetSnap = await targetRef.get();
      if (!targetSnap.exists) {
        throw new HttpsError("not-found", "Registration not found");
      }
      const regData = targetSnap.data() ?? {};
      const rating = regData.rating as number | undefined;
      if (rating === undefined || rating === null) {
        throw new HttpsError(
          "failed-precondition",
          "You can only reply once the user has rated this session"
        );
      }

      // regId IS the user uid per the bible_sessions/registrations
      // rule. We still defensively coalesce in case future schemas
      // ever divorce them.
      recipientUserId = regId;
      priestName =
        (parentData.priestName as string | undefined) ?? "Your speaker";
      priestPhotoUrl =
        (parentData.priestPhotoUrl as string | undefined) ?? "";
      mirrorKey = `bible_${bibleSessionId}_${regId}`;
      pushSessionId = bibleSessionId;
      route = `/user/priest/${priestUid}`;
    } else {
      const sessionId = data.sessionId as string | undefined;
      if (!sessionId || typeof sessionId !== "string") {
        throw new HttpsError("invalid-argument", "Missing sessionId");
      }

      targetRef = db.doc(`sessions/${sessionId}`);
      targetSnap = await targetRef.get();
      if (!targetSnap.exists) {
        throw new HttpsError("not-found", "Session not found");
      }
      const session = targetSnap.data() ?? {};
      if (session.priestId !== priestUid) {
        throw new HttpsError(
          "permission-denied",
          "You can only reply to your own sessions"
        );
      }
      const rating = session.userRating as number | undefined;
      if (rating === undefined || rating === null) {
        throw new HttpsError(
          "failed-precondition",
          "You can only reply once the user has rated this session"
        );
      }

      recipientUserId = session.userId as string;
      priestName =
        (session.priestName as string | undefined) ?? "Your speaker";
      priestPhotoUrl =
        (session.priestPhotoUrl as string | undefined) ?? "";
      mirrorKey = sessionId;
      pushSessionId = sessionId;
      route = `/user/priest/${priestUid}`;
    }

    // ── Shared write path (24h edit window + write + mirror + push).

    const existingReply = targetSnap.data()?.priestReply as
      | StoredReply
      | undefined;
    const isEdit = existingReply !== undefined && existingReply !== null;

    if (isEdit) {
      const createdAt = existingReply?.createdAt;
      const createdAtDate = createdAt?.toDate();
      if (!createdAtDate) {
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

    // createdAt stays stable across edits so the 24h window measures
    // from FIRST publish, not last edit.
    const reply: Record<string, unknown> = {
      text,
      updatedAt: now,
      authorId: priestUid,
    };
    if (!isEdit) {
      reply.createdAt = now;
    }

    await targetRef.update({priestReply: reply});

    // Mirror the reply onto the denormalised review entry on the
    // priest doc so the user-side profile page sees the reply (the
    // public copy is the only one rules let other users read). Best-
    // effort: if the priest doc has no matching entry yet (older
    // review pre-deploy, or recentReviews trimmed past the cap), we
    // skip — the source-of-truth doc still has the reply.
    try {
      const priestRef = db.doc(`priests/${priestUid}`);
      await db.runTransaction(async (tx) => {
        const snap = await tx.get(priestRef);
        if (!snap.exists) return;
        const pdata = snap.data() ?? {};
        const reviews =
          (pdata.recentReviews as Array<Record<string, unknown>>) ?? [];
        if (reviews.length === 0) return;
        let touched = false;
        const updated = reviews.map((r) => {
          if (r.sessionId === mirrorKey) {
            touched = true;
            const existingCreatedAt =
              (r.priestReplyCreatedAt as string | undefined) ??
              new Date().toISOString();
            return {
              ...r,
              priestReply: text,
              // ISO strings — Firestore forbids server sentinels
              // inside an array element. priestReplyCreatedAt stays
              // stable across edits so a client reading the mirror
              // (e.g. the bible review case where the source doc is
              // not directly read) can still compute the 24h edit
              // window correctly. priestReplyAt updates on every
              // write so a "edited" badge has something to compare.
              priestReplyAt: new Date().toISOString(),
              priestReplyCreatedAt: existingCreatedAt,
            };
          }
          return r;
        });
        if (touched) {
          tx.update(priestRef, {recentReviews: updated});
        }
      });
    } catch (err) {
      console.error(
        `[replyToReview] Mirror to priest doc failed for ${mirrorKey}:`,
        err
      );
    }

    // Inbox + push only on the FIRST publish. Edits shouldn't re-ping
    // the user.
    if (!isEdit && recipientUserId) {
      const notifTitle = `${priestName} replied to your review`;
      const preview =
        text.length > 100 ? `${text.substring(0, 97)}…` : text;

      try {
        await db.collection("notifications").add({
          userId: recipientUserId,
          type: "priest_reply",
          title: notifTitle,
          body: preview,
          sessionId: pushSessionId,
          priestId: priestUid,
          priestName,
          priestPhotoUrl,
          isRead: false,
          createdAt: now,
        });
      } catch (err) {
        console.error(
          `[replyToReview] Inbox write failed for ${recipientUserId}:`,
          err
        );
      }

      try {
        await sendPushNotification({
          userId: recipientUserId,
          title: notifTitle,
          body: preview,
          data: {
            type: "priest_reply",
            route,
            sessionId: pushSessionId,
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
