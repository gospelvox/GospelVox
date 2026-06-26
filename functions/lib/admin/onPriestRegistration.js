"use strict";
// Firestore trigger: a new speaker submitted their application. The
// registration repo writes priests/{uid} in a single .set() with
// status:'pending', so the first write to the doc IS the application —
// onDocumentCreated catches it.
//
// Why onDocumentCreated and NOT onDocumentWritten/onUpdated:
//   priests/{uid} is written on every heartbeat (lastHeartbeat / online
//   state). onDocumentWritten would bill an invocation on each of those
//   for every online speaker — pure waste. onDocumentCreated fires only
//   when the doc first appears, which is exactly the application moment.
//
// Edge note: a rejected speaker who later re-submits overwrites their
// existing doc (an update, not a create), so this trigger won't re-alert
// for that rare case — but they still surface in the admin dashboard's
// pending-speakers count. New applications (the dominant case) are fully
// covered.
Object.defineProperty(exports, "__esModule", { value: true });
exports.onPriestRegistration = void 0;
const firestore_1 = require("firebase-functions/v2/firestore");
const constants_1 = require("../config/constants");
const notifyAdmins_1 = require("./notifyAdmins");
exports.onPriestRegistration = (0, firestore_1.onDocumentCreated)({ document: "priests/{priestId}", region: constants_1.REGION }, async (event) => {
    var _a, _b;
    const priestId = event.params.priestId;
    // The one-time seed script (scripts/seed-firestore.js) creates a
    // "_placeholder" doc to keep the collection non-empty on first
    // deploy — never a real application, so skip it.
    if (priestId === "_placeholder")
        return;
    const data = (_a = event.data) === null || _a === void 0 ? void 0 : _a.data();
    if (!data)
        return;
    // Only a genuine pending application. A doc that somehow lands in
    // another status on create isn't an application awaiting review.
    if (data.status !== "pending")
        return;
    const name = (_b = data.fullName) === null || _b === void 0 ? void 0 : _b.trim();
    await (0, notifyAdmins_1.notifyAdmins)({
        type: "admin_new_registration",
        title: "New speaker application",
        body: `${name && name.length > 0 ? name : "A new speaker"} applied to ` +
            "join. Tap to review their application.",
        route: "/admin/speakers",
        dedupeKey: event.id,
        data: { priestId },
    });
});
//# sourceMappingURL=onPriestRegistration.js.map