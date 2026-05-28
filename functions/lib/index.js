"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.sendNotification = exports.onBibleSessionRated = exports.createBibleSession = exports.payAndJoinBibleSession = exports.startBibleSession = exports.bibleSessionReminders = exports.completeBibleSession = exports.notifyMeetLinkAdded = exports.onBibleRegistrationWrite = exports.notifyBibleSessionCancellation = exports.notifyAvailableSubscribers = exports.onUserCreated = exports.requestWithdrawal = exports.activatePriestAccount = exports.onReportResolved = exports.updateAppConfig = exports.approveRejectMatrimony = exports.approveRejectPriest = exports.getPublicPriestReviews = exports.backfillPriestReviews = exports.replyToReview = exports.onSessionRated = exports.onSessionTerminal = exports.sendPriestMessage = exports.sendFollowUp = exports.generateAgoraToken = exports.sessionWatchdog = exports.endSession = exports.billingTick = exports.expireSessionRequest = exports.createSessionRequest = exports.verifyMatrimonyPayment = exports.verifyBibleSessionPayment = exports.verifyActivationFee = exports.createActivationOrder = exports.verifyCoinPurchase = exports.createCoinOrder = void 0;
const admin = require("firebase-admin");
admin.initializeApp();
// ═══ Payments ═══
var createCoinOrder_1 = require("./payments/createCoinOrder");
Object.defineProperty(exports, "createCoinOrder", { enumerable: true, get: function () { return createCoinOrder_1.createCoinOrder; } });
var verifyCoinPurchase_1 = require("./payments/verifyCoinPurchase");
Object.defineProperty(exports, "verifyCoinPurchase", { enumerable: true, get: function () { return verifyCoinPurchase_1.verifyCoinPurchase; } });
var createActivationOrder_1 = require("./payments/createActivationOrder");
Object.defineProperty(exports, "createActivationOrder", { enumerable: true, get: function () { return createActivationOrder_1.createActivationOrder; } });
var verifyActivationFee_1 = require("./payments/verifyActivationFee");
Object.defineProperty(exports, "verifyActivationFee", { enumerable: true, get: function () { return verifyActivationFee_1.verifyActivationFee; } });
var verifyBibleSessionPayment_1 = require("./payments/verifyBibleSessionPayment");
Object.defineProperty(exports, "verifyBibleSessionPayment", { enumerable: true, get: function () { return verifyBibleSessionPayment_1.verifyBibleSessionPayment; } });
var verifyMatrimonyPayment_1 = require("./payments/verifyMatrimonyPayment");
Object.defineProperty(exports, "verifyMatrimonyPayment", { enumerable: true, get: function () { return verifyMatrimonyPayment_1.verifyMatrimonyPayment; } });
// ═══ Sessions ═══
var createSessionRequest_1 = require("./sessions/createSessionRequest");
Object.defineProperty(exports, "createSessionRequest", { enumerable: true, get: function () { return createSessionRequest_1.createSessionRequest; } });
var expireSessionRequest_1 = require("./sessions/expireSessionRequest");
Object.defineProperty(exports, "expireSessionRequest", { enumerable: true, get: function () { return expireSessionRequest_1.expireSessionRequest; } });
var billingTick_1 = require("./sessions/billingTick");
Object.defineProperty(exports, "billingTick", { enumerable: true, get: function () { return billingTick_1.billingTick; } });
var endSession_1 = require("./sessions/endSession");
Object.defineProperty(exports, "endSession", { enumerable: true, get: function () { return endSession_1.endSession; } });
var sessionWatchdog_1 = require("./sessions/sessionWatchdog");
Object.defineProperty(exports, "sessionWatchdog", { enumerable: true, get: function () { return sessionWatchdog_1.sessionWatchdog; } });
var generateAgoraToken_1 = require("./sessions/generateAgoraToken");
Object.defineProperty(exports, "generateAgoraToken", { enumerable: true, get: function () { return generateAgoraToken_1.generateAgoraToken; } });
// Legacy templated follow-up — kept exported for backwards compat
// while the client transitions to sendPriestMessage. Existing
// follow_up notifications continue to render in the chat thread.
var sendFollowUp_1 = require("./sessions/sendFollowUp");
Object.defineProperty(exports, "sendFollowUp", { enumerable: true, get: function () { return sendFollowUp_1.sendFollowUp; } });
var sendPriestMessage_1 = require("./sessions/sendPriestMessage");
Object.defineProperty(exports, "sendPriestMessage", { enumerable: true, get: function () { return sendPriestMessage_1.sendPriestMessage; } });
var onSessionTerminal_1 = require("./sessions/onSessionTerminal");
Object.defineProperty(exports, "onSessionTerminal", { enumerable: true, get: function () { return onSessionTerminal_1.onSessionTerminal; } });
var onSessionRated_1 = require("./sessions/onSessionRated");
Object.defineProperty(exports, "onSessionRated", { enumerable: true, get: function () { return onSessionRated_1.onSessionRated; } });
var replyToReview_1 = require("./sessions/replyToReview");
Object.defineProperty(exports, "replyToReview", { enumerable: true, get: function () { return replyToReview_1.replyToReview; } });
var backfillPriestReviews_1 = require("./sessions/backfillPriestReviews");
Object.defineProperty(exports, "backfillPriestReviews", { enumerable: true, get: function () { return backfillPriestReviews_1.backfillPriestReviews; } });
var getPublicPriestReviews_1 = require("./sessions/getPublicPriestReviews");
Object.defineProperty(exports, "getPublicPriestReviews", { enumerable: true, get: function () { return getPublicPriestReviews_1.getPublicPriestReviews; } });
// ═══ Admin ═══
var approveRejectPriest_1 = require("./admin/approveRejectPriest");
Object.defineProperty(exports, "approveRejectPriest", { enumerable: true, get: function () { return approveRejectPriest_1.approveRejectPriest; } });
var approveRejectMatrimony_1 = require("./admin/approveRejectMatrimony");
Object.defineProperty(exports, "approveRejectMatrimony", { enumerable: true, get: function () { return approveRejectMatrimony_1.approveRejectMatrimony; } });
var updateAppConfig_1 = require("./admin/updateAppConfig");
Object.defineProperty(exports, "updateAppConfig", { enumerable: true, get: function () { return updateAppConfig_1.updateAppConfig; } });
var onReportResolved_1 = require("./admin/onReportResolved");
Object.defineProperty(exports, "onReportResolved", { enumerable: true, get: function () { return onReportResolved_1.onReportResolved; } });
// ═══ Priest ═══
var activatePriestAccount_1 = require("./priest/activatePriestAccount");
Object.defineProperty(exports, "activatePriestAccount", { enumerable: true, get: function () { return activatePriestAccount_1.activatePriestAccount; } });
var requestWithdrawal_1 = require("./priest/requestWithdrawal");
Object.defineProperty(exports, "requestWithdrawal", { enumerable: true, get: function () { return requestWithdrawal_1.requestWithdrawal; } });
// ═══ Users ═══
var onUserCreated_1 = require("./users/onUserCreated");
Object.defineProperty(exports, "onUserCreated", { enumerable: true, get: function () { return onUserCreated_1.onUserCreated; } });
var notifyAvailableSubscribers_1 = require("./users/notifyAvailableSubscribers");
Object.defineProperty(exports, "notifyAvailableSubscribers", { enumerable: true, get: function () { return notifyAvailableSubscribers_1.notifyAvailableSubscribers; } });
// ═══ Bible sessions ═══
var notifyBibleSessionCancellation_1 = require("./bible/notifyBibleSessionCancellation");
Object.defineProperty(exports, "notifyBibleSessionCancellation", { enumerable: true, get: function () { return notifyBibleSessionCancellation_1.notifyBibleSessionCancellation; } });
var onRegistrationWrite_1 = require("./bible/onRegistrationWrite");
Object.defineProperty(exports, "onBibleRegistrationWrite", { enumerable: true, get: function () { return onRegistrationWrite_1.onBibleRegistrationWrite; } });
var notifyMeetLinkAdded_1 = require("./bible/notifyMeetLinkAdded");
Object.defineProperty(exports, "notifyMeetLinkAdded", { enumerable: true, get: function () { return notifyMeetLinkAdded_1.notifyMeetLinkAdded; } });
var completeBibleSession_1 = require("./bible/completeBibleSession");
Object.defineProperty(exports, "completeBibleSession", { enumerable: true, get: function () { return completeBibleSession_1.completeBibleSession; } });
var bibleSessionReminders_1 = require("./bible/bibleSessionReminders");
Object.defineProperty(exports, "bibleSessionReminders", { enumerable: true, get: function () { return bibleSessionReminders_1.bibleSessionReminders; } });
var startBibleSession_1 = require("./bible/startBibleSession");
Object.defineProperty(exports, "startBibleSession", { enumerable: true, get: function () { return startBibleSession_1.startBibleSession; } });
var payAndJoinBibleSession_1 = require("./bible/payAndJoinBibleSession");
Object.defineProperty(exports, "payAndJoinBibleSession", { enumerable: true, get: function () { return payAndJoinBibleSession_1.payAndJoinBibleSession; } });
var createBibleSession_1 = require("./bible/createBibleSession");
Object.defineProperty(exports, "createBibleSession", { enumerable: true, get: function () { return createBibleSession_1.createBibleSession; } });
var onBibleSessionRated_1 = require("./bible/onBibleSessionRated");
Object.defineProperty(exports, "onBibleSessionRated", { enumerable: true, get: function () { return onBibleSessionRated_1.onBibleSessionRated; } });
// ═══ Notifications ═══
var sendNotification_1 = require("./notifications/sendNotification");
Object.defineProperty(exports, "sendNotification", { enumerable: true, get: function () { return sendNotification_1.sendNotification; } });
//# sourceMappingURL=index.js.map