import {onSchedule} from "firebase-functions/v2/scheduler";
import * as admin from "firebase-admin";
import {REGION} from "../config/constants";

const db = admin.firestore();

// How long after the last client heartbeat we treat a session as
// abandoned. 2 minutes is the product contract — short enough that
// crashed sessions don't tie up a priest forever, long enough to
// absorb slow networks and brief OEM doze. Don't shrink without
// also shrinking the client heartbeat cadence (currently 30s).
const HEARTBEAT_TIMEOUT_MS = 2 * 60 * 1000;

// Scheduled every 5 minutes. The runtime is happy to tolerate the
// occasional slow tick — losing one cycle just delays the cleanup
// of orphaned sessions by another 5 minutes, which is acceptable
// given the heartbeat already gives 2 minutes of grace.
export const sessionWatchdog = onSchedule(
  {
    schedule: "every 5 minutes",
    region: REGION,
    // Cron firings retry on transient infrastructure failure so a
    // single bad invocation doesn't leave abandoned sessions to
    // accumulate for the next 5 minutes.
    retryCount: 2,
  },
  async () => {
    const now = admin.firestore.Timestamp.now();
    const cutoffTime = admin.firestore.Timestamp.fromMillis(
      now.toMillis() - HEARTBEAT_TIMEOUT_MS
    );

    console.log(
      `[Watchdog] Running at ${now.toDate().toISOString()}, ` +
      `cutoff: ${cutoffTime.toDate().toISOString()}`
    );

    // STEP 1 — Find every active session whose last heartbeat is
    // older than the cutoff. Composite index required:
    //   sessions: status (asc), lastHeartbeat (asc)
    // Firebase will surface a console URL the first time this runs
    // in a fresh project; click it to provision the index.
    const staleSessions = await db
      .collection("sessions")
      .where("status", "==", "active")
      .where("lastHeartbeat", "<", cutoffTime)
      .get();

    if (staleSessions.empty) {
      console.log("[Watchdog] No stale sessions found. All clear.");
      return;
    }

    console.log(`[Watchdog] Found ${staleSessions.size} stale session(s)`);

    // STEP 2 — Process each stale session independently. We catch
    // per-session errors so a single bad doc (e.g. malformed data
    // from an old build) doesn't block the watchdog from cleaning
    // up the rest of the queue.
    const results: Array<{sessionId: string; result: string}> = [];

    for (const sessionDoc of staleSessions.docs) {
      const sessionId = sessionDoc.id;
      try {
        await processStaleSession(sessionId, sessionDoc.data());
        results.push({sessionId, result: "ended"});
      } catch (error) {
        console.error(
          `[Watchdog] Failed to process session ${sessionId}:`,
          error
        );
        results.push({sessionId, result: `error: ${error}`});
      }
    }

    console.log("[Watchdog] Results:", JSON.stringify(results));
  }
);

// Settles one abandoned session. Authoritative billing values come
// from the session doc itself (durationMinutes / totalCharged /
// priestEarnings) — billingTick is the only thing that should ever
// have incremented those, and we trust it. The watchdog never
// recharges minutes that billingTick already processed; doing so
// would double-bill a user whose phone died in the middle of a
// minute that the server had already settled.
async function processStaleSession(
  sessionId: string,
  session: admin.firestore.DocumentData
): Promise<void> {
  const sessionRef = db.doc(`sessions/${sessionId}`);
  const rate = Number(session.ratePerMinute ?? 10);
  const commission = Number(session.commissionPercent ?? 20);
  // Math.floor matches billingTick — integer-only coin accounting,
  // commission pool absorbs the rounding remainder.
  const priestEarningPerMinute = Math.floor(
    rate * (1 - commission / 100)
  );

  let finalDuration = Number(session.durationMinutes ?? 0);
  let finalTotalCharged = Number(session.totalCharged ?? 0);
  let finalPriestEarnings = Number(session.priestEarnings ?? 0);
  let didMinimumCharge = false;

  // EDGE CASE — session went active but no billingTick ever ran
  // (app crashed inside the first 60s). Apply the minimum 1-minute
  // charge here so the priest still earns for showing up.
  if (finalDuration === 0) {
    console.log(
      `[Watchdog] Session ${sessionId}: 0 billed minutes — ` +
      "applying minimum 1-minute charge"
    );

    const userRef = db.doc(`users/${session.userId}`);
    const userDoc = await userRef.get();
    const userBalance = Number(userDoc.data()?.coinBalance ?? 0);

    if (userBalance >= rate) {
      const priestRef = db.doc(`priests/${session.priestId}`);
      const batch = db.batch();

      batch.update(userRef, {
        coinBalance: admin.firestore.FieldValue.increment(-rate),
      });

      batch.update(priestRef, {
        walletBalance: admin.firestore.FieldValue.increment(
          priestEarningPerMinute
        ),
        totalEarnings: admin.firestore.FieldValue.increment(
          priestEarningPerMinute
        ),
      });

      // Ledger row for the wallet history. Description tags the
      // charge as watchdog-driven so the source is auditable.
      const txRef = db.collection("wallet_transactions").doc();
      batch.set(txRef, {
        userId: session.userId,
        type: "session_charge",
        sessionId: sessionId,
        coins: -rate,
        description:
          `${session.type} session — minimum charge (watchdog)`,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
      });

      await batch.commit();

      finalDuration = 1;
      finalTotalCharged = rate;
      finalPriestEarnings = priestEarningPerMinute;
      didMinimumCharge = true;
    } else {
      // User can't afford the minimum minute. createSessionRequest
      // already verifies balance before accepting, so this branch
      // is genuinely rare — log it and end with 0 charge rather
      // than putting the user negative.
      console.log(
        `[Watchdog] Session ${sessionId}: User balance ${userBalance} ` +
        `< rate ${rate} — ending with 0 charge`
      );
    }
  }

  // STEP 3 — Settle the session doc. Carry forward whatever
  // billingTick already accumulated; only the duration / totals
  // touched above (if minimum charge applied) differ from what
  // the doc already had.
  await sessionRef.update({
    status: "completed",
    endedAt: admin.firestore.FieldValue.serverTimestamp(),
    endReason: "watchdog_timeout",
    durationMinutes: finalDuration,
    totalCharged: finalTotalCharged,
    priestEarnings: finalPriestEarnings,
  });

  // STEP 4 — Bump priest's lifetime session count. Mirrors what
  // endSession does so abandoned sessions still count toward the
  // priest's stats.
  await db.doc(`priests/${session.priestId}`).update({
    totalSessions: admin.firestore.FieldValue.increment(1),
  });

  // STEP 5 — Notify both sides so they understand WHY the session
  // disappeared from active state. Without this the user just
  // sees their balance dropped with no explanation.
  const notifBatch = db.batch();

  const userNotifRef = db.collection("notifications").doc();
  notifBatch.set(userNotifRef, {
    userId: session.userId,
    type: "session_ended",
    title: "Session Ended",
    body:
      `Your ${session.type} session with ` +
      `${session.priestName ?? "the speaker"} ended due to ` +
      `connection timeout. Duration: ${finalDuration} min. ` +
      `Charged: ${finalTotalCharged} coins.`,
    sessionId: sessionId,
    isRead: false,
    createdAt: admin.firestore.FieldValue.serverTimestamp(),
  });

  const priestNotifRef = db.collection("notifications").doc();
  notifBatch.set(priestNotifRef, {
    userId: session.priestId,
    type: "session_ended",
    title: "Session Ended",
    body:
      `Your ${session.type} session with ` +
      `${session.userName ?? "the user"} ended due to ` +
      `connection timeout. Duration: ${finalDuration} min. ` +
      `Earned: ₹${finalPriestEarnings}.`,
    sessionId: sessionId,
    isRead: false,
    createdAt: admin.firestore.FieldValue.serverTimestamp(),
  });

  await notifBatch.commit();

  console.log(
    `[Watchdog] Session ${sessionId} ended. ` +
    `Duration: ${finalDuration} min. ` +
    `Charged: ${finalTotalCharged} coins. ` +
    `Priest earned: ${finalPriestEarnings} coins. ` +
    `Min charge applied: ${didMinimumCharge}`
  );
}
