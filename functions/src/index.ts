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
export {billingTick} from "./sessions/billingTick";
export {endSession} from "./sessions/endSession";
export {sessionWatchdog} from "./sessions/sessionWatchdog";
export {generateAgoraToken} from "./sessions/generateAgoraToken";

// ═══ Admin ═══
export {approveRejectPriest} from "./admin/approveRejectPriest";
export {approveRejectMatrimony} from "./admin/approveRejectMatrimony";
export {updateAppConfig} from "./admin/updateAppConfig";

// ═══ Priest ═══
export {activatePriestAccount} from "./priest/activatePriestAccount";
export {requestWithdrawal} from "./priest/requestWithdrawal";

// ═══ Users ═══
export {onUserCreated} from "./users/onUserCreated";

// ═══ Bible sessions ═══
export {notifyBibleSessionCancellation} from "./bible/notifyBibleSessionCancellation";

// ═══ Notifications ═══
export {sendNotification} from "./notifications/sendNotification";
