import {onCall, HttpsError} from "firebase-functions/v2/https";
import * as admin from "firebase-admin";
import {RtcRole, RtcTokenBuilder} from "agora-token";
import {REGION} from "../config/constants";

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
export const generateAgoraToken = onCall(
  {region: REGION},
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Must be logged in");
    }

    const uid = request.auth.uid;
    const sessionId = request.data?.sessionId as string | undefined;
    if (!sessionId) {
      throw new HttpsError("invalid-argument", "Missing sessionId");
    }

    const sessionSnap = await db.doc(`sessions/${sessionId}`).get();
    if (!sessionSnap.exists) {
      throw new HttpsError("not-found", "Session not found");
    }

    const session = sessionSnap.data() ?? {};

    // Only the two parties on the session may mint a token. Catches
    // a curious dev calling the function with an arbitrary sessionId
    // before the rules layer can.
    if (uid !== session.userId && uid !== session.priestId) {
      throw new HttpsError(
        "permission-denied",
        "Not a participant in this session"
      );
    }

    // The token is only useful while the session is live. Refusing
    // pre-active sessions also stops a malicious priest who hasn't
    // accepted from joining the channel ahead of the user.
    if (session.status !== "active") {
      throw new HttpsError(
        "failed-precondition",
        "Session is not active"
      );
    }

    if (session.type !== "voice") {
      throw new HttpsError(
        "failed-precondition",
        "Not a voice session"
      );
    }

    const appId = process.env.AGORA_APP_ID;
    const appCertificate = process.env.AGORA_APP_CERTIFICATE;
    if (!appId || !appCertificate) {
      console.error("[generateAgoraToken] Missing Agora credentials");
      throw new HttpsError(
        "internal",
        "Voice service configuration error"
      );
    }

    // Channel name = sessionId. Guarantees one channel per session
    // without an extra round-trip to allocate a name.
    const channelName = sessionId;
    const agoraUid = hashUidToAgoraId(uid);
    const tokenTtlSeconds = 3600;
    const privilegeExpireTime =
      Math.floor(Date.now() / 1000) + tokenTtlSeconds;

    const token = RtcTokenBuilder.buildTokenWithUid(
      appId,
      appCertificate,
      channelName,
      agoraUid,
      RtcRole.PUBLISHER,
      tokenTtlSeconds,
      privilegeExpireTime
    );

    console.log(
      `[generateAgoraToken] session=${sessionId} ` +
      `firebaseUid=${uid} agoraUid=${agoraUid}`
    );

    return {
      token,
      uid: agoraUid,
      channelName,
    };
  }
);

// Convert a Firebase uid string to a stable 32-bit unsigned int.
// Agora's token + protocol need a numeric uid; the same string
// must always map to the same number so reconnects and offline
// callbacks correlate against the existing connection.
function hashUidToAgoraId(firebaseUid: string): number {
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
