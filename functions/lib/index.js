"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.sendNotification = exports.notifyBibleSessionCancellation = exports.onUserCreated = exports.requestWithdrawal = exports.activatePriestAccount = exports.updateAppConfig = exports.approveRejectMatrimony = exports.approveRejectPriest = exports.generateAgoraToken = exports.sessionWatchdog = exports.endSession = exports.billingTick = exports.createSessionRequest = exports.verifyMatrimonyPayment = exports.verifyBibleSessionPayment = exports.verifyActivationFee = exports.createActivationOrder = exports.verifyCoinPurchase = exports.createCoinOrder = void 0;
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
var billingTick_1 = require("./sessions/billingTick");
Object.defineProperty(exports, "billingTick", { enumerable: true, get: function () { return billingTick_1.billingTick; } });
var endSession_1 = require("./sessions/endSession");
Object.defineProperty(exports, "endSession", { enumerable: true, get: function () { return endSession_1.endSession; } });
var sessionWatchdog_1 = require("./sessions/sessionWatchdog");
Object.defineProperty(exports, "sessionWatchdog", { enumerable: true, get: function () { return sessionWatchdog_1.sessionWatchdog; } });
var generateAgoraToken_1 = require("./sessions/generateAgoraToken");
Object.defineProperty(exports, "generateAgoraToken", { enumerable: true, get: function () { return generateAgoraToken_1.generateAgoraToken; } });
// ═══ Admin ═══
var approveRejectPriest_1 = require("./admin/approveRejectPriest");
Object.defineProperty(exports, "approveRejectPriest", { enumerable: true, get: function () { return approveRejectPriest_1.approveRejectPriest; } });
var approveRejectMatrimony_1 = require("./admin/approveRejectMatrimony");
Object.defineProperty(exports, "approveRejectMatrimony", { enumerable: true, get: function () { return approveRejectMatrimony_1.approveRejectMatrimony; } });
var updateAppConfig_1 = require("./admin/updateAppConfig");
Object.defineProperty(exports, "updateAppConfig", { enumerable: true, get: function () { return updateAppConfig_1.updateAppConfig; } });
// ═══ Priest ═══
var activatePriestAccount_1 = require("./priest/activatePriestAccount");
Object.defineProperty(exports, "activatePriestAccount", { enumerable: true, get: function () { return activatePriestAccount_1.activatePriestAccount; } });
var requestWithdrawal_1 = require("./priest/requestWithdrawal");
Object.defineProperty(exports, "requestWithdrawal", { enumerable: true, get: function () { return requestWithdrawal_1.requestWithdrawal; } });
// ═══ Users ═══
var onUserCreated_1 = require("./users/onUserCreated");
Object.defineProperty(exports, "onUserCreated", { enumerable: true, get: function () { return onUserCreated_1.onUserCreated; } });
// ═══ Bible sessions ═══
var notifyBibleSessionCancellation_1 = require("./bible/notifyBibleSessionCancellation");
Object.defineProperty(exports, "notifyBibleSessionCancellation", { enumerable: true, get: function () { return notifyBibleSessionCancellation_1.notifyBibleSessionCancellation; } });
// ═══ Notifications ═══
var sendNotification_1 = require("./notifications/sendNotification");
Object.defineProperty(exports, "sendNotification", { enumerable: true, get: function () { return sendNotification_1.sendNotification; } });
//# sourceMappingURL=index.js.map