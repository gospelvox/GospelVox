"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.approveRejectMatrimony = void 0;
const https_1 = require("firebase-functions/v2/https");
const constants_1 = require("../config/constants");
exports.approveRejectMatrimony = (0, https_1.onCall)({ region: constants_1.REGION }, async (request) => {
    // TODO Week 5: Admin approves/rejects matrimony profile
    throw new https_1.HttpsError("unimplemented", "Not yet implemented");
});
//# sourceMappingURL=approveRejectMatrimony.js.map