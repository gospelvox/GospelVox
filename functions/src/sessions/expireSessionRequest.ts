// User-side 60-second countdown handoff. Called fire-and-forget
// from session_request_cubit when the local timer hits zero — the
// CF marks the session expired AND notifies the priest about the
// missed request in one atomic op so a successful CF call always
// produces a priest notification.
//
// Why this exists vs writing status from the client:
//   • Firestore rules don't allow the user to write `endReason`
//     on a session, and the priest notification doc must be
//     CF-only (rules say so). Both writes need server authority.
//   • Client-side direct-write would race with the watchdog: if
//     status='expired' is written from the client, the watchdog
//     can't tell whether the priest was already notified. Routing
//     through this CF gives a single notify-once code path.
//
// Race with the watchdog cron:
//   The watchdog has a separate branch that sweeps pending sessions
//   older than 60s. If this CF call fails (network blip, app killed
//   before fire-and-forget completed), the watchdog catches the
//   stuck pending session at the next 5-minute tick and notifies
//   the priest from there. Both paths set status='expired' and use
//   the same notifyPriestMissedRequest helper, so the priest always
//   gets exactly one missed_request notification per stuck session.
//
// We deliberately reject if status != 'pending':
//   • Already 'expired' — somebody (this CF or the watchdog) already
//     processed it, no double-notify.
//   • 'active' — priest accepted while the user's countdown was
//     ticking down; the user shouldn't be able to undo that.
//   • 'cancelled' / 'declined' — terminal, leave alone.

import {onCall, HttpsError} from "firebase-functions/v2/https";
import * as admin from "firebase-admin";
import {REGION} from "../config/constants";
import {notifyPriestMissedRequest} from "./missedRequestNotif";

const db = admin.firestore();

export const expireSessionRequest = onCall(
  {region: REGION},
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Must be logged in");
    }

    const uid = request.auth.uid;
    const sessionId = request.data?.sessionId as string | undefined;
    if (!sessionId || typeof sessionId !== "string") {
      throw new HttpsError("invalid-argument", "Missing sessionId");
    }

    const sessionRef = db.doc(`sessions/${sessionId}`);

    // Transaction wrapper closes the TOCTOU race with the watchdog
    // cron's stuck-pending branch. Both writers attempt to flip
    // status='pending' → 'expired'; the loser of the race retries
    // and sees status != 'pending' on the second pass, exiting
    // before sending a duplicate notification. Without this, two
    // concurrent reads-then-writes can both pass the status guard
    // and each fire a notification, double-pushing the priest.
    //
    // Returns the loaded session data when this call won the race
    // so the notify step outside the transaction has the priest's
    // denormalized info to work with. Throws permission-denied
    // synchronously inside the transaction so the rules-style
    // error message reaches the cubit unchanged.
    type TxOutcome =
      | {kind: "won"; session: admin.firestore.DocumentData}
      | {kind: "alreadyTerminal"};

    const outcome: TxOutcome = await db.runTransaction(async (tx) => {
      const snap = await tx.get(sessionRef);
      if (!snap.exists) {
        // Idempotent — a session that's already been deleted is
        // not a hard error from the caller's perspective.
        return {kind: "alreadyTerminal"};
      }

      const session = snap.data()!;

      // The user who owns the request, OR the priest it's addressed
      // to, may expire it on timeout. The priest path is essential
      // when the USER's app was killed mid-ring: the user's countdown
      // can no longer fire, so the priest's own 60s countdown becomes
      // the thing that releases the request — and clears the priest's
      // isBusy flag via onSessionTerminal. Without it the priest would
      // stay Busy until the 5-minute watchdog. The transaction below
      // still guarantees exactly-one missed_request even if the user's
      // and priest's countdowns race. Admins don't expire here.
      if (session.userId !== uid && session.priestId !== uid) {
        throw new HttpsError(
          "permission-denied",
          "Only a participant can expire this session"
        );
      }

      // Only pending sessions are eligible. Anything else is
      // already terminal — succeed quietly so a late cubit call
      // after the priest accepted doesn't error.
      if (session.status !== "pending") {
        return {kind: "alreadyTerminal"};
      }

      tx.update(sessionRef, {
        status: "expired",
        endedAt: admin.firestore.FieldValue.serverTimestamp(),
        endReason: "request_timeout",
      });

      return {kind: "won", session};
    });

    if (outcome.kind === "alreadyTerminal") {
      return {success: true, alreadyTerminal: true};
    }

    // Notification fires only when this CF won the status flip —
    // guaranteed exactly-once. If notify fails after a successful
    // status flip the session is still correctly marked expired
    // and the watchdog won't re-process it (its query is for
    // status='pending'). At worst we silently lose ONE
    // notification, never duplicate.
    await notifyPriestMissedRequest({
      session: outcome.session,
      sessionId: sessionId,
    });

    return {success: true, alreadyTerminal: false};
  }
);
