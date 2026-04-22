"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.billingTick = void 0;
const https_1 = require("firebase-functions/v2/https");
const constants_1 = require("../config/constants");
exports.billingTick = (0, https_1.onCall)({ region: constants_1.REGION }, async (request) => {
    // TODO Week 3: Called by client heartbeat every 60s
    // Deduct coins from user, credit priest earnings
    // Check low balance, auto-end if zero
    throw new https_1.HttpsError("unimplemented", "Not yet implemented");
});
//# sourceMappingURL=billingTick.js.map