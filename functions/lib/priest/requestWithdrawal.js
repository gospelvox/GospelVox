"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.requestWithdrawal = void 0;
const https_1 = require("firebase-functions/v2/https");
const constants_1 = require("../config/constants");
exports.requestWithdrawal = (0, https_1.onCall)({ region: constants_1.REGION }, async (request) => {
    // TODO Week 4: Priest requests withdrawal
    // Check min Rs.500, deduct from walletBalance,
    // create withdrawal doc with status "pending"
    throw new https_1.HttpsError("unimplemented", "Not yet implemented");
});
//# sourceMappingURL=requestWithdrawal.js.map