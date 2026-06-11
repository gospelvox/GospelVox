import * as admin from "firebase-admin";

admin.initializeApp();

// ═══ Payments ═══
// Every paid product flows through Google Play Billing:
//   • verifyCoinPurchase — consumable coin packs.
//   • verifyActivationPurchase — consumable priest activation.
//     (Server's priests/{uid}.isActivated is the source of truth;
//      Play's SKU is consumed after credit so multi-priest-per-Play-
//      account scenarios work without ITEM_ALREADY_OWNED.)
// Each CF resolves a Play purchaseToken against the Android
// Publisher API. There is no "create order" equivalent — Play
// handles the order lifecycle entirely on the device + Play servers.
// Matrimony payments intentionally not exported — the feature is not
// shipping in v1, and exporting a stub that throws `unimplemented`
// surfaces as a real runtime crash if anything ever invokes it.
export {verifyCoinPurchase} from "./payments/verifyCoinPurchase";
export {verifyActivationPurchase} from "./payments/verifyActivationPurchase";

// ═══ Sessions ═══
export {createSessionRequest} from "./sessions/createSessionRequest";
export {expireSessionRequest} from "./sessions/expireSessionRequest";
export {billingTick} from "./sessions/billingTick";
export {endSession} from "./sessions/endSession";
export {sessionWatchdog} from "./sessions/sessionWatchdog";
export {generateAgoraToken} from "./sessions/generateAgoraToken";
// Legacy templated follow-up — kept exported for backwards compat
// while the client transitions to sendPriestMessage. Existing
// follow_up notifications continue to render in the chat thread.
export {sendFollowUp} from "./sessions/sendFollowUp";
export {sendPriestMessage} from "./sessions/sendPriestMessage";
export {onSessionTerminal} from "./sessions/onSessionTerminal";
export {onSessionRated} from "./sessions/onSessionRated";
export {replyToReview} from "./sessions/replyToReview";
export {backfillPriestReviews} from "./sessions/backfillPriestReviews";
export {getPublicPriestReviews} from "./sessions/getPublicPriestReviews";

// ═══ Admin ═══
export {approveRejectPriest} from "./admin/approveRejectPriest";
export {onReportResolved} from "./admin/onReportResolved";
// approveRejectMatrimony + updateAppConfig are unimplemented stubs —
// not exported so they aren't deployed. Admin currently edits
// app_config/settings directly via the Firestore-rules-protected
// path; introduce the CF when matrimony or a config UI ships.

// ═══ Priest ═══
// activatePriestAccount is orphaned — the live activation flow runs
// through verifyActivationPurchase (Play-verified). Keeping the stub
// exported would deploy a CF that only throws.
export {requestWithdrawal} from "./priest/requestWithdrawal";

// ═══ Users ═══
export {onUserCreated} from "./users/onUserCreated";
export {notifyAvailableSubscribers} from "./users/notifyAvailableSubscribers";

// ═══ Bible sessions ═══
export {notifyBibleSessionCancellation} from "./bible/notifyBibleSessionCancellation";
export {onBibleRegistrationWrite} from "./bible/onRegistrationWrite";
export {notifyMeetLinkAdded} from "./bible/notifyMeetLinkAdded";
export {completeBibleSession} from "./bible/completeBibleSession";
export {bibleSessionReminders} from "./bible/bibleSessionReminders";
export {startBibleSession} from "./bible/startBibleSession";
// Play-backed pay-to-join. Fixed bible_session_199 SKU; the sessionId
// is carried on the Play purchase via obfuscatedAccountId so even an
// app-crash-mid-purchase recovers cleanly on the next launch.
export {verifyAndJoinBibleSession} from "./bible/verifyAndJoinBibleSession";
export {createBibleSession} from "./bible/createBibleSession";
export {onBibleSessionRated} from "./bible/onBibleSessionRated";

// ═══ Notifications ═══
// sendNotification stub removed — push delivery goes through sendPush
// (FCM) and the per-event CFs (missedRequestNotif, onSessionTerminal,
// etc.) that compose their own payloads. The bare stub never ran in
// production and only added a deployed-but-broken callable to probe.
