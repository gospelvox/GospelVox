"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.updateAppConfig = void 0;
const https_1 = require("firebase-functions/v2/https");
const constants_1 = require("../config/constants");
exports.updateAppConfig = (0, https_1.onCall)({ region: constants_1.REGION }, async (request) => {
    // TODO Week 1 Day 5: Admin updates app_config/settings
    // 1. Verify caller is admin
    // 2. Validate all fields are correct types
    // 3. Write to app_config/settings
    throw new https_1.HttpsError("unimplemented", "Not yet implemented");
});
//# sourceMappingURL=updateAppConfig.js.map