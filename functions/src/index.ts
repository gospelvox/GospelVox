import * as admin from "firebase-admin";

admin.initializeApp();

// ═══ Payments ═══
export {createCoinOrder} from "./payments/createCoinOrder";
export {verifyCoinPurchase} from "./payments/verifyCoinPurchase";
export {createActivationOrder} from "./payments/createActivationOrder";
export {verifyActivationFee} from "./payments/verifyActivationFee";
export {verifyBibleSessionPayment} from "./payments/verifyBibleSessionPayment";
export {verifyMatrimonyPayment} from "./payments/verifyMatrimonyPayment";

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

// ═══ Admin ═══
export {approveRejectPriest} from "./admin/approveRejectPriest";
export {approveRejectMatrimony} from "./admin/approveRejectMatrimony";
export {updateAppConfig} from "./admin/updateAppConfig";
export {onReportResolved} from "./admin/onReportResolved";

// ═══ Priest ═══
export {activatePriestAccount} from "./priest/activatePriestAccount";
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

// ═══ Notifications ═══
export {sendNotification} from "./notifications/sendNotification";
