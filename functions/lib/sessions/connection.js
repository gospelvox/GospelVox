"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.connectionEpochMs = connectionEpochMs;
// Single source of truth for "is this session billable, and from
// when?" Returns the millisecond epoch from which a session may be
// charged, or null if a gate-aware session never reached a confirmed
// connection (=> no charge, no commission).
//
// ── ROLLOUT SAFETY (critical) ─────────────────────────────────────
// The connection gate ONLY governs sessions explicitly marked
// gate-aware by the new client (connectionGated === true). Every
// other session — old-app builds that don't write connection stamps,
// and anything created before the gate shipped — uses the LEGACY
// model: "active == connected", billable from startedAt, exactly as
// before the gate existed. Without this guard the gate would force-
// end every real call from an app build that doesn't stamp
// userConnectedAt (i.e. all current production traffic) at the
// connect-grace deadline — a severe regression. Keying enforcement on
// connectionGated makes the rollout safe: the gate stays dormant
// until a build that actually stamps connections creates the session.
//
// ── Gate-aware sessions ───────────────────────────────────────────
// Billable only from userConnectedAt — the instant the USER's client
// confirmed a real connection (it stamps this when the priest's
// device actually joins the Agora channel, which happens regardless
// of the priest's app version). This both fixes the "billed for a
// call that never connected" bug and stops a priest earning on a
// connection that never happened — and, by keying on the user side,
// works even when the priest is still on an older build.
function connectionEpochMs(session) {
    var _a;
    const startedAt = session.startedAt;
    // Legacy / non-gated session → behave exactly as before the gate:
    // always billable from startedAt (never blocks billing).
    if (session.connectionGated !== true) {
        return startedAt ? startedAt.toMillis() : Date.now();
    }
    // Gate-aware session → billable only from the confirmed connection.
    const u = session.userConnectedAt;
    if (u) {
        return u.toMillis();
    }
    // Grandfather: a gated session already carrying billed minutes was
    // connected under a prior tick — keep it billable from startedAt.
    if (Number((_a = session.durationMinutes) !== null && _a !== void 0 ? _a : 0) > 0 && startedAt) {
        return startedAt.toMillis();
    }
    // Gate-aware, no confirmed connection, nothing billed yet → not
    // billable. The call never genuinely connected.
    return null;
}
//# sourceMappingURL=connection.js.map