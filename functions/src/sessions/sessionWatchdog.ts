import {onSchedule} from "firebase-functions/v2/scheduler";
import * as admin from "firebase-admin";
import {REGION} from "../config/constants";
import {sendPushNotification} from "../notifications/sendPush";
import {notifyPriestMissedRequest} from "./missedRequestNotif";
import {connectionEpochMs} from "./connection";
import {notifyConnectionFailed} from "./notifyConnectionFailed";

const db = admin.firestore();

// How long after the last client heartbeat we treat a session as
// abandoned. 2 minutes is the product contract — short enough that
// crashed sessions don't tie up a priest forever, long enough to
// absorb slow networks and brief OEM doze. Don't shrink without
// also shrinking the client heartbeat cadence (currently 30s).
const HEARTBEAT_TIMEOUT_MS = 2 * 60 * 1000;

// Pending requests stuck without a priest response are eligible
// for expiry once they're older than this. Matches the user-side
// 60s countdown — anything older means either:
//   • the priest never responded AND the user-side
//     expireSessionRequest CF call failed (network blip, app
//     killed before the fire-and-forget landed), OR
//   • the user closed the waiting screen without expireSessionRequest
//     running (e.g. force-quit during the 60s window).
// Either way, the priest deserves the missed-request notification
// — this watchdog branch is the safety net that ensures it.
const PENDING_REQUEST_TIMEOUT_MS = 60 * 1000;

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

    // STEP 1A — Find every active session whose last heartbeat is
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
      console.log("[Watchdog] No stale active sessions found.");
    } else {
      console.log(
        `[Watchdog] Found ${staleSessions.size} stale active session(s)`
      );
    }

    // STEP 1B — Find pending sessions older than 60s. These are
    // requests where the priest never responded AND the user-side
    // expireSessionRequest call didn't land. Composite index:
    //   sessions: status (asc), createdAt (asc)
    // First production run will log a console URL to provision.
    const pendingCutoff = admin.firestore.Timestamp.fromMillis(
      now.toMillis() - PENDING_REQUEST_TIMEOUT_MS
    );
    const stuckPending = await db
      .collection("sessions")
      .where("status", "==", "pending")
      .where("createdAt", "<", pendingCutoff)
      .get();

    if (stuckPending.empty) {
      console.log("[Watchdog] No stuck pending requests found.");
    } else {
      console.log(
        `[Watchdog] Found ${stuckPending.size} stuck pending request(s)`
      );
    }

    if (staleSessions.empty && stuckPending.empty) {
      console.log("[Watchdog] All clear.");
      return;
    }

    // STEP 2 — Process each session / priest independently.
    // Per-doc try/catch so a single bad doc doesn't block the
    // watchdog from cleaning up the rest of the queue.
    const results: Array<{id: string; result: string}> = [];

    for (const sessionDoc of staleSessions.docs) {
      const sessionId = sessionDoc.id;
      try {
        await processStaleSession(sessionId, sessionDoc.data());
        results.push({id: sessionId, result: "ended"});
      } catch (error) {
        console.error(
          `[Watchdog] Failed to process active session ${sessionId}:`,
          error
        );
        results.push({id: sessionId, result: `error: ${error}`});
      }
    }

    for (const sessionDoc of stuckPending.docs) {
      const sessionId = sessionDoc.id;
      try {
        await processStuckPending(sessionId, sessionDoc.data());
        results.push({id: sessionId, result: "expired"});
      } catch (error) {
        console.error(
          `[Watchdog] Failed to process stuck pending ${sessionId}:`,
          error
        );
        results.push({id: sessionId, result: `error: ${error}`});
      }
    }

    console.log("[Watchdog] Results:", JSON.stringify(results));
  }
);

// Marks a stuck pending request as expired and notifies the priest.
// Mirrors what expireSessionRequest does for the user-side cubit
// path — kept as a separate function rather than calling the
// HTTPS callable internally because admin SDK writes are simpler
// than re-routing through the request stack, and we want this to
// run regardless of any client auth state.
//
// TOCTOU-safe: status flip happens inside a transaction so a race
// with expireSessionRequest CF can't produce duplicate
// notifications. The loser of the race retries the transaction,
// sees status != 'pending' on the second pass, and exits before
// the notify step ever runs.
async function processStuckPending(
  sessionId: string,
  fallbackSession: admin.firestore.DocumentData
): Promise<void> {
  const sessionRef = db.doc(`sessions/${sessionId}`);

  type TxOutcome =
    | {kind: "won"; session: admin.firestore.DocumentData}
    | {kind: "alreadyTerminal"};

  const outcome: TxOutcome = await db.runTransaction(async (tx) => {
    const snap = await tx.get(sessionRef);
    if (!snap.exists) return {kind: "alreadyTerminal"};
    const session = snap.data()!;
    if (session.status !== "pending") return {kind: "alreadyTerminal"};

    tx.update(sessionRef, {
      status: "expired",
      endedAt: admin.firestore.FieldValue.serverTimestamp(),
      endReason: "watchdog_pending_timeout",
    });

    return {kind: "won", session};
  });

  if (outcome.kind === "alreadyTerminal") {
    console.log(
      `[Watchdog] Session ${sessionId} no longer pending — skipping.`
    );
    return;
  }

  await notifyPriestMissedRequest({
    // Prefer the freshly-loaded data from the transaction so any
    // late denormalized field updates are reflected in the
    // notification body. fallbackSession (from the original query)
    // is only used if the transaction read somehow returned empty.
    session: outcome.session ?? fallbackSession,
    sessionId: sessionId,
  });

  console.log(
    `[Watchdog] Stuck pending ${sessionId} expired and priest notified.`
  );
}

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

  // CONNECTION GATE — only an abandoned session that actually reached
  // a confirmed two-way connection may be charged. A session that was
  // "active" but never connected (priest stuck "Connecting", user app
  // died before connecting) settles free: 0 charge, 0 commission.
  const connectedEpochMs = connectionEpochMs(session);

  // EDGE CASE — session went active, connected, but no billingTick
  // ever ran (app crashed inside the first 60s). Apply the minimum
  // 1-minute charge here so the priest still earns for showing up.
  // Gated on a real connection — we never minimum-charge a call that
  // never connected.
  if (finalDuration === 0 && connectedEpochMs !== null) {
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

      // Priest-side earning row + platform-commission row, co-located
      // with the credit so the ledger always agrees with the wallet
      // (see billingTick.ts for the rationale).
      const priestTxRef = db.collection("wallet_transactions").doc();
      batch.set(priestTxRef, {
        userId: session.priestId,
        type: "session_earning",
        sessionId: sessionId,
        coins: priestEarningPerMinute,
        description:
          `${session.type} session earning — minimum charge (watchdog)`,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
      });

      const platformCommission = rate - priestEarningPerMinute;
      if (platformCommission > 0) {
        const platformTxRef = db.collection("wallet_transactions").doc();
        batch.set(platformTxRef, {
          userId: "__platform__",
          type: "session_commission",
          sessionId: sessionId,
          coins: platformCommission,
          description: `Commission — ${session.type} session`,
          createdAt: admin.firestore.FieldValue.serverTimestamp(),
        });
      }

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
    // A never-connected abandoned session is "connection_failed";
    // a connected-then-abandoned one is "watchdog_timeout".
    endReason:
      connectedEpochMs === null ? "connection_failed" : "watchdog_timeout",
    durationMinutes: finalDuration,
    totalCharged: finalTotalCharged,
    priestEarnings: finalPriestEarnings,
  });

  // STEP 4 — Bump priest's lifetime session count. Mirrors what
  // endSession does so abandoned sessions still count toward the
  // priest's stats. Also clear isBusy — the session ended (even
  // if abandoned), so the user feed shouldn't keep showing this
  // priest as Busy. The priest-stale-heartbeat sweep above might
  // already have flipped isBusy in parallel for the same priest;
  // both writes converge to false, so the order doesn't matter.
  await db.doc(`priests/${session.priestId}`).update({
    totalSessions: admin.firestore.FieldValue.increment(1),
    isBusy: false,
  });

  // STEP 5 — Notify both sides so they understand WHY the session
  // disappeared from active state. Two flavours:
  //   • never connected  → clear "couldn't connect, no charge" copy
  //   • connected then abandoned → charged-summary copy below
  if (connectedEpochMs === null) {
    await notifyConnectionFailed({session: session, sessionId: sessionId});
    console.log(
      `[Watchdog] Session ${sessionId} never connected — ` +
      "settled free, both sides notified."
    );
    return;
  }

  const notifBatch = db.batch();

  const userNotifRef = db.collection("notifications").doc();
  notifBatch.set(userNotifRef, {
    userId: session.userId,
    type: "session_ended",
    title: "Session Ended",
    body:
      `Your ${session.type} session with ` +
      `${session.priestName ?? "the speaker"} ended due to a ` +
      `connection issue. Duration: ${finalDuration} min. ` +
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
      `${session.userName ?? "the user"} ended due to a ` +
      `connection issue. Duration: ${finalDuration} min. ` +
      `Earned: ₹${finalPriestEarnings}.`,
    sessionId: sessionId,
    isRead: false,
    createdAt: admin.firestore.FieldValue.serverTimestamp(),
  });

  await notifBatch.commit();

  // Push both sides so the abandoned-session outcome lands as a
  // visible OS notification, not just an in-app inbox entry. Most
  // useful when the user's app crashed (which is why we got here) —
  // they need to know their balance changed.
  await sendPushNotification({
    userId: session.userId,
    title: "Session Ended",
    body:
      `Your ${session.type} session ended due to a connection issue. ` +
      `Duration: ${finalDuration} min. ` +
      `Charged: ${finalTotalCharged} coins.`,
    data: {
      type: "session_ended",
      sessionId: sessionId,
      route: "/user",
    },
  });

  await sendPushNotification({
    userId: session.priestId,
    title: "Session Ended",
    body:
      `Your ${session.type} session ended due to a connection issue. ` +
      `Duration: ${finalDuration} min. ` +
      `Earned: ₹${finalPriestEarnings}.`,
    data: {
      type: "session_ended",
      sessionId: sessionId,
      route: "/priest",
    },
  });

  console.log(
    `[Watchdog] Session ${sessionId} ended. ` +
    `Duration: ${finalDuration} min. ` +
    `Charged: ${finalTotalCharged} coins. ` +
    `Priest earned: ${finalPriestEarnings} coins. ` +
    `Min charge applied: ${didMinimumCharge}`
  );
}
