import * as admin from "firebase-admin";

admin.initializeApp();

// ═══ Payments ═══
export {createCoinOrder} from "./payments/createCoinOrder";
export {verifyCoinPurchase} from "./payments/verifyCoinPurchase";
export {createActivationOrder} from "./payments/createActivationOrder";
export {verifyActivationFee} from "./payments/verifyActivationFee";
export {verifyBibleSessionPayment} from "./payments/verifyBibleSessionPayment";
// Matrimony payments intentionally not exported — the feature is not
// shipping in v1, and exporting a stub that throws `unimplemented`
// surfaces as a real runtime crash if anything ever invokes it.

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
// through verifyActivationFee (Razorpay-signed). Keeping the stub
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
export {payAndJoinBibleSession} from "./bible/payAndJoinBibleSession";
export {createBibleSession} from "./bible/createBibleSession";
export {onBibleSessionRated} from "./bible/onBibleSessionRated";

// ═══ Notifications ═══
// sendNotification stub removed — push delivery goes through sendPush
// (FCM) and the per-event CFs (missedRequestNotif, onSessionTerminal,
// etc.) that compose their own payloads. The bare stub never ran in
// production and only added a deployed-but-broken callable to probe.
