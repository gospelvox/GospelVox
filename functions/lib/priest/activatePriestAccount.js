"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.activatePriestAccount = void 0;
const https_1 = require("firebase-functions/v2/https");
const constants_1 = require("../config/constants");
exports.activatePriestAccount = (0, https_1.onCall)({ region: constants_1.REGION }, async (request) => {
    // TODO Week 2: After Rs.500 payment verified,
    // set priests/{uid}.isActivated = true
    throw new https_1.HttpsError("unimplemented", "Not yet implemented");
});
//# sourceMappingURL=activatePriestAccount.js.map