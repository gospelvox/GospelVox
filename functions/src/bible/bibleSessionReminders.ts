import {onSchedule} from "firebase-functions/v2/scheduler";
import * as admin from "firebase-admin";
import {REGION} from "../config/constants";
import {sendPushNotification} from "../notifications/sendPush";

const db = admin.firestore();
const FANOUT_CHUNK_SIZE = 200;

// Time windows. Each window must be wider than the cron cadence
// (2 min) so a single tick never misses a reminder boundary. We
// also gate on a per-session `remindersSent` map so the multiple
// ticks that land inside the same 5-min window only fire the
// reminder once per kind per session.
//
// The cron was tightened from 5-min → 2-min cadence so the auto-
// complete pass at the bottom of this file flips stale `live` docs
// to `completed` within ~2 min of the deadline instead of ~5. The
// reminder windows themselves stayed at 5 min wide — wider than
// the cron cadence so we never miss a boundary, narrower than the
// reminder kind so two consecutive kinds (e.g. 24h vs 1h) don't
// collide.
const FIVE_MIN = 5;
const ONE_HOUR_MIN = 60;
const ONE_DAY_MIN = 24 * 60;

interface ReminderPayload {
  type: string;
  title: string;
  body: string;
}

function chunkArray<T>(arr: T[], size: number): T[][] {
  const out: T[][] = [];
  for (let i = 0; i < arr.length; i += size) {
    out.push(arr.slice(i, i + size));
  }
  return out;
}

// In-app inbox docs + OS push for a list of registrant doc snapshots.
// In-app first (the inbox is the source of truth), push second (best-
// effort). Errors in either path are logged and swallowed so one bad
// session never blocks the rest of the cron tick.
async function notifyRegistrants(
  sessionId: string,
  regs: FirebaseFirestore.QueryDocumentSnapshot[],
  payload: ReminderPayload,
): Promise<void> {
  for (const chunk of chunkArray(regs, FANOUT_CHUNK_SIZE)) {
    const batch = db.batch();
    for (const reg of chunk) {
      const notifRef = db.collection("notifications").doc();
      batch.set(notifRef, {
        userId: reg.id,
        type: payload.type,
        title: payload.title,
        body: payload.body,
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
        "[bibleSessionReminders] notif batch failed for " +
          `${sessionId}:`,
        err,
      );
    }
    await Promise.all(
      chunk.map((reg) =>
        sendPushNotification({
          userId: reg.id,
          title: payload.title,
          body: payload.body,
          data: {
            type: payload.type,
            sessionId,
            route: `/bible/detail/${sessionId}`,
          },
        }),
      ),
    );
  }
}

// Reads the registrations subcollection once per cron-tick branch.
// Cheap enough at V1 scale that we don't try to share a single read
// across the four user-facing branches — each branch only fires
// within a 5-minute window per session, so realistically a session
// reads its regs at most twice during the day before going live.
async function activeRegistrants(
  sessionId: string,
): Promise<FirebaseFirestore.QueryDocumentSnapshot[]> {
  const snap = await db
    .collection(`bible_sessions/${sessionId}/registrations`)
    .get();
  return snap.docs.filter((d) => d.data().status !== "cancelled");
}

// Scheduled every 2 minutes (see `schedule:` below). Iterates over
// upcoming sessions, classifies each by `diffMin` (minutes until
// scheduledAt), and fires whichever reminders fall inside the
// current 5-minute window AND haven't been fired before (per the
// `remindersSent` map on the session doc). The 5-min window is
// wider than the 2-min cadence so a single tick never misses a
// boundary, and the dedup guarantees the multiple ticks landing
// inside the same window fire each reminder at most once.
//
// Why a single-field query: filtering only on `status == 'upcoming'`
// keeps us in single-field equality land — no composite index needed.
// The scheduledAt-cutoff filter happens client-side after read. V1
// session volume is small (dozens), so the cost is negligible and
// the trade-off is worth the deploy-simplicity.
export const bibleSessionReminders = onSchedule(
  {
    schedule: "every 2 minutes",
    timeZone: "Asia/Kolkata",
    region: REGION,
    retryCount: 2,
  },
  async () => {
    const now = new Date();
    const upcoming = await db
      .collection("bible_sessions")
      .where("status", "==", "upcoming")
      .get();

    if (upcoming.empty) {
      console.log("[bibleSessionReminders] no upcoming sessions");
      return;
    }

    for (const sessionDoc of upcoming.docs) {
      const session = sessionDoc.data();
      const sessionId = sessionDoc.id;
      const scheduledTs =
        session.scheduledAt as admin.firestore.Timestamp | undefined;
      const scheduledAt = scheduledTs?.toDate();
      if (!scheduledAt) continue;

      const diffMin = Math.round(
        (scheduledAt.getTime() - now.getTime()) / 60000,
      );

      // Skip sessions outside the reminder horizon — more than ~25h
      // away (no 24h reminder yet) OR more than 1h past start (start
      // reminder already fired or scheduledAt was in the past on
      // creation, which the UI prevents).
      if (diffMin > ONE_DAY_MIN + FIVE_MIN || diffMin < -ONE_HOUR_MIN) {
        continue;
      }

      const title = String(session.title ?? "Bible Session");
      const priestId = session.priestId as string | undefined;
      const priestName = String(session.priestName ?? "Speaker");
      const meetingLink =
        typeof session.meetingLink === "string"
          ? (session.meetingLink as string)
          : "";
      const sent =
        (session.remindersSent as Record<string, boolean> | undefined) ?? {};
      const sessionRef = sessionDoc.ref;

      // ── 24 h before → registered users ───────────────────────────
      if (
        diffMin <= ONE_DAY_MIN &&
        diffMin > ONE_DAY_MIN - FIVE_MIN &&
        !sent["24h_users"]
      ) {
        const regs = await activeRegistrants(sessionId);
        await notifyRegistrants(sessionId, regs, {
          type: "bible_session_reminder_24h",
          title: "📖 Session Tomorrow",
          body:
            `"${title}" with ${priestName} is tomorrow. ` +
            "Don't miss this blessing!",
        });
        await sessionRef.update({"remindersSent.24h_users": true});
      }

      // ── 24 h before → priest (only if link still missing) ────────
      if (
        priestId &&
        diffMin <= ONE_DAY_MIN &&
        diffMin > ONE_DAY_MIN - FIVE_MIN &&
        !sent["24h_priest"] &&
        meetingLink === ""
      ) {
        await sendPushNotification({
          userId: priestId,
          title: "⚠️ Add Meeting Link",
          body:
            `"${title}" is tomorrow — ` +
            "please add the meeting link.",
          data: {
            type: "bible_session_link_reminder",
            sessionId,
            route: `/priest/bible/${sessionId}`,
          },
        });
        await sessionRef.update({"remindersSent.24h_priest": true});
      }

      // ── 1 h before → registered users ────────────────────────────
      if (
        diffMin <= ONE_HOUR_MIN &&
        diffMin > ONE_HOUR_MIN - FIVE_MIN &&
        !sent["1h_users"]
      ) {
        const regs = await activeRegistrants(sessionId);
        await notifyRegistrants(sessionId, regs, {
          type: "bible_session_reminder_1h",
          title: "🕐 Starting in 1 Hour",
          body: `"${title}" starts in 1 hour. Prepare your heart 🙏`,
        });
        await sessionRef.update({"remindersSent.1h_users": true});
      }

      // ── 1 h before → priest URGENT (only if link still missing) ──
      if (
        priestId &&
        diffMin <= ONE_HOUR_MIN &&
        diffMin > ONE_HOUR_MIN - FIVE_MIN &&
        !sent["1h_priest"] &&
        meetingLink === ""
      ) {
        await sendPushNotification({
          userId: priestId,
          title: "🚨 URGENT: Add Meeting Link!",
          body:
            `"${title}" starts in 1 hour — ` +
            "add the meeting link NOW.",
          data: {
            type: "bible_session_link_urgent",
            sessionId,
            route: `/priest/bible/${sessionId}`,
          },
        });
        await sessionRef.update({"remindersSent.1h_priest": true});
      }

      // ── 15 min before → registered-but-unpaid users (conversion) ─
      if (
        diffMin <= 15 &&
        diffMin > 15 - FIVE_MIN &&
        !sent["15m_unpaid"]
      ) {
        const unpaidSnap = await db
          .collection(`bible_sessions/${sessionId}/registrations`)
          .where("status", "==", "registered")
          .get();
        for (const reg of unpaidSnap.docs) {
          await sendPushNotification({
            userId: reg.id,
            title: "⏰ Starting in 15 min!",
            body:
              `"${title}" starts soon. ` +
              "You'll pay to join the moment the speaker goes live.",
            data: {
              type: "bible_session_pay_reminder",
              sessionId,
              route: `/bible/detail/${sessionId}`,
            },
          });
        }
        await sessionRef.update({"remindersSent.15m_unpaid": true});
      }

      // ── 15 min before → priest go-live nudge ─────────────────────
      if (
        priestId &&
        diffMin <= 15 &&
        diffMin > 15 - FIVE_MIN &&
        !sent["15m_priest"]
      ) {
        await sendPushNotification({
          userId: priestId,
          title: "🎙️ Go Live in 15 Minutes",
          body:
            `"${title}" starts soon. ` +
            "Get ready to lead your session.",
          data: {
            type: "bible_session_golive",
            sessionId,
            route: `/priest/bible/${sessionId}`,
          },
        });
        await sessionRef.update({"remindersSent.15m_priest": true});
      }

      // ── At start (within 5 min) → paid users ─────────────────────
      // Suppressed when the priest hasn't added a meeting link yet —
      // a "tap to join" push that lands on STATE B (no link) reads
      // as a broken app, not a missed-link priest. We DON'T mark
      // start_users:true in that case so the reminder retries on
      // the next cron tick once the link lands (still inside the
      // 5-min window if the priest is hurrying).
      if (
        diffMin <= 5 &&
        diffMin > 0 &&
        !sent["start_users"] &&
        meetingLink !== ""
      ) {
        const paidSnap = await db
          .collection(`bible_sessions/${sessionId}/registrations`)
          .where("status", "==", "paid")
          .get();
        await notifyRegistrants(sessionId, paidSnap.docs, {
          type: "bible_session_starting",
          title: "🕊️ Session Starting Now",
          body: `"${title}" is starting — tap to join and be blessed!`,
        });
        await sessionRef.update({"remindersSent.start_users": true});
      }

      // ── At start (within 5 min) → priest ─────────────────────────
      if (
        priestId &&
        diffMin <= 5 &&
        diffMin > 0 &&
        !sent["start_priest"]
      ) {
        await sendPushNotification({
          userId: priestId,
          title: "🎙️ Session Starting Now!",
          body: `"${title}" is starting. Lead your flock with grace.`,
          data: {
            type: "bible_session_starting_priest",
            sessionId,
            route: `/priest/bible/${sessionId}`,
          },
        });
        await sessionRef.update({"remindersSent.start_priest": true});
      }

      // ── General "still no link" pulse — every 30 min within 2h ──
      //
      // Unlike the 24h/1h/15m_priest reminders above (which each fire
      // exactly once because they store a boolean in remindersSent),
      // this one REPEATS so a priest who creates a session 30 minutes
      // before start gets pinged on every cron tick until they add a
      // link or the session passes. We store an ISO timestamp in the
      // separate `lastGeneralLinkReminderAt` field (NOT in remindersSent,
      // because the Dart model coerces that map to bool and a string
      // would be silently dropped) and re-fire only if 30+ min have
      // passed since the last send.
      //
      // Bounded to the 2h pre-start window so we don't pester for a
      // session that's still 5 days out — the fixed-window 24h/1h
      // reminders cover those.
      if (
        priestId &&
        meetingLink === "" &&
        diffMin > 0 &&
        diffMin <= 120
      ) {
        const lastTs =
          session.lastGeneralLinkReminderAt as
            admin.firestore.Timestamp |
            undefined;
        const lastReminder = lastTs?.toDate();
        const thirtyMinAgoMs = now.getTime() - 30 * 60 * 1000;
        if (!lastReminder || lastReminder.getTime() < thirtyMinAgoMs) {
          await sendPushNotification({
            userId: priestId,
            title: "⚠️ Add Meeting Link",
            body:
              `"${title}" starts in ${diffMin} min — ` +
              "add your meeting link now!",
            data: {
              type: "bible_session_link_reminder",
              sessionId,
              route: `/priest/bible/${sessionId}`,
            },
          });
          await sessionRef.update({
            lastGeneralLinkReminderAt:
              admin.firestore.FieldValue.serverTimestamp(),
          });
        }
      }
    }

    // ─────────────────────────────────────────────────────────────
    // AUTO-COMPLETE PASS
    // ─────────────────────────────────────────────────────────────
    //
    // In the new flow, sessions auto-complete exactly `durationMinutes`
    // minutes after the priest hit "Start Meeting" — there is no grace
    // window. `isJoinable` / `isPastDeadline` on the client use the
    // same deadline. Once past it the priest is assumed to have wrapped
    // up and forgotten to mark it completed, so we do it for them.
    //
    // Side effects per auto-completed session:
    //   • status → 'completed', completedAt = server time,
    //     autoCompleted = true (audit flag — distinguishes priest-
    //     completed from cron-completed in case we need to query
    //     for one or the other later).
    //   • One priest inbox doc summarising paid count + revenue.
    //
    // Single-field equality query keeps us index-free. Sessions that
    // were started but never reach the deadline (priest already
    // marked completed) are simply not in the live set on this tick.
    const liveSnap = await db
      .collection("bible_sessions")
      .where("status", "==", "live")
      .get();

    for (const sessionDoc of liveSnap.docs) {
      const session = sessionDoc.data();
      const sessionId = sessionDoc.id;

      const startedTs =
        session.startedAt as admin.firestore.Timestamp | undefined;
      const startedAt = startedTs?.toDate();
      if (!startedAt) {
        // A live session with no startedAt would mean the start CF
        // failed to stamp it — log loudly so this becomes a known
        // anomaly the next time someone audits.
        console.warn(
          "[bibleSessionReminders] live session without startedAt: " +
            `${sessionId}`,
        );
        continue;
      }

      // Default to 60 min if the doc is malformed — matches the
      // model fallback. Math.round to coerce any stray float.
      const durationMinRaw = session.durationMinutes as number | undefined;
      const durationMin =
        typeof durationMinRaw === "number" && Number.isFinite(durationMinRaw)
          ? Math.max(1, Math.round(durationMinRaw))
          : 60;

      const deadlineMs =
        startedAt.getTime() + durationMin * 60 * 1000;
      if (now.getTime() <= deadlineMs) continue;

      try {
        await sessionDoc.ref.update({
          status: "completed",
          completedAt: admin.firestore.FieldValue.serverTimestamp(),
          autoCompleted: true,
        });
      } catch (err) {
        console.error(
          "[bibleSessionReminders] auto-complete flip failed for " +
            `${sessionId}:`,
          err,
        );
        continue;
      }

      // Mirror completeBibleSession: bump the priest's totalSessions
      // counter AND release the in-bible-session lock (liveBibleSessionId
      // + bibleSessionLockedUntil). This cron is the load-bearing
      // safety net for the lock — if a priest taps "Mark Completed"
      // and the CF fails, OR they background the app and never tap
      // complete at all, this branch is what eventually flips them
      // back to "Online" for incoming calls/chats.
      //
      // Without clearing the lock here, a priest whose Bible session
      // ended via the cron (not manual complete) would stay flagged
      // as in-bible-session indefinitely, blocking all incoming
      // session requests for hours/days until manual cleanup.
      const priestIdForCount = session.priestId as string | undefined;
      if (priestIdForCount) {
        try {
          await db.doc(`priests/${priestIdForCount}`).update({
            totalSessions: admin.firestore.FieldValue.increment(1),
            liveBibleSessionId: admin.firestore.FieldValue.delete(),
            bibleSessionLockedUntil:
              admin.firestore.FieldValue.delete(),
          });
        } catch (err) {
          console.error(
            "[bibleSessionReminders] priest doc update failed " +
              `for priest=${priestIdForCount} session=${sessionId}:`,
            err,
          );
        }
      }

      // Priest summary — count + revenue. One read of the full
      // registrations subcollection feeds both the paid-count tally
      // (revenue line in the priest inbox doc) and the active-
      // registrant fanout below (user-facing "session ended" push).
      // Two filters over the same snapshot avoid a second round-trip
      // and a composite-index dependency.
      let paidCount = 0;
      let activeRegs: FirebaseFirestore.QueryDocumentSnapshot[] = [];
      try {
        const allRegsSnap = await db
          .collection(`bible_sessions/${sessionId}/registrations`)
          .get();
        paidCount = allRegsSnap.docs.filter(
          (d) => d.data().status === "paid",
        ).length;
        activeRegs = allRegsSnap.docs.filter(
          (d) => d.data().status !== "cancelled",
        );
      } catch (err) {
        console.error(
          "[bibleSessionReminders] registrations read failed for " +
            `${sessionId}:`,
          err,
        );
      }

      const price = Number(session.price ?? 0);
      const totalRevenue = paidCount * price;
      const title = String(session.title ?? "Bible Session");
      const priestId = session.priestId as string | undefined;
      if (!priestId) continue;

      try {
        const notifRef = db.collection("notifications").doc();
        await notifRef.set({
          userId: priestId,
          type: "bible_session_auto_completed",
          title: "🙌 Session Auto-Completed",
          body:
            `"${title}" wrapped up — ₹${totalRevenue} from ${paidCount} ` +
            `attendee${paidCount === 1 ? "" : "s"}.`,
          sessionId,
          data: {sessionId},
          isRead: false,
          createdAt: admin.firestore.FieldValue.serverTimestamp(),
        });
      } catch (err) {
        console.error(
          "[bibleSessionReminders] auto-complete notif failed for " +
            `${sessionId}:`,
          err,
        );
      }

      // ── Notify active registrants ───────────────────────────────
      // Mirrors the manual completeBibleSession path — paid users
      // lose access to the meeting link the moment status flips to
      // 'completed', and without a signal that reads as a broken
      // link. Free-registered (unpaid) users get the same note so
      // they have closure on a session they expressed interest in.
      // Cancelled registrations are skipped (they already opted out).
      //
      // Reuses the chunked-batch helper above (notifyRegistrants)
      // which handles in-app inbox + push fanout with per-chunk
      // error swallowing — a single bad chunk can't poison the rest
      // of the cron tick.
      if (activeRegs.length > 0) {
        await notifyRegistrants(sessionId, activeRegs, {
          type: "bible_session_completed_user",
          title: "🙌 Session Wrapped Up",
          body:
            `"${title}" has wrapped up. ` +
            "Thank you for being part of this blessed time.",
        });
      }
    }

    // ─────────────────────────────────────────────────────────────
    // AUTO-EXPIRE PASS (never-started sessions)
    // ─────────────────────────────────────────────────────────────
    //
    // A session the priest never tapped "Start Meeting" on stays
    // 'upcoming' forever — the auto-complete pass above only touches
    // 'live' docs, so nothing else ever closes it. Once we're past
    // (scheduledAt + durationMinutes + 15min grace) with no start, the
    // slot is missed: the priest forgot. We close it as 'cancelled'
    // (autoExpired:true for audit) so it stops rotting in the DB and
    // disappears cleanly, then notify registrants "didn't take place —
    // you were not charged" so they get closure instead of a silent
    // vanish (the old behaviour only hid it client-side).
    //
    // The 15-min grace mirrors BibleSessionModel.isExpiredUpcoming so
    // the server flips the doc at the exact moment the client already
    // hides it — no window where the two disagree. Nobody can have paid
    // (payment only happens once a session is live), so there is NO
    // refund concern. Reuses the `upcoming` snapshot read at the top of
    // the tick — no extra query.
    for (const sessionDoc of upcoming.docs) {
      const session = sessionDoc.data();
      const sessionId = sessionDoc.id;

      const scheduledTs =
        session.scheduledAt as admin.firestore.Timestamp | undefined;
      const scheduledAt = scheduledTs?.toDate();
      if (!scheduledAt) continue;

      const durationMinRaw = session.durationMinutes as number | undefined;
      const durationMin =
        typeof durationMinRaw === "number" && Number.isFinite(durationMinRaw)
          ? Math.max(1, Math.round(durationMinRaw))
          : 60;

      const expireMs =
        scheduledAt.getTime() + (durationMin + 15) * 60 * 1000;
      if (now.getTime() <= expireMs) continue;

      try {
        await sessionDoc.ref.update({
          status: "cancelled",
          cancelledAt: admin.firestore.FieldValue.serverTimestamp(),
          autoExpired: true,
        });
      } catch (err) {
        console.error(
          "[bibleSessionReminders] auto-expire flip failed for " +
            `${sessionId}:`,
          err,
        );
        continue;
      }

      const title = String(session.title ?? "Bible Session");

      // Registrant closure note (in-app inbox + push). Nobody paid, so
      // this is reassurance, not a refund.
      let activeRegs: FirebaseFirestore.QueryDocumentSnapshot[] = [];
      try {
        const regsSnap = await db
          .collection(`bible_sessions/${sessionId}/registrations`)
          .get();
        activeRegs = regsSnap.docs.filter(
          (d) => d.data().status !== "cancelled",
        );
      } catch (err) {
        console.error(
          "[bibleSessionReminders] auto-expire regs read failed for " +
            `${sessionId}:`,
          err,
        );
      }
      if (activeRegs.length > 0) {
        await notifyRegistrants(sessionId, activeRegs, {
          type: "bible_session_expired",
          title: "Session Didn't Take Place",
          body:
            `"${title}" didn't take place at its scheduled time. ` +
            "You were not charged.",
        });
      }

      // Priest nudge so they realise they forgot to start it.
      const priestId = session.priestId as string | undefined;
      if (priestId) {
        try {
          const notifRef = db.collection("notifications").doc();
          await notifRef.set({
            userId: priestId,
            type: "bible_session_expired_priest",
            title: "Session Expired",
            body:
              `"${title}" was never started, so it has been closed. ` +
              "Create a new session to reschedule.",
            sessionId,
            data: {sessionId},
            isRead: false,
            createdAt: admin.firestore.FieldValue.serverTimestamp(),
          });
        } catch (err) {
          console.error(
            "[bibleSessionReminders] auto-expire priest notif failed " +
              `for ${sessionId}:`,
            err,
          );
        }
      }
    }
  },
);
