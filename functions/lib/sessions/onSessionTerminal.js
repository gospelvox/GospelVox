"use strict";
// Firestore trigger that clears `priests/{priestId}.isBusy` whenever
// a session reaches a terminal status. This is the single source of
// truth for releasing the priest's busy flag, regardless of which
// path produced the terminal flip:
//
//   • Priest declines a ring  → status becomes "declined"  (client write)
//   • User cancels their ring → status becomes "cancelled" (client write)
//   • 60s expiry              → status becomes "expired"   (expireSessionRequest CF)
//   • Watchdog stuck-pending  → status becomes "expired"   (sessionWatchdog)
//   • Session settles cleanly → status becomes "completed" (endSession CF)
//   • Watchdog stale-active   → status becomes "completed" (sessionWatchdog)
//
// Because the user-side cancel path can't write to priests/{id}
// (rules deny non-priest writes on that doc), centralising the
// clear in this trigger is the cleanest way to keep the busy flag
// honest without granting the user write permission on the priest
// doc. endSession and the watchdog already write isBusy:false
// directly — that's idempotent with this trigger (same value, same
// outcome) so we don't need to remove those writes.
//
// We early-return on non-status snapshots (heartbeat tick, typing
// flips, rating writes) so the trigger does no work on the hot
// path of an active session.
Object.defineProperty(exports, "__esModule", { value: true });
exports.onSessionTerminal = void 0;
const firestore_1 = require("firebase-functions/v2/firestore");
const admin = require("firebase-admin");
const constants_1 = require("../config/constants");
const TERMINAL_STATUSES = new Set([
    "completed",
    "cancelled",
    "declined",
    "expired",
]);
exports.onSessionTerminal = (0, firestore_1.onDocumentUpdated)({ document: "sessions/{sessionId}", region: constants_1.REGION }, async (event) => {
    var _a, _b;
    const before = (_a = event.data) === null || _a === void 0 ? void 0 : _a.before.data();
    const after = (_b = event.data) === null || _b === void 0 ? void 0 : _b.after.data();
    if (!before || !after)
        return;
    // Only react to status transitions. Heartbeat / typing / rating
    // writes hit the same trigger but should be no-ops.
    if (before.status === after.status)
        return;
    // Only TRANSITIONS INTO a terminal status matter. A doc that
    // somehow re-emits with the same terminal status (re-write
    // edge case) is filtered out by the prior equality check.
    if (!TERMINAL_STATUSES.has(after.status))
        return;
    const priestId = after.priestId;
    if (!priestId)
        return;
    try {
        await admin.firestore().doc(`priests/${priestId}`).update({
            isBusy: false,
        });
    }
    catch (err) {
        // Don't bubble — a missing/deleted priest doc shouldn't
        // poison the trigger. The next session creation will
        // re-evaluate isBusy from whatever the doc looks like
        // then.
        console.error(`[onSessionTerminal] Failed to clear isBusy for ${priestId}:`, err);
    }
});
//# sourceMappingURL=onSessionTerminal.js.map