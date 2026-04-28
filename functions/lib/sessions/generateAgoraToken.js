"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.generateAgoraToken = void 0;
const https_1 = require("firebase-functions/v2/https");
const admin = require("firebase-admin");
const agora_token_1 = require("agora-token");
const constants_1 = require("../config/constants");
const db = admin.firestore();
// Mints a per-session Agora RTC token. Called by both participants
// (user + priest) right after they navigate into the voice call
// screen. The token is short-lived (1h) and tied to a specific
// channel name (= sessionId), so leaking one only ever exposes
// access to a single session — not the project.
//
// Why server-side: the App Certificate signs the token. Putting it
// in client code would let anyone mint tokens for any channel and
// hijack arbitrary calls. The CF gate also validates participation
// (only the user/priest in this session) and session state (must be
// active + voice), which rules cannot enforce as cleanly.
//
// Returns:
//   { token, uid, channelName }
// `uid` is the numeric Agora user id we derived from the caller's
// Firebase uid — Agora's protocol uses 32-bit ints, not strings,
// and we want the same Firebase user to always map to the same
// Agora id across reconnects so onUserOffline correlates correctly.
exports.generateAgoraToken = (0, https_1.onCall)({ region: constants_1.REGION }, async (request) => {
    var _a, _b;
    if (!request.auth) {
        throw new https_1.HttpsError("unauthenticated", "Must be logged in");
    }
    const uid = request.auth.uid;
    const sessionId = (_a = request.data) === null || _a === void 0 ? void 0 : _a.sessionId;
    if (!sessionId) {
        throw new https_1.HttpsError("invalid-argument", "Missing sessionId");
    }
    const sessionSnap = await db.doc(`sessions/${sessionId}`).get();
    if (!sessionSnap.exists) {
        throw new https_1.HttpsError("not-found", "Session not found");
    }
    const session = (_b = sessionSnap.data()) !== null && _b !== void 0 ? _b : {};
    // Only the two parties on the session may mint a token. Catches
    // a curious dev calling the function with an arbitrary sessionId
    // before the rules layer can.
    if (uid !== session.userId && uid !== session.priestId) {
        throw new https_1.HttpsError("permission-denied", "Not a participant in this session");
    }
    // The token is only useful while the session is live. Refusing
    // pre-active sessions also stops a malicious priest who hasn't
    // accepted from joining the channel ahead of the user.
    if (session.status !== "active") {
        throw new https_1.HttpsError("failed-precondition", "Session is not active");
    }
    if (session.type !== "voice") {
        throw new https_1.HttpsError("failed-precondition", "Not a voice session");
    }
    const appId = process.env.AGORA_APP_ID;
    const appCertificate = process.env.AGORA_APP_CERTIFICATE;
    if (!appId || !appCertificate) {
        console.error("[generateAgoraToken] Missing Agora credentials");
        throw new https_1.HttpsError("internal", "Voice service configuration error");
    }
    // Channel name = sessionId. Guarantees one channel per session
    // without an extra round-trip to allocate a name.
    const channelName = sessionId;
    const agoraUid = hashUidToAgoraId(uid);
    const tokenTtlSeconds = 3600;
    const privilegeExpireTime = Math.floor(Date.now() / 1000) + tokenTtlSeconds;
    const token = agora_token_1.RtcTokenBuilder.buildTokenWithUid(appId, appCertificate, channelName, agoraUid, agora_token_1.RtcRole.PUBLISHER, tokenTtlSeconds, privilegeExpireTime);
    console.log(`[generateAgoraToken] session=${sessionId} ` +
        `firebaseUid=${uid} agoraUid=${agoraUid}`);
    return {
        token,
        uid: agoraUid,
        channelName,
    };
});
// Convert a Firebase uid string to a stable 32-bit unsigned int.
// Agora's token + protocol need a numeric uid; the same string
// must always map to the same number so reconnects and offline
// callbacks correlate against the existing connection.
function hashUidToAgoraId(firebaseUid) {
    let hash = 0;
    for (let i = 0; i < firebaseUid.length; i++) {
        const char = firebaseUid.charCodeAt(i);
        hash = ((hash << 5) - hash) + char;
        // Keep within 32 bits.
        hash = hash & hash;
    }
    // Agora rejects 0 as a "let me pick" sentinel — guard the
    // unlikely but possible collision.
    const result = Math.abs(hash);
    return result === 0 ? 1 : result;
}
//# sourceMappingURL=generateAgoraToken.js.map