"use strict";
// Admin moderation for speaker applications.
//
// Handles all four admin actions in one callable:
//   approve   — pending → approved, notifies priest
//   reject    — pending → rejected, writes rejectionReason, notifies
//   suspend   — approved → suspended, notifies
//   unsuspend — suspended → approved, notifies
//
// All four need identical guard rails (admin-only, status transition
// validation, audit trail, notification) so sharing one callable
// keeps the contract in one place.  Using one function also means the
// client's repository can treat "what the admin can do to a priest"
// as a single surface.
//
// We bypass Firestore rules via the Admin SDK deliberately — the
// caller's admin role is verified at the top of the function, which
// is safer than trying to express this with declarative rules
// (admin writes to *other* users' documents cut against the normal
// "owner-only write" pattern we use everywhere else).
Object.defineProperty(exports, "__esModule", { value: true });
exports.approveRejectPriest = void 0;
const https_1 = require("firebase-functions/v2/https");
const admin = require("firebase-admin");
const constants_1 = require("../config/constants");
const db = admin.firestore();
exports.approveRejectPriest = (0, https_1.onCall)({ region: constants_1.REGION }, async (request) => {
    var _a, _b, _c, _d;
    // ── 1. Authentication ──
    if (!request.auth) {
        throw new https_1.HttpsError("unauthenticated", "Must be logged in");
    }
    const callerUid = request.auth.uid;
    // ── 2. Admin authorisation ──
    // Pull the caller's user doc; refuse unless role === "admin".
    // A missing user doc is treated as non-admin.
    const callerSnap = await db.doc(`users/${callerUid}`).get();
    if (!callerSnap.exists || ((_a = callerSnap.data()) === null || _a === void 0 ? void 0 : _a.role) !== "admin") {
        throw new https_1.HttpsError("permission-denied", "Only admins can moderate speaker applications");
    }
    // ── 3. Input validation ──
    const data = (_b = request.data) !== null && _b !== void 0 ? _b : {};
    const priestId = data.priestId;
    const action = data.action;
    const rejectionReason = data.rejectionReason;
    if (!priestId || typeof priestId !== "string") {
        throw new https_1.HttpsError("invalid-argument", "priestId is required");
    }
    const validActions = [
        "approve",
        "reject",
        "suspend",
        "unsuspend",
    ];
    if (!action || !validActions.includes(action)) {
        throw new https_1.HttpsError("invalid-argument", "action must be approve, reject, suspend, or unsuspend");
    }
    const typedAction = action;
    if (typedAction === "reject") {
        if (!rejectionReason ||
            typeof rejectionReason !== "string" ||
            rejectionReason.trim().length < 10) {
            throw new https_1.HttpsError("invalid-argument", "Rejection reason must be at least 10 characters");
        }
    }
    // ── 4. Fetch priest + check current status ──
    const priestRef = db.doc(`priests/${priestId}`);
    const priestSnap = await priestRef.get();
    if (!priestSnap.exists) {
        throw new https_1.HttpsError("not-found", "Speaker not found");
    }
    const currentStatus = (_d = (_c = priestSnap.data()) === null || _c === void 0 ? void 0 : _c.status) !== null && _d !== void 0 ? _d : "pending";
    // State machine: reject/approve require pending; suspend requires
    // approved; unsuspend requires suspended.  Anything else is a
    // programming error in the admin client we want to catch loudly.
    const allowedTransitions = {
        approve: ["pending"],
        reject: ["pending"],
        suspend: ["approved"],
        unsuspend: ["suspended"],
    };
    if (!allowedTransitions[typedAction].includes(currentStatus)) {
        throw new https_1.HttpsError("failed-precondition", `Cannot ${typedAction} a speaker whose status is "${currentStatus}"`);
    }
    // ── 5. Compute target status + update ──
    let newStatus;
    switch (typedAction) {
        case "approve":
            newStatus = "approved";
            break;
        case "reject":
            newStatus = "rejected";
            break;
        case "suspend":
            newStatus = "suspended";
            break;
        case "unsuspend":
            newStatus = "approved";
            break;
    }
    const updateData = {
        status: newStatus,
        reviewedBy: callerUid,
        reviewedAt: admin.firestore.FieldValue.serverTimestamp(),
    };
    if (typedAction === "reject" && rejectionReason) {
        updateData.rejectionReason = rejectionReason.trim();
    }
    if (typedAction === "suspend") {
        updateData.suspendedAt = admin.firestore.FieldValue.serverTimestamp();
    }
    if (typedAction === "unsuspend") {
        // Wipe the suspension timestamp so the audit trail doesn't
        // look like the priest is still suspended when queried later.
        updateData.suspendedAt = admin.firestore.FieldValue.delete();
    }
    await priestRef.update(updateData);
    // ── 6. Notify the priest ──
    // Best-effort — a failed notification should not cause the whole
    // moderation action to roll back, so this is in its own try.
    try {
        const notification = buildNotification(typedAction, rejectionReason);
        await db.collection("notifications").add(Object.assign(Object.assign({ userId: priestId }, notification), { isRead: false, createdAt: admin.firestore.FieldValue.serverTimestamp() }));
    }
    catch (err) {
        console.error(`[approveRejectPriest] Notification failed for ${priestId}:`, err);
    }
    return {
        success: true,
        newStatus,
    };
});
// Keeps notification copy out of the big switch above.
function buildNotification(action, rejectionReason) {
    switch (action) {
        case "approve":
            return {
                type: "application_approved",
                title: "Application Approved!",
                body: "Your speaker application has been approved. " +
                    "Complete activation to start accepting sessions.",
            };
        case "reject":
            return {
                type: "application_rejected",
                title: "Application Update",
                body: "Your application was not approved. Reason: " +
                    (rejectionReason !== null && rejectionReason !== void 0 ? rejectionReason : "Not specified"),
            };
        case "suspend":
            return {
                type: "account_suspended",
                title: "Account Suspended",
                body: "Your speaker account has been suspended. " +
                    "Please contact support for details.",
            };
        case "unsuspend":
            return {
                type: "account_reactivated",
                title: "Account Reactivated",
                body: "Your speaker account has been reactivated. " +
                    "You can now accept sessions again.",
            };
    }
}
//# sourceMappingURL=approveRejectPriest.js.map