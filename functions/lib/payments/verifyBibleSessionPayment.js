"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.verifyBibleSessionPayment = void 0;
const https_1 = require("firebase-functions/v2/https");
const constants_1 = require("../config/constants");
exports.verifyBibleSessionPayment = (0, https_1.onCall)({ region: constants_1.REGION }, async (request) => {
    // TODO Week 5: Verify Bible session payment, return Meet link
    throw new https_1.HttpsError("unimplemented", "Not yet implemented");
});
//# sourceMappingURL=verifyBibleSessionPayment.js.map