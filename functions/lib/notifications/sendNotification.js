"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.sendNotification = void 0;
const https_1 = require("firebase-functions/v2/https");
const constants_1 = require("../config/constants");
exports.sendNotification = (0, https_1.onCall)({ region: constants_1.REGION }, async (request) => {
    // TODO Week 4: Send push via OneSignal
    throw new https_1.HttpsError("unimplemented", "Not yet implemented");
});
//# sourceMappingURL=sendNotification.js.map