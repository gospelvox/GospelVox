"use strict";
// Firestore trigger: a user filed a report (reports/{id} is created
// client-side; there is no callable in the report path). Alerts every
// admin so the moderation queue isn't something they have to remember
// to pull-to-refresh to discover.
//
// onDocumentCreated (not onWritten) keeps this cheap — it fires once,
// when the report lands, and never on the later status edits the admin
// themselves make when resolving it.
Object.defineProperty(exports, "__esModule", { value: true });
exports.onReportCreated = void 0;
const firestore_1 = require("firebase-functions/v2/firestore");
const constants_1 = require("../config/constants");
const notifyAdmins_1 = require("./notifyAdmins");
exports.onReportCreated = (0, firestore_1.onDocumentCreated)({ document: "reports/{reportId}", region: constants_1.REGION }, async (event) => {
    var _a, _b, _c;
    const data = (_a = event.data) === null || _a === void 0 ? void 0 : _a.data();
    if (!data)
        return;
    const reporter = (_b = data.reporterName) === null || _b === void 0 ? void 0 : _b.trim();
    const reported = (_c = data.reportedUserName) === null || _c === void 0 ? void 0 : _c.trim();
    await (0, notifyAdmins_1.notifyAdmins)({
        type: "admin_new_report",
        title: "New report filed",
        body: `${reporter && reporter.length > 0 ? reporter : "A user"} reported ` +
            `${reported && reported.length > 0 ? reported : "a speaker"}. ` +
            "Tap to review.",
        route: "/admin/reports",
        // event.id is stable across at-least-once retries of THIS event,
        // so a retry can't double-alert; distinct reports get distinct
        // event ids and each alerts once.
        dedupeKey: event.id,
        data: { reportId: event.params.reportId },
    });
});
//# sourceMappingURL=onReportCreated.js.map