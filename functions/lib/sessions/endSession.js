"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.endSession = void 0;
const https_1 = require("firebase-functions/v2/https");
const constants_1 = require("../config/constants");
exports.endSession = (0, https_1.onCall)({ region: constants_1.REGION }, async (request) => {
    // TODO Week 3: End session, final billing, update stats
    throw new https_1.HttpsError("unimplemented", "Not yet implemented");
});
//# sourceMappingURL=endSession.js.map