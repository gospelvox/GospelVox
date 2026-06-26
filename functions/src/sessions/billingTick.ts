import {onCall, HttpsError} from "firebase-functions/v2/https";
import * as admin from "firebase-admin";
import {REGION} from "../config/constants";
import {connectionEpochMs} from "./connection";
import {notifyConnectionFailed} from "./notifyConnectionFailed";
import {sendPushNotification} from "../notifications/sendPush";

// How long a session may sit "active" without BOTH sides confirming a
// real connection before we treat it as failed-to-connect and end it
// free. Comfortably longer than a healthy Agora handshake (a few
// seconds) so we never void a call that genuinely connected slowly.
const CONNECT_GRACE_MS = 75 * 1000;

const db = admin.firestore();

// Deducts one minute's worth of coins from the user and credits the
// priest's share. Called by the USER'S client every 60s while the
// session is active — never by the priest, to avoid double-billing.
//
// All mutations land in a single batch so a partial failure can't
// leave the user debited without the priest credited (or vice
// versa). The wallet_transactions write is part of the same batch
// so the ledger always agrees with the wallet.
//
// Returns `shouldEnd: true` when the user can no longer afford
// another minute — the client treats that as the authoritative
// signal to stop its local timers and navigate to the summary.
export const billingTick = onCall(
  {region: REGION},
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Must be logged in");
    }

    const sessionId = request.data?.sessionId as string | undefined;
    if (!sessionId) {
      throw new HttpsError("invalid-argument", "Missing sessionId");
    }

    const sessionRef = db.doc(`sessions/${sessionId}`);
    const sessionSnap = await sessionRef.get();

    if (!sessionSnap.exists) {
      throw new HttpsError("not-found", "Session not found");
    }

    const session = sessionSnap.data() ?? {};

    // Only the user in this session may trigger billing. This is
    // belt-and-braces — the client restricts billing to user-side
    // already, but a compromised client shouldn't be able to bill
    // on behalf of someone else.
    if (request.auth.uid !== session.userId) {
      throw new HttpsError(
        "permission-denied",
        "Only the session user can trigger billing"
      );
    }

    // If the session is already terminal we short-circuit with the
    // existing totals. Lets the client observe shouldEnd=true and
    // stop ticking instead of repeatedly hitting this CF.
    if (session.status !== "active") {
      return {
        remainingBalance: 0,
        totalCharged: Number(session.totalCharged ?? 0),
        durationMinutes: Number(session.durationMinutes ?? 0),
        shouldEnd: true,
      };
    }

    const rate = Number(session.ratePerMinute ?? 10);
    const commission = Number(session.commissionPercent ?? 20);
    // Math.floor so integer-only coin accounting never leaks a
    // fractional coin to the priest. The commission pool absorbs
    // the rounding remainder.
    const priestEarningPerMinute = Math.floor(
      rate * (1 - commission / 100)
    );

    const userRef = db.doc(`users/${session.userId}`);
    const userSnap = await userRef.get();
    const currentBalance = Number(userSnap.data()?.coinBalance ?? 0);

    // CONNECTION GATE — never charge until BOTH sides confirmed a real
    // two-way connection. Until then the user pays nothing and the
    // priest earns nothing, no matter how long the session sits
    // "active". This is what kills the "billed for a call that never
    // connected" bug and stops a priest farming commission on dead
    // calls.
    const connectedEpochMs = connectionEpochMs(session);
    if (connectedEpochMs === null) {
      const startedAtMs = (
        session.startedAt as admin.firestore.Timestamp | undefined
      )?.toMillis();
      const ageMs = startedAtMs ? Date.now() - startedAtMs : 0;

      // Past the connect window with no confirmation → the call never
      // connected. End it free: 0 charge, 0 commission.
      if (ageMs >= CONNECT_GRACE_MS) {
        await sessionRef.update({
          status: "completed",
          endedAt: admin.firestore.FieldValue.serverTimestamp(),
          endReason: "connection_failed",
          durationMinutes: 0,
          totalCharged: 0,
          priestEarnings: 0,
        });

        // Tell both sides clearly: the call never connected and no
        // coins were taken. Without this the user's screen would just
        // close with no explanation for the (zero) balance change.
        await notifyConnectionFailed({session: session, sessionId: sessionId});

        return {
          remainingBalance: currentBalance,
          totalCharged: 0,
          durationMinutes: 0,
          shouldEnd: true,
        };
      }

      // Still inside the connect window — don't charge, keep waiting.
      return {
        remainingBalance: currentBalance,
        totalCharged: 0,
        durationMinutes: Number(session.durationMinutes ?? 0),
        shouldEnd: false,
      };
    }

    // Not enough coins for another minute — settle the session
    // right here. We still return the current totals so the client
    // renders the correct final state without a second round trip.
    if (currentBalance < rate) {
      await sessionRef.update({
        status: "completed",
        endedAt: admin.firestore.FieldValue.serverTimestamp(),
        endReason: "balance_zero",
      });

      // Notify both sides. billingTick settles this end itself, so
      // endSession's idempotent fast-path returns before its own notify
      // block — without this, a "ran out of coins" end would be the ONE
      // ending that leaves no inbox entry / push, unlike every other.
      // Fully wrapped + best-effort: a notify failure must NEVER roll
      // back the settle above. (sendPushNotification already swallows
      // its own errors; the try/catch guards the inbox-batch commit.)
      // Fires once — later billingTicks short-circuit on status!=active
      // and endSession's idempotent path doesn't notify.
      const durationMinutes = Number(session.durationMinutes ?? 0);
      const totalCharged = Number(session.totalCharged ?? 0);
      const priestEarnings = Number(session.priestEarnings ?? 0);
      const sessionType = session.type ?? "chat";
      try {
        const notifBatch = db.batch();
        notifBatch.set(db.collection("notifications").doc(), {
          userId: session.userId,
          type: "session_ended",
          title: "Session Ended",
          body:
            `Your ${sessionType} session ended — your coins ran out. ` +
            `Duration: ${durationMinutes} min. ${totalCharged} coins used.`,
          sessionId: sessionId,
          isRead: false,
          createdAt: admin.firestore.FieldValue.serverTimestamp(),
        });
        notifBatch.set(db.collection("notifications").doc(), {
          userId: session.priestId,
          type: "session_ended",
          title: "Session Ended",
          body:
            `Your ${sessionType} session ended ` +
            `(the user's balance ran out). ` +
            `Duration: ${durationMinutes} min. ₹${priestEarnings} earned.`,
          sessionId: sessionId,
          isRead: false,
          createdAt: admin.firestore.FieldValue.serverTimestamp(),
        });
        await notifBatch.commit();

        await sendPushNotification({
          userId: session.userId,
          title: "Session Ended",
          body:
            `Your ${sessionType} session ended — coins ran out. ` +
            `${totalCharged} coins used.`,
          data: {type: "session_ended", sessionId: sessionId, route: "/user"},
        });
        await sendPushNotification({
          userId: session.priestId,
          title: "Session Ended",
          body: `Your ${sessionType} session ended. ₹${priestEarnings} earned.`,
          data: {
            type: "session_ended",
            sessionId: sessionId,
            route: "/priest",
          },
        });
      } catch (e) {
        console.error("[billingTick] balance_zero notify failed:", e);
      }

      return {
        remainingBalance: currentBalance,
        totalCharged: Number(session.totalCharged ?? 0),
        durationMinutes: Number(session.durationMinutes ?? 0),
        shouldEnd: true,
      };
    }

    const priestRef = db.doc(`priests/${session.priestId}`);

    const newDuration = Number(session.durationMinutes ?? 0) + 1;
    const newTotalCharged = Number(session.totalCharged ?? 0) + rate;
    const newPriestEarnings =
      Number(session.priestEarnings ?? 0) + priestEarningPerMinute;

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

    batch.update(sessionRef, {
      durationMinutes: newDuration,
      totalCharged: newTotalCharged,
      priestEarnings: newPriestEarnings,
      lastHeartbeat: admin.firestore.FieldValue.serverTimestamp(),
    });

    // Ledger entry for the wallet screen. `-rate` convention matches
    // the coin-purchase flow so the history list can render both
    // credits and debits the same way.
    const txRef = db.collection("wallet_transactions").doc();
    batch.set(txRef, {
      userId: session.userId,
      type: "session_charge",
      sessionId: sessionId,
      coins: -rate,
      description: `${session.type} session — minute ${newDuration}`,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
    });

    // Priest-side EARNING ledger row — mirrors the bible-session
    // earning row so the priest's wallet History shows call/chat
    // income (previously only the priest-doc counters moved, leaving
    // History empty for every call/chat earning). Written in the SAME
    // batch as the credit above, so it can never disagree with the
    // walletBalance increment.
    const priestTxRef = db.collection("wallet_transactions").doc();
    batch.set(priestTxRef, {
      userId: session.priestId,
      type: "session_earning",
      sessionId: sessionId,
      coins: priestEarningPerMinute,
      description: `${session.type} session earning — minute ${newDuration}`,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
    });

    // Platform COMMISSION ledger row — the slice the platform retains
    // (rate − priest share, incl. the floor remainder). Addressed to
    // the `__platform__` sentinel uid so the admin revenue dashboard
    // sums call/chat commission the same way it already sums bible
    // commission. Skipped when zero so the ledger isn't polluted.
    const platformCommissionPerMinute = rate - priestEarningPerMinute;
    if (platformCommissionPerMinute > 0) {
      const platformTxRef = db.collection("wallet_transactions").doc();
      batch.set(platformTxRef, {
        userId: "__platform__",
        type: "session_commission",
        sessionId: sessionId,
        coins: platformCommissionPerMinute,
        description: `Commission — ${session.type} session`,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    }

    await batch.commit();

    const newBalance = currentBalance - rate;

    return {
      remainingBalance: newBalance,
      totalCharged: newTotalCharged,
      durationMinutes: newDuration,
      // If the user can't afford another minute we tell the client
      // to wind down now, rather than waiting for the next tick.
      shouldEnd: newBalance < rate,
    };
  }
);
