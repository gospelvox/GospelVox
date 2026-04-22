"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.createSessionRequest = void 0;
const https_1 = require("firebase-functions/v2/https");
const constants_1 = require("../config/constants");
exports.createSessionRequest = (0, https_1.onCall)({ region: constants_1.REGION }, async (request) => {
    // TODO Week 3: Create session doc, check user balance,
    // notify priest, return sessionId
    throw new https_1.HttpsError("unimplemented", "Not yet implemented");
});
//# sourceMappingURL=createSessionRequest.js.map