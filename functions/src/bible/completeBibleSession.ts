import {onCall, HttpsError} from "firebase-functions/v2/https";
import * as admin from "firebase-admin";
import {REGION} from "../config/constants";
import {sendPushNotification} from "../notifications/sendPush";

const db = admin.firestore();

// Chunked-batch size for the user fanout below. Mirrors
// notifyBibleSessionCancellation — well below Firestore's 500-op
// batch limit and caps concurrent FCM sends to keep memory bounded
// on large sessions.
const FANOUT_CHUNK_SIZE = 200;

// Callable invoked by the priest's client when they tap "Mark
// Completed". Owns three things the client can't:
//   1. The status flip from "upcoming" → "completed" (defense in
//      depth on top of the repo's UI gate).
//   2. A paid-attendee head count and revenue tally — these need
//      a query over the registrations subcollection that the
//      priest's client could do, but doing it server-side here
//      keeps the success snackbar's numbers honest even if the
//      client lost network mid-commit.
//   3. A priest-facing in-app inbox notification. Firestore rules
//      have `notifications.create: if false`, so the Admin SDK
//      writing here is the only way to populate the priest's
//      inbox with a session-completed summary.
//
// Returns {paidCount, totalRevenue} so the caller can also surface
// those values without a follow-up read.
export const completeBibleSession = onCall(
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

    const sessionRef = db.doc(`bible_sessions/${sessionId}`);
    const sessionSnap = await sessionRef.get();
    if (!sessionSnap.exists) {
      throw new HttpsError("not-found", "Session not found");
    }

    const session = sessionSnap.data() ?? {};
    if (session.priestId !== callerUid) {
      throw new HttpsError(
        "permission-denied",
        "You don't own this session",
      );
    }
    // Accept BOTH 'upcoming' AND 'live'. The normal new-flow path
    // is live → completed (priest started the meeting, now wraps
    // up manually before the auto-complete cron catches it). The
    // 'upcoming' → 'completed' path is the escape hatch for the
    // rare case where a priest ran the session outside the app
    // entirely and wants to retire the listing without going
    // through Start Meeting. Cancelled / already-completed remain
    // rejected — those are terminal.
    if (session.status !== "upcoming" && session.status !== "live") {
      throw new HttpsError(
        "failed-precondition",
        `Cannot complete a ${session.status} session`,
      );
    }

    await sessionRef.update({
      status: "completed",
      completedAt: admin.firestore.FieldValue.serverTimestamp(),
    });

    // Bump the priest's totalSessions counter AND release the
    // "in bible session" lock — both writes in a single update
    // so the priest goes from "In Bible Session" back to "Online"
    // atomically. The lock fields use FieldValue.delete() (rather
    // than null) so the priest doc stays minimal — Firestore
    // simply removes the keys, and the Dart model reads back the
    // missing fields as their defaults (empty string / null).
    //
    // If this update fails (network blip, doc missing), the
    // bibleSessionReminders cron is the safety net: it clears
    // the same fields when it auto-completes the session, and
    // the client-side bibleSessionLockedUntil deadline guarantees
    // the lock self-releases once the time passes regardless of
    // whether any CF runs.
    try {
      await db.doc(`priests/${callerUid}`).update({
        totalSessions: admin.firestore.FieldValue.increment(1),
        liveBibleSessionId: admin.firestore.FieldValue.delete(),
        bibleSessionLockedUntil: admin.firestore.FieldValue.delete(),
      });
    } catch (err) {
      console.error(
        "[completeBibleSession] priest doc update failed for " +
          `priest=${callerUid} session=${sessionId}:`,
        err,
      );
    }

    // One read of the full registrations subcollection — used both
    // for the paid-attendee tally (priest summary) and the active-
    // registrant fanout (user "session ended" notifications).
    // Two filters over the same snapshot are cheaper than two
    // separate where() queries and avoid depending on a composite
    // index. V1 session sizes make the full read cost negligible.
    const allRegsSnap = await db
      .collection(`bible_sessions/${sessionId}/registrations`)
      .get();
    const paidCount = allRegsSnap.docs.filter(
      (d) => d.data().status === "paid",
    ).length;
    const activeRegs = allRegsSnap.docs.filter(
      (d) => d.data().status !== "cancelled",
    );
    const price = Number(session.price ?? 0);
    const totalRevenue = paidCount * price;
    const title = String(session.title ?? "Bible Session");

    // Priest-facing summary. Spiritual + warm tone per product
    // guidance — the priest just finished serving, the inbox entry
    // is the closing acknowledgement of that.
    try {
      const notifRef = db.collection("notifications").doc();
      await notifRef.set({
        userId: callerUid,
        type: "bible_session_completed",
        title: "🙌 Session Completed",
        body:
          `"${title}" — ₹${totalRevenue} earned from ${paidCount} ` +
          `attendee${paidCount === 1 ? "" : "s"}. ` +
          "God bless your ministry!",
        sessionId,
        data: {sessionId},
        isRead: false,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    } catch (err) {
      // Inbox is best-effort — the status flip is the load-bearing
      // result. The priest will see the snackbar regardless.
      console.error(
        "[completeBibleSession] priest notif write failed for " +
          `${sessionId}:`,
        err,
      );
    }

    // ── Notify active registrants ───────────────────────────────────
    // Paid users especially need this — the moment status flips to
    // 'completed' their meeting link stops working, and without an
    // in-app signal it reads as a broken link / app. Free-registered
    // (unpaid) users get the same notification so they have closure
    // on a session they expressed interest in (and the rating dialog
    // on the detail page auto-opens for paid users when they tap in).
    //
    // Cancelled registrations are skipped — those users already opted
    // out. Chunked batches mirror notifyBibleSessionCancellation: the
    // /notifications doc is the source of truth (rules deny client
    // creates, so Admin SDK is the only path) and the push is a best-
    // effort overlay. Errors per chunk are logged and swallowed so a
    // single bad batch doesn't abort the rest of the fanout.
    const userBody =
      `"${title}" has wrapped up. ` +
      "Thank you for being part of this blessed time.";

    for (let i = 0; i < activeRegs.length; i += FANOUT_CHUNK_SIZE) {
      const chunk = activeRegs.slice(i, i + FANOUT_CHUNK_SIZE);

      const batch = db.batch();
      for (const reg of chunk) {
        const notifRef = db.collection("notifications").doc();
        batch.set(notifRef, {
          userId: reg.id,
          type: "bible_session_completed_user",
          title: "🙌 Session Wrapped Up",
          body: userBody,
          sessionId,
          data: {sessionId},
          isRead: false,
          createdAt: admin.firestore.FieldValue.serverTimestamp(),
        });
      }
      try {
        await batch.commit();
      } catch (err) {
        console.error(
          "[completeBibleSession] user notif batch failed for " +
            `${sessionId} (chunk start=${i}):`,
          err,
        );
      }

      await Promise.all(
        chunk.map((reg) =>
          sendPushNotification({
            userId: reg.id,
            title: "🙌 Session Wrapped Up",
            body: userBody,
            data: {
              type: "bible_session_completed_user",
              sessionId,
              route: `/bible/detail/${sessionId}`,
            },
          }),
        ),
      );
    }

    return {paidCount, totalRevenue};
  },
);
