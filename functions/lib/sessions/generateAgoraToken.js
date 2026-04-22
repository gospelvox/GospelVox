"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.generateAgoraToken = void 0;
const https_1 = require("firebase-functions/v2/https");
const constants_1 = require("../config/constants");
exports.generateAgoraToken = (0, https_1.onCall)({ region: constants_1.REGION }, async (request) => {
    // TODO Week 4: Generate Agora RTC token for voice channel
    // Channel name = sessionId, TTL = 3600s
    throw new https_1.HttpsError("unimplemented", "Not yet implemented");
});
//# sourceMappingURL=generateAgoraToken.js.map