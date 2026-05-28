"use strict";
// Callable that returns a priest's public reviews to any signed-in
// user.
//
// Why it exists: reviews are stored on session docs (sessions/{id}
// with userRating + userFeedback), and the Firestore rules restrict
// `sessions` reads to participants. So a different user opening a
// priest's profile cannot query the sessions collection — the read
// is rejected, and the Reviews section comes back empty.
//
// This function runs as the Firebase Admin (bypassing rules), reads
// the priest's rated sessions server-side, and returns a sanitised
// projection that contains only the public review fields. That makes
// it safe to expose to any caller: they see the same data they would
// see scrolling the priest's public profile anyway, but they can't
// pull any private session metadata via this endpoint.
//
// Auth: requires `request.auth` so anonymous traffic can't scrape
// reviews in bulk. Any signed-in app user can call it.
Object.defineProperty(exports, "__esModule", { value: true });
exports.getPublicPriestReviews = void 0;
const https_1 = require("firebase-functions/v2/https");
const admin = require("firebase-admin");
const constants_1 = require("../config/constants");
const db = admin.firestore();
// Hard cap so a single call can't ask for the entire history of a
// busy priest. 200 is well above any realistic profile preview.
const MAX_LIMIT = 200;
const DEFAULT_LIMIT = 50;
// How many session docs we scan before slicing — needs to be bigger
// than the limit because not every session has a userRating.
const SESSION_SCAN_LIMIT = 300;
exports.getPublicPriestReviews = (0, https_1.onCall)({ region: constants_1.REGION }, async (request) => {
    var _a, _b, _c, _d;
    if (!request.auth) {
        throw new https_1.HttpsError("unauthenticated", "Must be logged in");
    }
    const priestId = (_a = request.data) === null || _a === void 0 ? void 0 : _a.priestId;
    if (!priestId || typeof priestId !== "string") {
        throw new https_1.HttpsError("invalid-argument", "Missing priestId");
    }
    const rawLimit = (_b = request.data) === null || _b === void 0 ? void 0 : _b.limit;
    const limit = Math.min(MAX_LIMIT, Math.max(1, typeof rawLimit === "number" ? rawLimit : DEFAULT_LIMIT));
    // Two parallel reads:
    //   1. chat/voice ratings from the flat `sessions` collection.
    //   2. bible-session ratings denormalised onto the priest doc's
    //      `recentReviews` array by the onBibleSessionRated trigger.
    // We merge both and apply the same sort + limit so a busy priest
    // who runs lots of bible sessions doesn't lose chat reviews from
    // the visible window (and vice versa).
    const [sessionsSnap, priestSnap] = await Promise.all([
        db
            .collection("sessions")
            .where("priestId", "==", priestId)
            .limit(SESSION_SCAN_LIMIT)
            .get(),
        db.doc(`priests/${priestId}`).get(),
    ]);
    const sessionRows = sessionsSnap.docs
        .map((d) => ({ id: d.id, data: d.data() }))
        .filter((r) => typeof r.data.userRating === "number");
    // Bible review rows come from priests/{id}.recentReviews entries
    // where source == "bible". Each entry already carries userName,
    // userPhotoUrl, rating, feedback, endedAt — close enough to a
    // session doc that we adapt the field names below and reuse the
    // shared sort + projection path.
    const bibleEntries = (priestSnap.exists
        ? (_d = (_c = priestSnap.data()) === null || _c === void 0 ? void 0 : _c.recentReviews) !== null && _d !== void 0 ? _d : []
        : []).filter((e) => (e === null || e === void 0 ? void 0 : e.source) === "bible");
    const bibleRows = bibleEntries.map((e) => {
        var _a, _b, _c;
        // The bible mirror stores priestReply as a flat string (the
        // replyToReview CF writes `priestReply: text` onto the
        // recentReviews entry). Wrap it back into the {text} shape that
        // the projection reads, so bible and chat/voice rows take the
        // exact same code path below.
        const replyText = ((_a = e.priestReply) !== null && _a !== void 0 ? _a : "").trim();
        return {
            id: String((_b = e.sessionId) !== null && _b !== void 0 ? _b : `bible_${(_c = e.bibleSessionId) !== null && _c !== void 0 ? _c : "unknown"}`),
            data: {
                userRating: e.rating,
                userFeedback: e.feedback,
                userName: e.userName,
                userPhotoUrl: e.userPhotoUrl,
                endedAt: e.endedAt,
                priestReply: replyText.length > 0 ? { text: replyText } : undefined,
            },
        };
    });
    const allRows = [...sessionRows, ...bibleRows];
    // Sort: written feedback first (most informative as a preview),
    // then newest-first within each group.
    const endedAtMs = (data) => {
        const ended = data.endedAt;
        if (ended && typeof ended.toMillis === "function") {
            return ended.toMillis();
        }
        const created = data.createdAt;
        if (created && typeof created.toMillis === "function") {
            return created.toMillis();
        }
        return 0;
    };
    const hasText = (data) => {
        var _a;
        const t = (_a = data.userFeedback) !== null && _a !== void 0 ? _a : "";
        return t.trim().length > 0;
    };
    allRows.sort((a, b) => {
        const wa = hasText(a.data) ? 0 : 1;
        const wb = hasText(b.data) ? 0 : 1;
        if (wa !== wb)
            return wa - wb;
        return endedAtMs(b.data) - endedAtMs(a.data);
    });
    const reviews = allRows.slice(0, limit).map((r) => {
        var _a, _b, _c, _d;
        const replyMap = r.data.priestReply;
        const replyText = ((_a = replyMap === null || replyMap === void 0 ? void 0 : replyMap.text) !== null && _a !== void 0 ? _a : "").trim();
        const rating = Math.max(1, Math.min(5, r.data.userRating));
        const ended = r.data.endedAt;
        const endedIso = ended && typeof ended.toDate === "function"
            ? ended.toDate().toISOString()
            : null;
        return {
            sessionId: r.id,
            userName: (_b = r.data.userName) !== null && _b !== void 0 ? _b : "",
            userPhotoUrl: (_c = r.data.userPhotoUrl) !== null && _c !== void 0 ? _c : "",
            rating,
            feedback: ((_d = r.data.userFeedback) !== null && _d !== void 0 ? _d : "").trim(),
            // ISO string is universal across clients; Flutter parses it
            // with DateTime.tryParse on the read path.
            endedAt: endedIso,
            priestReply: replyText.length > 0 ? replyText : null,
        };
    });
    return { reviews, total: allRows.length };
});
//# sourceMappingURL=getPublicPriestReviews.js.map