"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.onUserCreated = void 0;
const firestore_1 = require("firebase-functions/v2/firestore");
const constants_1 = require("../config/constants");
exports.onUserCreated = (0, firestore_1.onDocumentCreated)({ document: "users/{userId}", region: constants_1.REGION }, async (event) => {
    // TODO: Send welcome notification, log analytics event
    const userId = event.params.userId;
    console.log(`New user created: ${userId}`);
});
//# sourceMappingURL=onUserCreated.js.map