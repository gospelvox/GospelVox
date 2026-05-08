"use strict";
// User-side 60-second countdown handoff. Called fire-and-forget
// from session_request_cubit when the local timer hits zero — the
// CF marks the session expired AND notifies the priest about the
// missed request in one atomic op so a successful CF call always
// produces a priest notification.
//
// Why this exists vs writing status from the client:
//   • Firestore rules don't allow the user to write `endReason`
//     on a session, and the priest notification doc must be
//     CF-only (rules say so). Both writes need server authority.
//   • Client-side direct-write would race with the watchdog: if
//     status='expired' is written from the client, the watchdog
//     can't tell whether the priest was already notified. Routing
//     through this CF gives a single notify-once code path.
//
// Race with the watchdog cron:
//   The watchdog has a separate branch that sweeps pending sessions
//   older than 60s. If this CF call fails (network blip, app killed
//   before fire-and-forget completed), the watchdog catches the
//   stuck pending session at the next 5-minute tick and notifies
//   the priest from there. Both paths set status='expired' and use
//   the same notifyPriestMissedRequest helper, so the priest always
//   gets exactly one missed_request notification per stuck session.
//
// We deliberately reject if status != 'pending':
//   • Already 'expired' — somebody (this CF or the watchdog) already
//     processed it, no double-notify.
//   • 'active' — priest accepted while the user's countdown was
//     ticking down; the user shouldn't be able to undo that.
//   • 'cancelled' / 'declined' — terminal, leave alone.
Object.defineProperty(exports, "__esModule", { value: true });
exports.expireSessionRequest = void 0;
const https_1 = require("firebase-functions/v2/https");
const admin = require("firebase-admin");
const constants_1 = require("../config/constants");
const missedRequestNotif_1 = require("./missedRequestNotif");
const db = admin.firestore();
exports.expireSessionRequest = (0, https_1.onCall)({ region: constants_1.REGION }, async (request) => {
    var _a;
    if (!request.auth) {
        throw new https_1.HttpsError("unauthenticated", "Must be logged in");
    }
    const uid = request.auth.uid;
    const sessionId = (_a = request.data) === null || _a === void 0 ? void 0 : _a.sessionId;
    if (!sessionId || typeof sessionId !== "string") {
        throw new https_1.HttpsError("invalid-argument", "Missing sessionId");
    }
    const sessionRef = db.doc(`sessions/${sessionId}`);
    const outcome = await db.runTransaction(async (tx) => {
        const snap = await tx.get(sessionRef);
        if (!snap.exists) {
            // Idempotent — a session that's already been deleted is
            // not a hard error from the caller's perspective.
            return { kind: "alreadyTerminal" };
        }
        const session = snap.data();
        // Only the user who owns the request can expire it. Priests
        // decline via their own status write; admins don't expire
        // requests through this CF.
        if (session.userId !== uid) {
            throw new https_1.HttpsError("permission-denied", "Only the requester can expire this session");
        }
        // Only pending sessions are eligible. Anything else is
        // already terminal — succeed quietly so a late cubit call
        // after the priest accepted doesn't error.
        if (session.status !== "pending") {
            return { kind: "alreadyTerminal" };
        }
        tx.update(sessionRef, {
            status: "expired",
            endedAt: admin.firestore.FieldValue.serverTimestamp(),
            endReason: "request_timeout",
        });
        return { kind: "won", session };
    });
    if (outcome.kind === "alreadyTerminal") {
        return { success: true, alreadyTerminal: true };
    }
    // Notification fires only when this CF won the status flip —
    // guaranteed exactly-once. If notify fails after a successful
    // status flip the session is still correctly marked expired
    // and the watchdog won't re-process it (its query is for
    // status='pending'). At worst we silently lose ONE
    // notification, never duplicate.
    await (0, missedRequestNotif_1.notifyPriestMissedRequest)({
        session: outcome.session,
        sessionId: sessionId,
    });
    return { success: true, alreadyTerminal: false };
});
//# sourceMappingURL=expireSessionRequest.js.map