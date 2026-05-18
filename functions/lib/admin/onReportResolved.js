"use strict";
// Firestore trigger that notifies a reported priest AFTER admin has
// reviewed the complaint against them.
//
// What the priest sees: a sanitized "your account was reviewed by
// admin — outcome: resolved" notice. No reporter identity, no raw
// description, no admin notes. The full context lives only on the
// admin side. This is deliberate — exposing the reporter to the
// reported priest would create a retaliation risk that defeats the
// point of the report queue.
//
// Trigger condition: status flips pending → resolved AND the
// reported party is actually a priest (checked via priests/{uid}
// existence). A user-against-user report skips this branch.
Object.defineProperty(exports, "__esModule", { value: true });
exports.onReportResolved = void 0;
const firestore_1 = require("firebase-functions/v2/firestore");
const admin = require("firebase-admin");
const constants_1 = require("../config/constants");
const sendPush_1 = require("../notifications/sendPush");
const db = admin.firestore();
exports.onReportResolved = (0, firestore_1.onDocumentUpdated)({ document: "reports/{reportId}", region: constants_1.REGION }, async (event) => {
    var _a, _b;
    const before = (_a = event.data) === null || _a === void 0 ? void 0 : _a.before.data();
    const after = (_b = event.data) === null || _b === void 0 ? void 0 : _b.after.data();
    if (!before || !after)
        return;
    // Only react to the specific transition into resolved. Any other
    // edit (admin updating notes, re-opening, etc) is a no-op here.
    if (before.status === after.status)
        return;
    if (after.status !== "resolved")
        return;
    const reportedUid = after.reportedUser;
    if (!reportedUid)
        return;
    // Only notify when the reported party is a priest. We make this
    // call explicitly rather than infer from the report shape — the
    // reports collection is a generic ledger; users-against-users
    // can show up here too, and we don't want to ping a regular
    // user with the "your account was reviewed" notice.
    const priestSnap = await db.doc(`priests/${reportedUid}`).get();
    if (!priestSnap.exists)
        return;
    const title = "A complaint was reviewed";
    const body = "Admin reviewed a complaint involving your account. " +
        "Outcome: resolved. Contact support if you need more detail.";
    try {
        await db.collection("notifications").add({
            userId: reportedUid,
            type: "report_resolved",
            title,
            body,
            reportId: event.params.reportId,
            isRead: false,
            createdAt: admin.firestore.FieldValue.serverTimestamp(),
        });
    }
    catch (err) {
        console.error(`[onReportResolved] Inbox write failed for ${reportedUid}:`, err);
    }
    try {
        await (0, sendPush_1.sendPushNotification)({
            userId: reportedUid,
            title,
            body,
            data: {
                type: "report_resolved",
                route: "/priest/notifications",
            },
        });
    }
    catch (_c) {
        // sendPushNotification swallows internally.
    }
});
//# sourceMappingURL=onReportResolved.js.map