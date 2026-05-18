import {onCall, HttpsError} from "firebase-functions/v2/https";
import * as admin from "firebase-admin";
import {REGION} from "../config/constants";

const db = admin.firestore();

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

    // Bump the priest's totalSessions counter. The priest dashboard
    // and admin speaker-detail page read this field directly off
    // `priests/{uid}`, so without an increment a priest who only
    // ran bible sessions would show "0 sessions" forever. Done
    // outside the transaction-style batch above because the status
    // flip is already authoritative — if this update fails we'd
    // rather have a slightly-stale counter than a half-completed
    // session.
    try {
      await db.doc(`priests/${callerUid}`).update({
        totalSessions: admin.firestore.FieldValue.increment(1),
      });
    } catch (err) {
      console.error(
        "[completeBibleSession] totalSessions increment failed for " +
          `priest=${callerUid} session=${sessionId}:`,
        err,
      );
    }

    // Count paid registrations — single-field equality query, no
    // composite index needed. `regsSnap.size` is the authoritative
    // attendee count because the onBibleRegistrationWrite trigger
    // is the only thing that mutates registrationCount, and a paid
    // doc is always also "active" (not cancelled).
    const regsSnap = await db
      .collection(`bible_sessions/${sessionId}/registrations`)
      .where("status", "==", "paid")
      .get();
    const paidCount = regsSnap.size;
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

    return {paidCount, totalRevenue};
  },
);
