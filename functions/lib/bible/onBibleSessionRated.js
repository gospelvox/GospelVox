"use strict";
// Firestore trigger that aggregates a user's bible-session rating into
// the priest's running average + review count, and denormalises the
// review into the priest doc's `recentReviews` array so it shows on
// the user-side priest profile and the priest's own review surfaces
// alongside chat/voice reviews.
//
// Mirrors the call/chat `onSessionRated.ts` trigger but reads from
// `bible_sessions/{sid}/registrations/{regId}` instead of the flat
// sessions collection. The same `ratingAggregated` flag is written
// back onto the registration doc to make replays idempotent — a
// snapshot redelivery of the same write must not double-count.
//
// Why a CF: the priest doc is not writable from a USER's client (rules
// would deny `priests/{id}` writes from anyone but the priest themself,
// and we don't want the priest writing their own average anyway). The
// Admin SDK is the only path that can safely recompute and persist
// the running average + reviewCount.
//
// Why we also push to `priests/{id}.recentReviews`: the user-side
// priest profile page already renders that array as the review feed.
// Without this denormalisation, the profile would only ever show
// chat/voice reviews and bible reviews would be invisible there even
// though they aggregate into the rating.
Object.defineProperty(exports, "__esModule", { value: true });
exports.onBibleSessionRated = void 0;
const firestore_1 = require("firebase-functions/v2/firestore");
const admin = require("firebase-admin");
const constants_1 = require("../config/constants");
const sendPush_1 = require("../notifications/sendPush");
const db = admin.firestore();
// Soft cap on the denormalized review array. The same cap used in
// onSessionRated.ts so the two paths agree on how much history the
// priest doc carries — keeps the doc well under Firestore's 1MB limit
// even with long feedback text from both bible and chat/voice
// sessions combined.
const PUBLIC_REVIEWS_CAP = 100;
exports.onBibleSessionRated = (0, firestore_1.onDocumentWritten)({
    document: "bible_sessions/{sessionId}/registrations/{regId}",
    region: constants_1.REGION,
}, async (event) => {
    var _a, _b, _c, _d, _e, _f, _g, _h;
    const before = (_a = event.data) === null || _a === void 0 ? void 0 : _a.before;
    const after = (_b = event.data) === null || _b === void 0 ? void 0 : _b.after;
    if (!(after === null || after === void 0 ? void 0 : after.exists))
        return;
    const beforeData = (before === null || before === void 0 ? void 0 : before.exists) ? (_c = before.data()) !== null && _c !== void 0 ? _c : {} : {};
    const afterData = (_d = after.data()) !== null && _d !== void 0 ? _d : {};
    // Only react to the FIRST time `rating` becomes a number. Every
    // other write on this doc (status flip, pay, cancel, photo update)
    // also lands on this trigger and must early-return.
    const beforeRating = beforeData.rating;
    const afterRating = afterData.rating;
    if (afterRating === undefined ||
        afterRating === null ||
        typeof afterRating !== "number") {
        return;
    }
    if (beforeRating !== undefined &&
        beforeRating !== null &&
        typeof beforeRating === "number") {
        return;
    }
    // Already aggregated — a replay or a follow-up write after the
    // flag was set. Bail out.
    if (afterData.ratingAggregated === true)
        return;
    const sessionId = event.params.sessionId;
    const regId = event.params.regId;
    // Clamp to 1-5 just in case a client wrote outside the range.
    const rating = Math.max(1, Math.min(5, afterRating));
    // We need the parent session doc to resolve priestId + completedAt.
    // Done OUTSIDE the transaction (read-only metadata that doesn't
    // need to be locked against concurrent writes).
    const sessionRef = db.doc(`bible_sessions/${sessionId}`);
    let priestId;
    let sessionTitle = "Bible Session";
    let completedAt = null;
    try {
        const sessionSnap = await sessionRef.get();
        if (!sessionSnap.exists)
            return;
        const sessionData = (_e = sessionSnap.data()) !== null && _e !== void 0 ? _e : {};
        priestId = sessionData.priestId;
        sessionTitle = String((_f = sessionData.title) !== null && _f !== void 0 ? _f : "Bible Session");
        completedAt =
            (_g = sessionData.completedAt) !== null && _g !== void 0 ? _g : null;
    }
    catch (err) {
        console.error("[onBibleSessionRated] parent session read failed " +
            `for ${sessionId}:`, err);
        return;
    }
    if (!priestId)
        return;
    const priestRef = db.doc(`priests/${priestId}`);
    const regRef = db.doc(`bible_sessions/${sessionId}/registrations/${regId}`);
    try {
        await db.runTransaction(async (tx) => {
            var _a, _b, _c, _d, _e, _f, _g, _h;
            const priestSnap = await tx.get(priestRef);
            if (!priestSnap.exists) {
                // Priest doc deleted between session creation and now — flag
                // the registration so we don't keep retrying on every replay.
                tx.update(regRef, { ratingAggregated: true });
                return;
            }
            const priestData = (_a = priestSnap.data()) !== null && _a !== void 0 ? _a : {};
            const oldAvg = (_b = priestData.rating) !== null && _b !== void 0 ? _b : 0;
            const oldCount = (_c = priestData.reviewCount) !== null && _c !== void 0 ? _c : 0;
            const newCount = oldCount + 1;
            const newAvgRaw = (oldAvg * oldCount + rating) / newCount;
            // 1-decimal precision matches what the dashboard renders so
            // the stored value and the displayed value never drift.
            const newAvg = Math.round(newAvgRaw * 10) / 10;
            // Denormalise this review onto the priest doc so the user-
            // facing profile page can render bible reviews alongside
            // chat/voice ones without any additional read path. We mark
            // each entry with `source: "bible"` so the CF / clients can
            // tell the two origins apart if needed.
            const existingReviews = (_d = priestData.recentReviews) !== null && _d !== void 0 ? _d : [];
            // Strip any prior entry for the same (sessionId, regId) pair
            // — onBibleSessionRated only fires on first rating, but a
            // snapshot replay shouldn't be able to double-insert.
            const dedupeKey = `bible_${sessionId}_${regId}`;
            const withoutThis = existingReviews.filter((r) => r.sessionId !== dedupeKey);
            const feedback = ((_e = afterData.feedback) !== null && _e !== void 0 ? _e : "").trim();
            const reviewEntry = {
                // Use the sentinel `bible_<sid>_<uid>` so the entry can't
                // collide with a chat/voice session id (those are flat doc
                // ids in the `sessions` collection without underscores in
                // the typical Firestore auto-id shape, but the prefix is
                // the load-bearing distinguisher either way).
                sessionId: dedupeKey,
                bibleSessionId: sessionId,
                source: "bible",
                userName: (_f = afterData.userName) !== null && _f !== void 0 ? _f : "",
                userPhotoUrl: (_g = afterData.userPhotoUrl) !== null && _g !== void 0 ? _g : "",
                rating,
                feedback,
                // Prefer the session's completedAt so the review timeline
                // reflects when the session actually ended. Falls back to
                // `ratedAt` (when the user pressed submit) if the parent
                // doc didn't carry completedAt — should be rare but the
                // fallback keeps the sort key non-null.
                endedAt: (_h = completedAt !== null && completedAt !== void 0 ? completedAt : afterData.ratedAt) !== null && _h !== void 0 ? _h : null,
            };
            const updatedReviews = [reviewEntry, ...withoutThis].slice(0, PUBLIC_REVIEWS_CAP);
            tx.update(priestRef, {
                rating: newAvg,
                reviewCount: newCount,
                recentReviews: updatedReviews,
            });
            tx.update(regRef, { ratingAggregated: true });
        });
    }
    catch (err) {
        console.error("[onBibleSessionRated] aggregation failed for " +
            `${sessionId}/${regId}:`, err);
        return;
    }
    // Priest-facing review nudge. Two halves, each best-effort:
    //
    //   1. /notifications inbox doc — source of truth, survives a
    //      missed push. Rules deny `notifications.create` from clients
    //      so the Admin SDK is the only path here.
    //   2. OS push via sendPushNotification — wakes the priest's
    //      device. Previously omitted, which is why the priest had to
    //      manually open the reviews surface to discover that a user
    //      had rated their session.
    //
    // Per-review push (not milestone-gated). The chat/voice
    // onSessionRated trigger now follows the same contract — every
    // rating fires a push to the priest. Milestones are kept on the
    // chat/voice side as an inbox-only bonus card so a milestone
    // review doesn't land two pushes for the same event; bible
    // doesn't have a milestone concept at all because attendee
    // volume per session is bounded.
    const userName = (_h = afterData.userName) !== null && _h !== void 0 ? _h : "Someone";
    const reviewTitle = "⭐ New Review";
    const reviewBody = `${userName} rated "${sessionTitle}" ${rating} ` +
        `star${rating === 1 ? "" : "s"}.`;
    try {
        const notifRef = db.collection("notifications").doc();
        await notifRef.set({
            userId: priestId,
            type: "bible_session_reviewed",
            title: reviewTitle,
            body: reviewBody,
            sessionId,
            data: { sessionId, route: `/priest/bible/${sessionId}` },
            isRead: false,
            createdAt: admin.firestore.FieldValue.serverTimestamp(),
        });
    }
    catch (err) {
        console.error("[onBibleSessionRated] priest inbox write failed " +
            `for ${sessionId}/${regId}:`, err);
    }
    // sendPushNotification swallows its own errors (per its contract
    // — losing a push is recoverable via the inbox doc above, but
    // throwing here would re-fire the whole trigger on retry and
    // could double-aggregate). No try/catch needed.
    await (0, sendPush_1.sendPushNotification)({
        userId: priestId,
        title: reviewTitle,
        body: reviewBody,
        data: {
            type: "bible_session_reviewed",
            sessionId,
            route: `/priest/bible/${sessionId}`,
        },
    });
});
//# sourceMappingURL=onBibleSessionRated.js.map