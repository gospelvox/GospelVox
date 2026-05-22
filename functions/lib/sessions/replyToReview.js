"use strict";
// Priest's reply to a single session review.
//
// One reply per rated session. Editable for 24 hours after first
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
    var _a, _b, _c;
    if (!request.auth) {
        throw new https_1.HttpsError("unauthenticated", "Must be logged in");
    }
    const priestUid = request.auth.uid;
    const data = (_a = request.data) !== null && _a !== void 0 ? _a : {};
    const sessionId = data.sessionId;
    const rawText = data.text;
    if (!sessionId || typeof sessionId !== "string") {
        throw new https_1.HttpsError("invalid-argument", "Missing sessionId");
    }
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
    const sessionRef = db.doc(`sessions/${sessionId}`);
    const sessionSnap = await sessionRef.get();
    if (!sessionSnap.exists) {
        throw new https_1.HttpsError("not-found", "Session not found");
    }
    const session = sessionSnap.data();
    if (session.priestId !== priestUid) {
        throw new https_1.HttpsError("permission-denied", "You can only reply to your own sessions");
    }
    // No rating = nothing to reply to. The reviews page only shows
    // rated sessions; this is a defensive backstop for a client that
    // somehow calls in with an unrated sessionId.
    const rating = session.userRating;
    if (rating === undefined || rating === null) {
        throw new https_1.HttpsError("failed-precondition", "You can only reply once the user has rated this session");
    }
    const existingReply = session.priestReply;
    const isEdit = existingReply !== undefined && existingReply !== null;
    if (isEdit) {
        const createdAt = existingReply === null || existingReply === void 0 ? void 0 : existingReply.createdAt;
        const createdAtDate = createdAt === null || createdAt === void 0 ? void 0 : createdAt.toDate();
        if (!createdAtDate) {
            // Shouldn't happen — if there's an existing reply, createdAt
            // was set in the same write. Treat absence as already-locked.
            throw new https_1.HttpsError("failed-precondition", "This reply can no longer be edited.");
        }
        const hoursSinceCreated = (Date.now() - createdAtDate.getTime()) / (1000 * 60 * 60);
        if (hoursSinceCreated > EDIT_WINDOW_HOURS) {
            throw new https_1.HttpsError("failed-precondition", `Replies can only be edited within ${EDIT_WINDOW_HOURS} hours of posting.`);
        }
    }
    const now = admin.firestore.FieldValue.serverTimestamp();
    // We deliberately keep the createdAt stamp stable across edits so
    // the 24h window measures from FIRST publish, not last edit. An
    // edit only refreshes `updatedAt`.
    const reply = {
        text,
        updatedAt: now,
        authorId: priestUid,
    };
    if (!isEdit) {
        reply.createdAt = now;
    }
    await sessionRef.update({ priestReply: reply });
    // Mirror the reply onto the denormalized review entry on the
    // priest doc so the user-side profile page sees the reply (the
    // public copy is the only one rules let other users read).
    // Best-effort: if the priest doc has no array yet (older review
    // pre-deploy), we just skip — the source-of-truth session doc
    // still has the reply.
    try {
        const priestRef = db.doc(`priests/${priestUid}`);
        await db.runTransaction(async (tx) => {
            var _a, _b;
            const snap = await tx.get(priestRef);
            if (!snap.exists)
                return;
            const data = (_a = snap.data()) !== null && _a !== void 0 ? _a : {};
            const reviews = (_b = data.recentReviews) !== null && _b !== void 0 ? _b : [];
            if (reviews.length === 0)
                return;
            let touched = false;
            const updated = reviews.map((r) => {
                if (r.sessionId === sessionId) {
                    touched = true;
                    return Object.assign(Object.assign({}, r), { priestReply: text, 
                        // ISO string instead of serverTimestamp() — Firestore
                        // forbids server sentinels inside an array element. The
                        // exact priestReplyAt is rarely used by the UI; the
                        // canonical timestamp lives on the session doc.
                        priestReplyAt: new Date().toISOString() });
                }
                return r;
            });
            if (touched) {
                tx.update(priestRef, { recentReviews: updated });
            }
        });
    }
    catch (err) {
        console.error(`[replyToReview] Mirror to priest doc failed for ${sessionId}:`, err);
    }
    // Inbox + push only on the FIRST publish. Edits shouldn't re-ping
    // the user — that's the standard professional-app behaviour and
    // matches what the product confirmed.
    if (!isEdit) {
        const userId = session.userId;
        const priestName = (_b = session.priestName) !== null && _b !== void 0 ? _b : "Your speaker";
        const priestPhotoUrl = (_c = session.priestPhotoUrl) !== null && _c !== void 0 ? _c : "";
        const notifTitle = `${priestName} replied to your review`;
        // Preview keeps under ~100 chars so the FCM heads-up banner
        // renders cleanly across OEM-themed Android lock screens.
        const preview = text.length > 100 ? `${text.substring(0, 97)}…` : text;
        try {
            await db.collection("notifications").add({
                userId,
                type: "priest_reply",
                title: notifTitle,
                body: preview,
                sessionId,
                priestId: priestUid,
                priestName,
                priestPhotoUrl,
                isRead: false,
                createdAt: now,
            });
        }
        catch (err) {
            console.error(`[replyToReview] Inbox write failed for ${userId}:`, err);
        }
        try {
            await (0, sendPush_1.sendPushNotification)({
                userId,
                title: notifTitle,
                body: preview,
                data: {
                    type: "priest_reply",
                    route: `/user/priest/${priestUid}`,
                    sessionId,
                    priestId: priestUid,
                },
            });
        }
        catch (_d) {
            // sendPushNotification already logs internally.
        }
    }
    return { success: true, isEdit };
});
//# sourceMappingURL=replyToReview.js.map