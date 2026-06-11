"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.createBibleSession = void 0;
const https_1 = require("firebase-functions/v2/https");
const admin = require("firebase-admin");
const constants_1 = require("../config/constants");
const db = admin.firestore();
// Single source of truth for create-time validation. Replaces the
// previous direct-from-client Firestore write so we can enforce:
//
//   1. Server-validated input shape (title length, description
//      length, duration whitelist, fixed ₹199 price). Same checks
//      the client form already enforces — the CF is the
//      authoritative copy in case a tampered client tries to slip
//      past them.
//
//   Pricing: every Bible session is fixed at ₹199 to match the
//   single bible_session_199 Play SKU. Anything else from the
//   client is rejected with a clear error rather than silently
//   coerced — drift on either side surfaces immediately.
//
//   2. Overlap detection against the priest's existing UPCOMING +
//      LIVE sessions. The priest UI prevents most accidental
//      double-booking by hiding the create CTA, but two near-
//      simultaneous taps from different devices, or a session
//      created on day 1 that wasn't started by day 2 when the
//      priest tries to schedule another, both need a server-side
//      block. Overlap math is `newStart < existEnd && newEnd >
//      existStart` (the canonical half-open-interval intersection),
//      where each end = start + durationMinutes.
//
//   3. Approved + activated priest check. Firestore rules already
//      enforce this on the direct write, but the CF call goes
//      through the Admin SDK (rules bypass), so we re-check here
//      to keep the same guarantee.
//
// Returns {sessionId} so the client can navigate / link to the
// freshly-created session without a second read.
exports.createBibleSession = (0, https_1.onCall)({ region: constants_1.REGION }, async (request) => {
    var _a, _b, _c, _d, _e, _f, _g, _h, _j, _k, _l, _m, _o, _p, _q;
    if (!request.auth) {
        throw new https_1.HttpsError("unauthenticated", "Must be logged in");
    }
    const priestUid = request.auth.uid;
    const data = request.data;
    // ── 1. Input validation ─────────────────────────────────────
    const title = ((_a = data.title) !== null && _a !== void 0 ? _a : "").trim();
    const description = ((_b = data.description) !== null && _b !== void 0 ? _b : "").trim();
    const category = ((_c = data.category) !== null && _c !== void 0 ? _c : "").trim();
    const scheduledAtRaw = (_d = data.scheduledAt) !== null && _d !== void 0 ? _d : "";
    const durationMinutes = Number((_e = data.durationMinutes) !== null && _e !== void 0 ? _e : 0);
    const price = Number((_f = data.price) !== null && _f !== void 0 ? _f : 0);
    const maxParticipants = Number((_g = data.maxParticipants) !== null && _g !== void 0 ? _g : 0);
    const meetingLink = ((_h = data.meetingLink) !== null && _h !== void 0 ? _h : "").trim();
    if (title.length < 5 || title.length > 100) {
        throw new https_1.HttpsError("invalid-argument", "Title must be 5–100 characters");
    }
    if (description.length < 20 || description.length > 300) {
        throw new https_1.HttpsError("invalid-argument", "Description must be 20–300 characters");
    }
    if (category === "") {
        throw new https_1.HttpsError("invalid-argument", "Category is required");
    }
    if (![30, 45, 60, 90, 120].includes(durationMinutes)) {
        throw new https_1.HttpsError("invalid-argument", "Duration must be 30, 45, 60, 90, or 120 minutes");
    }
    // Fixed price — matches the single bible_session_199 Play SKU.
    // A drifted client (older build, tampered payload) will surface
    // here with a clear error rather than silently creating a
    // mispriced session.
    if (price !== 199) {
        throw new https_1.HttpsError("invalid-argument", "Bible session price must be ₹199");
    }
    if (!Number.isInteger(maxParticipants) || maxParticipants < 0) {
        throw new https_1.HttpsError("invalid-argument", "Max participants must be 0 (unlimited) or a positive integer");
    }
    if (meetingLink !== "" && !meetingLink.startsWith("https://")) {
        throw new https_1.HttpsError("invalid-argument", "Meeting link must start with https://");
    }
    // Client sends an ISO-8601 string (toUtc().toIso8601String()).
    // Parse explicitly so a malformed payload throws here instead
    // of being treated as an "invalid date" Timestamp later.
    const startTime = new Date(scheduledAtRaw);
    if (Number.isNaN(startTime.getTime())) {
        throw new https_1.HttpsError("invalid-argument", "Invalid scheduled date");
    }
    if (startTime.getTime() < Date.now()) {
        throw new https_1.HttpsError("invalid-argument", "Scheduled time must be in the future");
    }
    const endTime = new Date(startTime.getTime() + durationMinutes * 60 * 1000);
    // ── 2. Priest must be approved + activated ──────────────────
    const priestDoc = await db.doc(`priests/${priestUid}`).get();
    if (!priestDoc.exists) {
        throw new https_1.HttpsError("not-found", "Priest profile not found");
    }
    const priestData = (_j = priestDoc.data()) !== null && _j !== void 0 ? _j : {};
    if (priestData.status !== "approved") {
        throw new https_1.HttpsError("permission-denied", "Your priest profile is not approved yet");
    }
    if (priestData.isActivated !== true) {
        throw new https_1.HttpsError("permission-denied", "Your account is not activated");
    }
    // ── 3. Overlap detection ────────────────────────────────────
    // Single-field equality on priestId + status `in` clause keeps
    // us inside the auto-index. Filtering by 'upcoming' OR 'live'
    // — but NOT 'cancelled' or 'completed' — because a terminal
    // session no longer occupies a slot. The where-in clause caps
    // at 30 values per Firestore limits; we have 2.
    const existingSnap = await db
        .collection("bible_sessions")
        .where("priestId", "==", priestUid)
        .where("status", "in", ["upcoming", "live"])
        .get();
    for (const doc of existingSnap.docs) {
        const existing = doc.data();
        const existStartTs = existing.scheduledAt;
        const existStart = existStartTs === null || existStartTs === void 0 ? void 0 : existStartTs.toDate();
        if (!existStart)
            continue;
        const existDuration = Number((_k = existing.durationMinutes) !== null && _k !== void 0 ? _k : 60);
        const existEnd = new Date(existStart.getTime() + existDuration * 60 * 1000);
        // Half-open interval intersection — two windows [aStart,aEnd)
        // and [bStart,bEnd) overlap iff aStart < bEnd && bStart < aEnd.
        if (startTime < existEnd && endTime > existStart) {
            const existTitle = String((_l = existing.title) !== null && _l !== void 0 ? _l : "another session");
            const existWhen = existStart.toLocaleString("en-IN", {
                timeZone: "Asia/Kolkata",
                dateStyle: "medium",
                timeStyle: "short",
            });
            throw new https_1.HttpsError("already-exists", `This time overlaps with "${existTitle}" at ${existWhen}. ` +
                "Please choose a different time.");
        }
    }
    // ── 4. Create ───────────────────────────────────────────────
    // Fields with defaults from the priest doc when the client
    // didn't supply them. The CF is the authoritative writer, so
    // anything the client sends for priestName/priestPhotoUrl is
    // accepted but falls back to the priests/{uid} doc on miss.
    const sessionRef = db.collection("bible_sessions").doc();
    await sessionRef.set({
        priestId: priestUid,
        priestName: ((_m = data.priestName) !== null && _m !== void 0 ? _m : "").trim() !== ""
            ? data.priestName
            : String((_o = priestData.fullName) !== null && _o !== void 0 ? _o : ""),
        priestPhotoUrl: ((_p = data.priestPhotoUrl) !== null && _p !== void 0 ? _p : "") !== ""
            ? data.priestPhotoUrl
            : String((_q = priestData.photoUrl) !== null && _q !== void 0 ? _q : ""),
        title,
        description,
        category,
        scheduledAt: admin.firestore.Timestamp.fromDate(startTime),
        durationMinutes,
        price,
        maxParticipants,
        meetingLink,
        status: "upcoming",
        registrationCount: 0,
        remindersSent: {},
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    return { sessionId: sessionRef.id };
});
//# sourceMappingURL=createBibleSession.js.map