// Agora RTC configuration for Gospel Vox voice calls.
//
// Why the App ID is hardcoded here: Agora's App ID is a public
// project identifier — it's safe on the client and is required to
// initialise the engine before we can fetch a token. The matching
// App Certificate, on the other hand, is SECRET and lives only in
// the generateAgoraToken Cloud Function (Firebase functions config
// → process.env.AGORA_APP_CERTIFICATE). Tokens are minted server-
// side and handed to the client per session, so no certificate ever
// touches the device.
//
// Channel topology: one Agora channel per session. We use the
// session document id as the channel name, which guarantees a
// unique room per call without an extra round-trip to allocate a
// channel id.
//
// To rotate the App ID later, change it once here and redeploy —
// no other client code references the value.

class AgoraConfig {
  AgoraConfig._();

  // Agora project App ID — public; safe to ship in the client.
  static const String appId = '794d5e5a5f1043f8ae2846d292793518';

  // Token TTL in seconds. The Cloud Function uses the same value
  // when minting tokens; the SDK fires onTokenPrivilegeWillExpire
  // ~30s before this expires so the cubit can refresh in flight.
  // 1 hour is comfortably longer than any realistic session.
  static const int tokenTtlSeconds = 3600;
}
