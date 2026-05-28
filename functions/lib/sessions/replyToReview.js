"use strict";
// Priest's reply to a single review.
//
// Handles BOTH review sources:
//   • Chat / voice — review lives on sessions/{sessionId}. This is
//     the original path; clients that pass only {sessionId, text}
//     still hit it unchanged.
//   • Bible session — review lives on
//     bible_sessions/{bibleSessionId}/registrations/{regId}. Selected
//     by passing source="bible" with bibleSessionId + regId. The reply
//     shape, 24h edit window, mirror onto priests/{uid}.recentReviews,
//     and user push notification are identical to the session path —
//     priests get a single reply UX regardless of source.
//
// One reply per rated review. Editable for 24 hours after first
// write, then locked — matches the Airbnb host-reply pattern. We
// enforce both windows here (server is the only writer the rules
// will accept) so a tampered client cannot bypass the cap.
//
// Notification: the user who left the review gets a single push
// when the priest's reply lands. Edits within the 24h window do NOT
// re-notify — a noisier loop than the product wants.
Object.defineProperty(exports, "__esModule", { value: true });
exports.replyToReview = void 0;
const https_1 = require("firebase-functions/v2/https");
const admin = require("firebase-admin");
const constants_1 = require("../config/constants");
const sendPush_1 = require("../notifications/sendPush");
const db = admin.firestore();
const REPLY_MAX_CHARS = 300;
const EDIT_WINDOW_HOURS = 24;
exports.replyToReview = (0, https_1.onCall)({ region: constants_1.REGION }, async (request) => {
    var _a, _b, _c, _d, _e, _f, _g, _h, _j;
    if (!request.auth) {
        throw new https_1.HttpsError("unauthenticated", "Must be logged in");
    }
    const priestUid = request.auth.uid;
    const data = (_a = request.data) !== null && _a !== void 0 ? _a : {};
    const rawText = data.text;
    // `source` is the dispatcher. Legacy clients omit it entirely and
    // we treat them as session-source for back-compat — that's the
    // path the chat/voice review page has always taken.
    const source = data.source === "bible" ? "bible" : "session";
    if (typeof rawText !== "string") {
        throw new https_1.HttpsError("invalid-argument", "Missing reply text");
    }
    const text = rawText.trim();
    if (text.length === 0) {
        throw new https_1.HttpsError("invalid-argument", "Reply cannot be empty. Add a few words or skip.");
    }
    if (text.length > REPLY_MAX_CHARS) {
        throw new https_1.HttpsError("invalid-argument", `Reply must be ${REPLY_MAX_CHARS} characters or fewer.`);
    }
    // ── Resolve target doc, owner check, rating check, dedupe key.
    let targetRef;
    let targetSnap;
    let recipientUserId;
    let priestName;
    let priestPhotoUrl;
    // Key the mirror onto priests/{uid}.recentReviews uses to find
    // this review's entry: the flat sessionId for chat/voice, the
    // sentinel "bible_<sid>_<regId>" for bible (matches what the
    // onBibleSessionRated CF writes).
    let mirrorKey;
    // Used in push payload route + notification metadata.
    let pushSessionId;
    let route;
    if (source === "bible") {
        const bibleSessionId = data.bibleSessionId;
        const regId = data.regId;
        if (!bibleSessionId || typeof bibleSessionId !== "string") {
            throw new https_1.HttpsError("invalid-argument", "Missing bibleSessionId");
        }
        if (!regId || typeof regId !== "string") {
            throw new https_1.HttpsError("invalid-argument", "Missing regId");
        }
        // Owner check: the parent bible session has to belong to this
        // priest. We could read the registration first and then load
        // the parent, but a single parent-doc read up front rejects
        // unauthorised callers faster.
        const parentRef = db.doc(`bible_sessions/${bibleSessionId}`);
        const parentSnap = await parentRef.get();
        if (!parentSnap.exists) {
            throw new https_1.HttpsError("not-found", "Bible session not found");
        }
        const parentData = (_b = parentSnap.data()) !== null && _b !== void 0 ? _b : {};
        if (parentData.priestId !== priestUid) {
            throw new https_1.HttpsError("permission-denied", "You can only reply to reviews on your own bible sessions");
        }
        targetRef = db.doc(`bible_sessions/${bibleSessionId}/registrations/${regId}`);
        targetSnap = await targetRef.get();
        if (!targetSnap.exists) {
            throw new https_1.HttpsError("not-found", "Registration not found");
        }
        const regData = (_c = targetSnap.data()) !== null && _c !== void 0 ? _c : {};
        const rating = regData.rating;
        if (rating === undefined || rating === null) {
            throw new https_1.HttpsError("failed-precondition", "You can only reply once the user has rated this session");
        }
        // regId IS the user uid per the bible_sessions/registrations
        // rule. We still defensively coalesce in case future schemas
        // ever divorce them.
        recipientUserId = regId;
        priestName =
            (_d = parentData.priestName) !== null && _d !== void 0 ? _d : "Your speaker";
        priestPhotoUrl =
            (_e = parentData.priestPhotoUrl) !== null && _e !== void 0 ? _e : "";
        mirrorKey = `bible_${bibleSessionId}_${regId}`;
        pushSessionId = bibleSessionId;
        route = `/user/priest/${priestUid}`;
    }
    else {
        const sessionId = data.sessionId;
        if (!sessionId || typeof sessionId !== "string") {
            throw new https_1.HttpsError("invalid-argument", "Missing sessionId");
        }
        targetRef = db.doc(`sessions/${sessionId}`);
        targetSnap = await targetRef.get();
        if (!targetSnap.exists) {
            throw new https_1.HttpsError("not-found", "Session not found");
        }
        const session = (_f = targetSnap.data()) !== null && _f !== void 0 ? _f : {};
        if (session.priestId !== priestUid) {
            throw new https_1.HttpsError("permission-denied", "You can only reply to your own sessions");
        }
        const rating = session.userRating;
        if (rating === undefined || rating === null) {
            throw new https_1.HttpsError("failed-precondition", "You can only reply once the user has rated this session");
        }
        recipientUserId = session.userId;
        priestName =
            (_g = session.priestName) !== null && _g !== void 0 ? _g : "Your speaker";
        priestPhotoUrl =
            (_h = session.priestPhotoUrl) !== null && _h !== void 0 ? _h : "";
        mirrorKey = sessionId;
        pushSessionId = sessionId;
        route = `/user/priest/${priestUid}`;
    }
    // ── Shared write path (24h edit window + write + mirror + push).
    const existingReply = (_j = targetSnap.data()) === null || _j === void 0 ? void 0 : _j.priestReply;
    const isEdit = existingReply !== undefined && existingReply !== null;
    if (isEdit) {
        const createdAt = existingReply === null || existingReply === void 0 ? void 0 : existingReply.createdAt;
        const createdAtDate = createdAt === null || createdAt === void 0 ? void 0 : createdAt.toDate();
        if (!createdAtDate) {
            throw new https_1.HttpsError("failed-precondition", "This reply can no longer be edited.");
        }
        const hoursSinceCreated = (Date.now() - createdAtDate.getTime()) / (1000 * 60 * 60);
        if (hoursSinceCreated > EDIT_WINDOW_HOURS) {
            throw new https_1.HttpsError("failed-precondition", `Replies can only be edited within ${EDIT_WINDOW_HOURS} hours of posting.`);
        }
    }
    const now = admin.firestore.FieldValue.serverTimestamp();
    // createdAt stays stable across edits so the 24h window measures
    // from FIRST publish, not last edit.
    const reply = {
        text,
        updatedAt: now,
        authorId: priestUid,
    };
    if (!isEdit) {
        reply.createdAt = now;
    }
    await targetRef.update({ priestReply: reply });
    // Mirror the reply onto the denormalised review entry on the
    // priest doc so the user-side profile page sees the reply (the
    // public copy is the only one rules let other users read). Best-
    // effort: if the priest doc has no matching entry yet (older
    // review pre-deploy, or recentReviews trimmed past the cap), we
    // skip — the source-of-truth doc still has the reply.
    try {
        const priestRef = db.doc(`priests/${priestUid}`);
        await db.runTransaction(async (tx) => {
            var _a, _b;
            const snap = await tx.get(priestRef);
            if (!snap.exists)
                return;
            const pdata = (_a = snap.data()) !== null && _a !== void 0 ? _a : {};
            const reviews = (_b = pdata.recentReviews) !== null && _b !== void 0 ? _b : [];
            if (reviews.length === 0)
                return;
            let touched = false;
            const updated = reviews.map((r) => {
                var _a;
                if (r.sessionId === mirrorKey) {
                    touched = true;
                    const existingCreatedAt = (_a = r.priestReplyCreatedAt) !== null && _a !== void 0 ? _a : new Date().toISOString();
                    return Object.assign(Object.assign({}, r), { priestReply: text, 
                        // ISO strings — Firestore forbids server sentinels
                        // inside an array element. priestReplyCreatedAt stays
                        // stable across edits so a client reading the mirror
                        // (e.g. the bible review case where the source doc is
                        // not directly read) can still compute the 24h edit
                        // window correctly. priestReplyAt updates on every
                        // write so a "edited" badge has something to compare.
                        priestReplyAt: new Date().toISOString(), priestReplyCreatedAt: existingCreatedAt });
                }
                return r;
            });
            if (touched) {
                tx.update(priestRef, { recentReviews: updated });
            }
        });
    }
    catch (err) {
        console.error(`[replyToReview] Mirror to priest doc failed for ${mirrorKey}:`, err);
    }
    // Inbox + push only on the FIRST publish. Edits shouldn't re-ping
    // the user.
    if (!isEdit && recipientUserId) {
        const notifTitle = `${priestName} replied to your review`;
        const preview = text.length > 100 ? `${text.substring(0, 97)}…` : text;
        try {
            await db.collection("notifications").add({
                userId: recipientUserId,
                type: "priest_reply",
                title: notifTitle,
                body: preview,
                sessionId: pushSessionId,
                priestId: priestUid,
                priestName,
                priestPhotoUrl,
                isRead: false,
                createdAt: now,
            });
        }
        catch (err) {
            console.error(`[replyToReview] Inbox write failed for ${recipientUserId}:`, err);
        }
        try {
            await (0, sendPush_1.sendPushNotification)({
                userId: recipientUserId,
                title: notifTitle,
                body: preview,
                data: {
                    type: "priest_reply",
                    route,
                    sessionId: pushSessionId,
                    priestId: priestUid,
                },
            });
        }
        catch (_k) {
            // sendPushNotification already logs internally.
        }
    }
    return { success: true, isEdit };
});
//# sourceMappingURL=replyToReview.js.map