// Server-side maintainer of bible_sessions/{sid}.registrationCount
// AND user / priest notifications around registration events.
//
// Counter classification (every write maps to a +1/0/-1 delta):
//
//   create as 'registered'                  → +1
//   create as 'paid' (Admin-SDK seed)       → +1
//   'registered'/'paid' → 'cancelled'       → -1
//   'cancelled' → 'registered'              → +1   (re-register)
//   'registered' → 'paid'                   →  0   (still active)
//   delete while active                     → -1
//   delete while already cancelled          →  0
//
// Notifications fire only on a +1 transition (genuine new active
// registration). Cancellations and pay-flips reach the user via
// other surfaces (in-app snackbar / verifyBibleSessionPayment) so
// we deliberately don't double up here.
//
// The count update + reads share a transaction so:
//   • the post-update count is known atomically (needed for
//     milestone classification — "did this write make us hit
//     maxParticipants?")
//   • a session doc deleted between trigger fire and read doesn't
//     cause a count write against a missing parent.
//
// Why this lives in a CF and not on the client:
// Firestore rules deny user-side writes to the parent bible_sessions
// doc (only the priest can update it). A client-side increment is
// always permission-denied and the count drifts to zero. Same logic
// for the priest-targeted milestone notifications: clients can't
// write `/notifications` docs (rule denies create), so the Admin SDK
// is the only path.

import {onDocumentWritten} from "firebase-functions/v2/firestore";
import * as admin from "firebase-admin";
import {REGION} from "../config/constants";
import {sendPushNotification} from "../notifications/sendPush";

const db = admin.firestore();

export const onBibleRegistrationWrite = onDocumentWritten(
  {
    document: "bible_sessions/{sessionId}/registrations/{regId}",
    region: REGION,
  },
  async (event) => {
    const sessionId = event.params.sessionId;
    const regId = event.params.regId;
    const before = event.data?.before;
    const after = event.data?.after;

    // "Active" = the registration currently consumes a seat. Non-
    // existent or cancelled docs aren't active. This single
    // comparison reduces every transition (create / update / delete)
    // to a +1 / 0 / -1 delta without enumerating each case.
    const wasActive =
      before?.exists === true &&
      (before.data()?.status as string | undefined) !== "cancelled";
    const isActive =
      after?.exists === true &&
      (after.data()?.status as string | undefined) !== "cancelled";

    let delta = 0;
    if (!wasActive && isActive) delta = 1;
    if (wasActive && !isActive) delta = -1;
    if (delta === 0) return;

    // Transaction lets us:
    //   1. read the current count + session metadata in one round
    //      trip so the milestone-detection logic is race-free against
    //      simultaneous registrations.
    //   2. write the new count atomically — Math.max(0, ...) guards
    //      against a stale doc (e.g. count never seeded) going
    //      negative on a cancel.
    let postCount = 0;
    let sessionTitle = "Bible Session";
    let priestId: string | undefined;
    let maxParticipants = 0;
    let txOk = false;

    try {
      await db.runTransaction(async (tx) => {
        const sessionRef = db.doc(`bible_sessions/${sessionId}`);
        const snap = await tx.get(sessionRef);
        if (!snap.exists) return;
        const data = snap.data() ?? {};
        const currentCount =
          (data.registrationCount as number | undefined) ?? 0;
        postCount = Math.max(0, currentCount + delta);
        sessionTitle = String(data.title ?? "Bible Session");
        priestId = data.priestId as string | undefined;
        maxParticipants =
          (data.maxParticipants as number | undefined) ?? 0;
        tx.update(sessionRef, {registrationCount: postCount});
        txOk = true;
      });
    } catch (err) {
      // Don't bubble — the registration write already succeeded; a
      // missing or deleted parent session shouldn't poison the
      // trigger. Logging is enough; the next manual reconciliation
      // can re-derive the count from the subcollection size.
      console.error(
        "[onBibleRegistrationWrite] count update failed for " +
          `${sessionId} (delta=${delta}):`,
        err,
      );
      return;
    }

    if (!txOk) return;

    // Notifications only fire on a +1 transition (new registration
    // or re-register). Cancel + pay surfaces are handled elsewhere.
    if (delta !== 1) return;

    // Skip the user-facing "Registration Confirmed" inbox + push
    // when payAndJoinBibleSession already wrote the more-informative
    // "You're in! 🙏 + meeting link" doc for this user. Two flags
    // cover both paths:
    //   • paidOnCreate  — first-time create as 'paid' (never-
    //                     registered user pays directly).
    //   • paidViaUpdate — cancelled → paid update (re-pay after
    //                     cancel). Without this the trigger sees a
    //                     +1 delta and fires the redundant
    //                     "Registration Confirmed" doc.
    // Priest milestone notifications still fire either way.
    const afterData = after?.data() ?? {};
    const skipUserConfirmation =
      afterData.paidOnCreate === true ||
      afterData.paidViaUpdate === true;

    // ── User confirmation ───────────────────────────────────────────
    // The user just registered — write an inbox doc + push so they
    // get a warm acknowledgement that survives a missed snackbar.
    if (!skipUserConfirmation) {
      try {
        const userNotif = db.collection("notifications").doc();
        await userNotif.set({
          userId: regId,
          type: "bible_session_registered",
          title: "Registration Confirmed 🙏",
          body:
            `You're registered for "${sessionTitle}". ` +
            "May this session bless your journey.",
          sessionId,
          data: {sessionId},
          isRead: false,
          createdAt: admin.firestore.FieldValue.serverTimestamp(),
        });
      } catch (err) {
        console.error(
          "[onBibleRegistrationWrite] user notif write failed for " +
            `${sessionId}:`,
          err,
        );
      }

      await sendPushNotification({
        userId: regId,
        title: "Registration Confirmed 🙏",
        body: `You're registered for "${sessionTitle}"`,
        data: {
          type: "bible_session_registered",
          sessionId,
          route: `/bible/detail/${sessionId}`,
        },
      });
    }

    // ── Priest milestones ───────────────────────────────────────────
    // No inbox doc for these — they're motivational nudges, push only.
    // Inbox would just become noisy for popular sessions.
    if (!priestId) return;

    const userName = String(after?.data()?.userName ?? "Someone");

    // First registration — postCount == 1 with delta == +1 means we
    // just transitioned 0 → 1 (the very first attendee).
    if (postCount === 1) {
      await sendPushNotification({
        userId: priestId,
        title: "🎉 First Registration!",
        body:
          `${userName} registered for "${sessionTitle}". ` +
          "Your session is gaining interest!",
        data: {
          type: "bible_session_first_registration",
          sessionId,
          route: `/priest/bible/${sessionId}`,
        },
      });
    }

    // Session full — fire only on the EXACT transition to capacity.
    // (postCount - delta) is the pre-write count; if it was below
    // max and post is at-or-above, this write was the one that hit
    // the cap. Without this guard, every subsequent write while the
    // session is full would re-fire the push.
    if (
      maxParticipants > 0 &&
      postCount >= maxParticipants &&
      postCount - delta < maxParticipants
    ) {
      await sendPushNotification({
        userId: priestId,
        title: "🙏 Session Full!",
        body:
          `"${sessionTitle}" has reached full capacity ` +
          `with ${postCount} registrations!`,
        data: {
          type: "bible_session_full",
          sessionId,
          route: `/priest/bible/${sessionId}`,
        },
      });
    }
  },
);
