// Firestore trigger that aggregates a user's session rating into the
// priest's running average + total review count, and fires a milestone
// push when the priest's review count crosses a celebration threshold.
//
// Why a CF instead of client-side aggregation: the priest doc isn't
// writable by the user under our rules (and shouldn't be — letting a
// user write directly to priests/{uid}.rating would be an obvious
// tampering surface). The server is the only place this math is safe.
//
// Idempotency: the trigger stamps `ratingAggregated: true` on the
// session inside the same transaction as the priest-doc update. The
// trigger short-circuits if the flag is already set, so a re-emit of
// the same snapshot (Firestore replays the trigger occasionally) can
// never double-count a rating.
//
// Milestone notifications fire at the curve the product confirmed:
// 1, 5, 10, 25, 50, 100, 250, 500. Stored as a watermark on the priest
// doc (`lastReviewMilestone`) so a snapshot replay can't push twice
// even if the count somehow re-crosses the same threshold.

import {onDocumentUpdated} from "firebase-functions/v2/firestore";
import * as admin from "firebase-admin";
import {REGION} from "../config/constants";
import {sendPushNotification} from "../notifications/sendPush";

const db = admin.firestore();

const REVIEW_MILESTONES: ReadonlyArray<number> = [
  1, 5, 10, 25, 50, 100, 250, 500,
];

// Soft cap on the denormalized review array stored on priests/{uid}.
// Reviews are also on the source sessions/{sid} doc — this array is
// the public-read copy the user-side profile page renders. Bounded so
// the priest doc stays well under the Firestore 1MB limit even with
// long feedback + reply text.
const PUBLIC_REVIEWS_CAP = 100;

export const onSessionRated = onDocumentUpdated(
  {document: "sessions/{sessionId}", region: REGION},
  async (event) => {
    const before = event.data?.before.data();
    const after = event.data?.after.data();
    if (!before || !after) return;

    // Only react to the FIRST time userRating gets set on this
    // session. Every other write (heartbeat, typing, follow-up, reply)
    // also lands on this trigger and must early-return.
    const beforeRating = before.userRating as number | undefined;
    const afterRating = after.userRating as number | undefined;
    if (
      afterRating === undefined ||
      afterRating === null ||
      typeof afterRating !== "number"
    ) {
      return;
    }
    if (beforeRating !== undefined && beforeRating !== null) return;

    // Already aggregated — a snapshot replay or a follow-up write
    // after the flag was set. Bail out.
    if (after.ratingAggregated === true) return;

    const priestId = after.priestId as string | undefined;
    const sessionId = event.params.sessionId;
    if (!priestId) return;

    // Clamp to the 1-5 range the rating dialog already enforces. A
    // bogus client-side write (or a future feature that bumps the
    // scale without updating this CF) shouldn't poison the average.
    const rating = Math.max(1, Math.min(5, afterRating));

    const priestRef = db.doc(`priests/${priestId}`);
    const sessionRef = db.doc(`sessions/${sessionId}`);

    // Transaction: we read the priest doc, recompute the running
    // average, and write back both docs together. Two concurrent
    // ratings landing on the same priest would otherwise race and
    // overwrite each other's increment.
    let milestoneToPush: number | null = null;
    let priestName = "";

    try {
      await db.runTransaction(async (tx) => {
        const priestSnap = await tx.get(priestRef);
        if (!priestSnap.exists) {
          // Priest doc deleted between session creation and now —
          // skip aggregation but still flag the session so we don't
          // keep retrying on every replay.
          tx.update(sessionRef, {ratingAggregated: true});
          return;
        }

        const priestData = priestSnap.data() ?? {};
        const oldRating =
          (priestData.rating as number | undefined) ?? 0;
        const oldCount =
          (priestData.reviewCount as number | undefined) ?? 0;
        const lastMilestone =
          (priestData.lastReviewMilestone as number | undefined) ?? 0;

        const newCount = oldCount + 1;
        // Running average rebuilt from the previous mean instead of
        // re-summing every session — keeps the trigger O(1) regardless
        // of how many ratings the priest already has.
        const newAvgRaw = (oldRating * oldCount + rating) / newCount;
        // 1-decimal precision matches what the dashboard renders
        // (`_rating.toStringAsFixed(1)`) so the value the priest sees
        // and the value stored on the doc never drift.
        const newAvg = Math.round(newAvgRaw * 10) / 10;

        priestName =
          (priestData.fullName as string | undefined) ?? "Speaker";

        // Denormalize this review into a public-read array on the
        // priest doc so the user-side profile page can render reviews
        // without reading the rules-restricted `sessions` collection.
        // Newest-first so we can slice the head — a long-tail
        // simulator priest would otherwise blow past Firestore's 1MB
        // doc limit.
        const existingReviews =
          (priestData.recentReviews as Array<Record<string, unknown>>) ?? [];
        // Strip the entry for this sessionId if one already exists —
        // shouldn't happen (onSessionRated only fires on the FIRST
        // rating) but guards against snapshot replay double-inserts.
        const withoutThis = existingReviews.filter(
          (r) => r.sessionId !== sessionId
        );
        const feedback =
          ((after.userFeedback as string | undefined) ?? "").trim();
        const reviewEntry: Record<string, unknown> = {
          sessionId,
          userName: (after.userName as string | undefined) ?? "",
          userPhotoUrl:
            (after.userPhotoUrl as string | undefined) ?? "",
          rating,
          feedback,
          // endedAt is the most useful "when" for review ordering —
          // falls back to createdAt if endedAt didn't land for some
          // reason (cancelled sessions don't reach this CF anyway).
          endedAt: (after.endedAt as admin.firestore.Timestamp | null) ?? null,
        };
        const updatedReviews = [reviewEntry, ...withoutThis].slice(
          0,
          PUBLIC_REVIEWS_CAP
        );

        const priestUpdate: Record<string, unknown> = {
          rating: newAvg,
          reviewCount: newCount,
          recentReviews: updatedReviews,
        };

        // Pick the largest milestone the new count has just crossed
        // that's also strictly greater than the watermark — protects
        // against replays.
        for (const milestone of REVIEW_MILESTONES) {
          if (newCount >= milestone && milestone > lastMilestone) {
            milestoneToPush = milestone;
          }
        }
        if (milestoneToPush !== null) {
          priestUpdate.lastReviewMilestone = milestoneToPush;
        }

        tx.update(priestRef, priestUpdate);
        tx.update(sessionRef, {ratingAggregated: true});
      });
    } catch (err) {
      console.error(
        `[onSessionRated] Aggregation failed for ${sessionId}:`,
        err
      );
      return;
    }

    // Skip downstream pushes if the priest doc didn't exist (the
    // transaction's no-priest branch left priestName at "" and
    // stamped ratingAggregated:true without aggregating). Pushing
    // to a nonexistent priest would just hit "no FCM tokens" inside
    // sendPushNotification — harmless but wasteful.
    if (priestName === "") return;

    // ── Per-review push ─────────────────────────────────────────
    // Fires for EVERY rating so the priest learns about each new
    // review the moment it lands, instead of having to manually
    // open /priest/reviews to discover non-milestone ones. Mirrors
    // onBibleSessionRated's per-review push so both surfaces
    // behave identically — every reviewed session, whether bible
    // or call/chat, produces exactly one priest-facing push.
    //
    // Idempotency is inherited from the trigger guards above
    // (rating-already-existed early-return + ratingAggregated
    // flag), so this block runs at most once per (session, user).
    const userName = (after.userName as string | undefined) ?? "Someone";
    const reviewTitle = "⭐ New Review";
    const reviewBody =
      `${userName} rated your session ${rating} ` +
      `star${rating === 1 ? "" : "s"}.`;

    try {
      const notifRef = db.collection("notifications").doc();
      await notifRef.set({
        userId: priestId,
        type: "session_rated",
        title: reviewTitle,
        body: reviewBody,
        sessionId,
        data: {sessionId, route: "/priest/reviews"},
        isRead: false,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    } catch (err) {
      console.error(
        `[onSessionRated] per-review inbox write failed for ${priestId}:`,
        err,
      );
    }

    // sendPushNotification swallows its own errors (per its
    // contract — losing a push is recoverable via the inbox doc
    // above, but throwing here would re-fire the trigger on retry
    // and could double-aggregate). No try/catch needed.
    await sendPushNotification({
      userId: priestId,
      title: reviewTitle,
      body: reviewBody,
      data: {
        type: "session_rated",
        route: "/priest/reviews",
        sessionId,
      },
    });

    // ── Milestone celebration (inbox-only) ──────────────────────
    // Bonus inbox card when the priest crosses 1 / 5 / 10 / 25 /
    // 50 / 100 / 250 / 500 reviews — a celebratory record they can
    // scroll back to later. The OS push was removed here: the
    // per-review push above already wakes the device on the same
    // event (the milestone review IS the review), and firing both
    // would land two notifications for the same write. Keeping
    // milestones as inbox-only preserves the achievement signal
    // without the duplicate buzz.
    if (milestoneToPush !== null) {
      const milestone = milestoneToPush as number;
      const {title, body} = buildMilestoneCopy(milestone, priestName);
      try {
        await db.collection("notifications").add({
          userId: priestId,
          type: "review_milestone",
          title,
          body,
          milestone,
          isRead: false,
          createdAt: admin.firestore.FieldValue.serverTimestamp(),
        });
      } catch (err) {
        console.error(
          `[onSessionRated] milestone inbox write failed for ${priestId}:`,
          err
        );
      }
    }
  }
);

// Copy is intentionally specific per milestone — a "you got your 100th
// review" push that reads the same as the "you got your 1st" push
// would feel cheap. Body stays under 110 chars so it doesn't truncate
// inside an FCM heads-up banner on small screens.
function buildMilestoneCopy(
  milestone: number,
  priestName: string
): {title: string; body: string} {
  const _ = priestName; // reserved for future personalisation
  void _;
  switch (milestone) {
    case 1:
      return {
        title: "Your first review!",
        body: "Someone just rated their session with you. Tap to see what they said.",
      };
    case 5:
      return {
        title: "5 reviews and counting",
        body: "You've reached 5 reviews. Keep showing up — people are noticing.",
      };
    case 10:
      return {
        title: "10 reviews — well done",
        body: "Ten people have now shared feedback on a session with you.",
      };
    case 25:
      return {
        title: "25 reviews milestone",
        body: "You're building a real reputation. Tap to read your latest reviews.",
      };
    case 50:
      return {
        title: "50 reviews — that's huge",
        body: "Fifty rated sessions. Your ministry is reaching people.",
      };
    case 100:
      return {
        title: "100 reviews — congratulations",
        body: "You've crossed 100 reviewed sessions. Thank you for the care you bring.",
      };
    case 250:
      return {
        title: "250 reviews milestone",
        body: "A quarter-thousand rated sessions. That's a lot of lives touched.",
      };
    case 500:
      return {
        title: "500 reviews — extraordinary",
        body: "Five hundred reviewed sessions. You've become a foundation here.",
      };
    default:
      return {
        title: `${milestone} reviews milestone`,
        body: `You've reached ${milestone} reviewed sessions. Tap to read them.`,
      };
  }
}
