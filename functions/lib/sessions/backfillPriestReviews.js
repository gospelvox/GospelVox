"use strict";
// One-shot admin-callable that rebuilds `recentReviews` on the priest
// doc from the canonical sessions data.
//
// Why this exists: onSessionRated only fires when a session's
// userRating field TRANSITIONS from unset → set. Historical reviews
// (rated before recentReviews was added to the schema) never trigger
// the new mirror code, so they don't appear on user-side profile
// pages until backfilled. Run this once after deploying the
// recentReviews change.
//
// Invocation:
//   • From the admin app (or any signed-in admin), call
//     `httpsCallable('backfillPriestReviews')` with either:
//       - {priestId: "abc"} to migrate one priest, or
//       - {} to migrate ALL priests
//   • The caller must be an admin (auth.token.admin === true).
//
// Idempotency: this REPLACES the array, doesn't append. Safe to
// re-run; the result converges to the same state.
Object.defineProperty(exports, "__esModule", { value: true });
exports.backfillPriestReviews = void 0;
const https_1 = require("firebase-functions/v2/https");
const admin = require("firebase-admin");
const constants_1 = require("../config/constants");
const db = admin.firestore();
// Same cap onSessionRated enforces — keep them in sync so a backfill
// produces the same shape a live rating would.
const PUBLIC_REVIEWS_CAP = 100;
exports.backfillPriestReviews = (0, https_1.onCall)({ region: constants_1.REGION, timeoutSeconds: 540, memory: "512MiB" }, async (request) => {
    var _a, _b;
    if (!request.auth) {
        throw new https_1.HttpsError("unauthenticated", "Must be logged in");
    }
    // Admin-gate: same `admin` custom claim the rest of the admin
    // surface uses. Avoids exposing a free "rebuild any priest doc"
    // call to non-admin users.
    if (request.auth.token.admin !== true) {
        throw new https_1.HttpsError("permission-denied", "Admin privileges required");
    }
    const onePriestId = (_b = (_a = request.data) === null || _a === void 0 ? void 0 : _a.priestId) !== null && _b !== void 0 ? _b : null;
    // List of priest IDs to process. Either the explicit one passed
    // in, or every priest doc (minus the registration placeholder).
    let priestIds;
    if (onePriestId) {
        priestIds = [onePriestId];
    }
    else {
        const priestsSnap = await db.collection("priests").get();
        priestIds = priestsSnap.docs
            .map((d) => d.id)
            .filter((id) => id !== "_placeholder");
    }
    let priestsUpdated = 0;
    let totalReviewsWritten = 0;
    for (const priestId of priestIds) {
        try {
            // All rated sessions for this priest. limit(500) caps the
            // worst case — well above the array cap so we have enough
            // raw material to pick the best 100 from.
            const sessSnap = await db
                .collection("sessions")
                .where("priestId", "==", priestId)
                .limit(500)
                .get();
            const rated = sessSnap.docs
                .map((d) => ({ id: d.id, data: d.data() }))
                .filter((r) => {
                const v = r.data.userRating;
                return typeof v === "number";
            });
            // Newest-first by endedAt → createdAt fallback so a session
            // missing endedAt for any reason still has a sortable key.
            rated.sort((a, b) => {
                var _a, _b;
                const ta = (_a = a.data.endedAt) !== null && _a !== void 0 ? _a : a.data.createdAt;
                const tb = (_b = b.data.endedAt) !== null && _b !== void 0 ? _b : b.data.createdAt;
                if (!ta && !tb)
                    return 0;
                if (!ta)
                    return 1;
                if (!tb)
                    return -1;
                return tb.toMillis() - ta.toMillis();
            });
            const reviewArr = rated.slice(0, PUBLIC_REVIEWS_CAP).map((r) => {
                var _a, _b, _c, _d, _e, _f;
                const replyMap = r.data.priestReply;
                const replyText = ((_a = replyMap === null || replyMap === void 0 ? void 0 : replyMap.text) !== null && _a !== void 0 ? _a : "").trim();
                const rating = Math.max(1, Math.min(5, r.data.userRating));
                const entry = {
                    sessionId: r.id,
                    userName: (_b = r.data.userName) !== null && _b !== void 0 ? _b : "",
                    userPhotoUrl: (_c = r.data.userPhotoUrl) !== null && _c !== void 0 ? _c : "",
                    rating,
                    feedback: ((_d = r.data.userFeedback) !== null && _d !== void 0 ? _d : "").trim(),
                    endedAt: (_e = r.data.endedAt) !== null && _e !== void 0 ? _e : null,
                };
                if (replyText.length > 0) {
                    entry.priestReply = replyText;
                    // Reply timestamp on the array stays a plain string —
                    // serverTimestamp sentinels are forbidden inside array
                    // elements. The canonical timestamp is still on the
                    // session doc's priestReply.updatedAt.
                    const updatedAt = (_f = replyMap === null || replyMap === void 0 ? void 0 : replyMap.updatedAt) === null || _f === void 0 ? void 0 : _f.toDate();
                    if (updatedAt) {
                        entry.priestReplyAt = updatedAt.toISOString();
                    }
                }
                return entry;
            });
            await db.doc(`priests/${priestId}`).update({
                recentReviews: reviewArr,
            });
            priestsUpdated += 1;
            totalReviewsWritten += reviewArr.length;
        }
        catch (err) {
            console.error(`[backfillPriestReviews] Skipping ${priestId} on error:`, err);
            // Don't fail the whole run because one priest doc is broken.
            // The summary tells the caller how many actually landed.
        }
    }
    return {
        success: true,
        priestsProcessed: priestIds.length,
        priestsUpdated,
        totalReviewsWritten,
    };
});
//# sourceMappingURL=backfillPriestReviews.js.map