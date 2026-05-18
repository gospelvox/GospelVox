"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.bibleSessionReminders = void 0;
const scheduler_1 = require("firebase-functions/v2/scheduler");
const admin = require("firebase-admin");
const constants_1 = require("../config/constants");
const sendPush_1 = require("../notifications/sendPush");
const db = admin.firestore();
const FANOUT_CHUNK_SIZE = 200;
// Time windows. Each window must be wider than the cron cadence
// (5 min) so a single tick never misses a reminder boundary. We
// also gate on a per-session `remindersSent` map so a tick that
// catches the window twice (rare clock drift, retries) only fires
// once per kind per session.
const FIVE_MIN = 5;
const ONE_HOUR_MIN = 60;
const ONE_DAY_MIN = 24 * 60;
function chunkArray(arr, size) {
    const out = [];
    for (let i = 0; i < arr.length; i += size) {
        out.push(arr.slice(i, i + size));
    }
    return out;
}
// In-app inbox docs + OS push for a list of registrant doc snapshots.
// In-app first (the inbox is the source of truth), push second (best-
// effort). Errors in either path are logged and swallowed so one bad
// session never blocks the rest of the cron tick.
async function notifyRegistrants(sessionId, regs, payload) {
    for (const chunk of chunkArray(regs, FANOUT_CHUNK_SIZE)) {
        const batch = db.batch();
        for (const reg of chunk) {
            const notifRef = db.collection("notifications").doc();
            batch.set(notifRef, {
                userId: reg.id,
                type: payload.type,
                title: payload.title,
                body: payload.body,
                sessionId,
                data: { sessionId },
                isRead: false,
                createdAt: admin.firestore.FieldValue.serverTimestamp(),
            });
        }
        try {
            await batch.commit();
        }
        catch (err) {
            console.error("[bibleSessionReminders] notif batch failed for " +
                `${sessionId}:`, err);
        }
        await Promise.all(chunk.map((reg) => (0, sendPush_1.sendPushNotification)({
            userId: reg.id,
            title: payload.title,
            body: payload.body,
            data: {
                type: payload.type,
                sessionId,
                route: `/bible/detail/${sessionId}`,
            },
        })));
    }
}
// Reads the registrations subcollection once per cron-tick branch.
// Cheap enough at V1 scale that we don't try to share a single read
// across the four user-facing branches — each branch only fires
// within a 5-minute window per session, so realistically a session
// reads its regs at most twice during the day before going live.
async function activeRegistrants(sessionId) {
    const snap = await db
        .collection(`bible_sessions/${sessionId}/registrations`)
        .get();
    return snap.docs.filter((d) => d.data().status !== "cancelled");
}
// Scheduled every 5 minutes. Iterates over upcoming sessions, classifies
// each by `diffMin` (minutes until scheduledAt), and fires whichever
// reminders fall inside the current 5-minute window AND haven't been
// fired before (per the `remindersSent` map on the session doc).
//
// Why a single-field query: filtering only on `status == 'upcoming'`
// keeps us in single-field equality land — no composite index needed.
// The scheduledAt-cutoff filter happens client-side after read. V1
// session volume is small (dozens), so the cost is negligible and
// the trade-off is worth the deploy-simplicity.
exports.bibleSessionReminders = (0, scheduler_1.onSchedule)({
    schedule: "every 5 minutes",
    timeZone: "Asia/Kolkata",
    region: constants_1.REGION,
    retryCount: 2,
}, async () => {
    var _a, _b, _c, _d, _e;
    const now = new Date();
    const upcoming = await db
        .collection("bible_sessions")
        .where("status", "==", "upcoming")
        .get();
    if (upcoming.empty) {
        console.log("[bibleSessionReminders] no upcoming sessions");
        return;
    }
    for (const sessionDoc of upcoming.docs) {
        const session = sessionDoc.data();
        const sessionId = sessionDoc.id;
        const scheduledTs = session.scheduledAt;
        const scheduledAt = scheduledTs === null || scheduledTs === void 0 ? void 0 : scheduledTs.toDate();
        if (!scheduledAt)
            continue;
        const diffMin = Math.round((scheduledAt.getTime() - now.getTime()) / 60000);
        // Skip sessions outside the reminder horizon — more than ~25h
        // away (no 24h reminder yet) OR more than 1h past start (start
        // reminder already fired or scheduledAt was in the past on
        // creation, which the UI prevents).
        if (diffMin > ONE_DAY_MIN + FIVE_MIN || diffMin < -ONE_HOUR_MIN) {
            continue;
        }
        const title = String((_a = session.title) !== null && _a !== void 0 ? _a : "Bible Session");
        const priestId = session.priestId;
        const priestName = String((_b = session.priestName) !== null && _b !== void 0 ? _b : "Speaker");
        const meetingLink = typeof session.meetingLink === "string"
            ? session.meetingLink
            : "";
        const sent = (_c = session.remindersSent) !== null && _c !== void 0 ? _c : {};
        const sessionRef = sessionDoc.ref;
        // ── 24 h before → registered users ───────────────────────────
        if (diffMin <= ONE_DAY_MIN &&
            diffMin > ONE_DAY_MIN - FIVE_MIN &&
            !sent["24h_users"]) {
            const regs = await activeRegistrants(sessionId);
            await notifyRegistrants(sessionId, regs, {
                type: "bible_session_reminder_24h",
                title: "📖 Session Tomorrow",
                body: `"${title}" with ${priestName} is tomorrow. ` +
                    "Don't miss this blessing!",
            });
            await sessionRef.update({ "remindersSent.24h_users": true });
        }
        // ── 24 h before → priest (only if link still missing) ────────
        if (priestId &&
            diffMin <= ONE_DAY_MIN &&
            diffMin > ONE_DAY_MIN - FIVE_MIN &&
            !sent["24h_priest"] &&
            meetingLink === "") {
            await (0, sendPush_1.sendPushNotification)({
                userId: priestId,
                title: "⚠️ Add Meeting Link",
                body: `"${title}" is tomorrow — ` +
                    "please add the Google Meet link.",
                data: {
                    type: "bible_session_link_reminder",
                    sessionId,
                    route: `/priest/bible/${sessionId}`,
                },
            });
            await sessionRef.update({ "remindersSent.24h_priest": true });
        }
        // ── 1 h before → registered users ────────────────────────────
        if (diffMin <= ONE_HOUR_MIN &&
            diffMin > ONE_HOUR_MIN - FIVE_MIN &&
            !sent["1h_users"]) {
            const regs = await activeRegistrants(sessionId);
            await notifyRegistrants(sessionId, regs, {
                type: "bible_session_reminder_1h",
                title: "🕐 Starting in 1 Hour",
                body: `"${title}" starts in 1 hour. Prepare your heart 🙏`,
            });
            await sessionRef.update({ "remindersSent.1h_users": true });
        }
        // ── 1 h before → priest URGENT (only if link still missing) ──
        if (priestId &&
            diffMin <= ONE_HOUR_MIN &&
            diffMin > ONE_HOUR_MIN - FIVE_MIN &&
            !sent["1h_priest"] &&
            meetingLink === "") {
            await (0, sendPush_1.sendPushNotification)({
                userId: priestId,
                title: "🚨 URGENT: Add Meeting Link!",
                body: `"${title}" starts in 1 hour — ` +
                    "add the Google Meet link NOW.",
                data: {
                    type: "bible_session_link_urgent",
                    sessionId,
                    route: `/priest/bible/${sessionId}`,
                },
            });
            await sessionRef.update({ "remindersSent.1h_priest": true });
        }
        // ── 15 min before → registered-but-unpaid users (conversion) ─
        if (diffMin <= 15 &&
            diffMin > 15 - FIVE_MIN &&
            !sent["15m_unpaid"]) {
            const unpaidSnap = await db
                .collection(`bible_sessions/${sessionId}/registrations`)
                .where("status", "==", "registered")
                .get();
            for (const reg of unpaidSnap.docs) {
                await (0, sendPush_1.sendPushNotification)({
                    userId: reg.id,
                    title: "⏰ Pay Now — Starting in 15 min!",
                    body: `"${title}" starts soon. ` +
                        "Pay now to get the meeting link.",
                    data: {
                        type: "bible_session_pay_reminder",
                        sessionId,
                        route: `/bible/detail/${sessionId}`,
                    },
                });
            }
            await sessionRef.update({ "remindersSent.15m_unpaid": true });
        }
        // ── 15 min before → priest go-live nudge ─────────────────────
        if (priestId &&
            diffMin <= 15 &&
            diffMin > 15 - FIVE_MIN &&
            !sent["15m_priest"]) {
            await (0, sendPush_1.sendPushNotification)({
                userId: priestId,
                title: "🎙️ Go Live in 15 Minutes",
                body: `"${title}" starts soon. ` +
                    "Get ready to lead your session.",
                data: {
                    type: "bible_session_golive",
                    sessionId,
                    route: `/priest/bible/${sessionId}`,
                },
            });
            await sessionRef.update({ "remindersSent.15m_priest": true });
        }
        // ── At start (within 5 min) → paid users ─────────────────────
        // Suppressed when the priest hasn't added a meeting link yet —
        // a "tap to join" push that lands on STATE B (no link) reads
        // as a broken app, not a missed-link priest. We DON'T mark
        // start_users:true in that case so the reminder retries on
        // the next cron tick once the link lands (still inside the
        // 5-min window if the priest is hurrying).
        if (diffMin <= 5 &&
            diffMin > 0 &&
            !sent["start_users"] &&
            meetingLink !== "") {
            const paidSnap = await db
                .collection(`bible_sessions/${sessionId}/registrations`)
                .where("status", "==", "paid")
                .get();
            await notifyRegistrants(sessionId, paidSnap.docs, {
                type: "bible_session_starting",
                title: "🕊️ Session Starting Now",
                body: `"${title}" is starting — tap to join and be blessed!`,
            });
            await sessionRef.update({ "remindersSent.start_users": true });
        }
        // ── At start (within 5 min) → priest ─────────────────────────
        if (priestId &&
            diffMin <= 5 &&
            diffMin > 0 &&
            !sent["start_priest"]) {
            await (0, sendPush_1.sendPushNotification)({
                userId: priestId,
                title: "🎙️ Session Starting Now!",
                body: `"${title}" is starting. Lead your flock with grace.`,
                data: {
                    type: "bible_session_starting_priest",
                    sessionId,
                    route: `/priest/bible/${sessionId}`,
                },
            });
            await sessionRef.update({ "remindersSent.start_priest": true });
        }
        // ── General "still no link" pulse — every 30 min within 2h ──
        //
        // Unlike the 24h/1h/15m_priest reminders above (which each fire
        // exactly once because they store a boolean in remindersSent),
        // this one REPEATS so a priest who creates a session 30 minutes
        // before start gets pinged on every cron tick until they add a
        // link or the session passes. We store an ISO timestamp in the
        // separate `lastGeneralLinkReminderAt` field (NOT in remindersSent,
        // because the Dart model coerces that map to bool and a string
        // would be silently dropped) and re-fire only if 30+ min have
        // passed since the last send.
        //
        // Bounded to the 2h pre-start window so we don't pester for a
        // session that's still 5 days out — the fixed-window 24h/1h
        // reminders cover those.
        if (priestId &&
            meetingLink === "" &&
            diffMin > 0 &&
            diffMin <= 120) {
            const lastTs = session.lastGeneralLinkReminderAt;
            const lastReminder = lastTs === null || lastTs === void 0 ? void 0 : lastTs.toDate();
            const thirtyMinAgoMs = now.getTime() - 30 * 60 * 1000;
            if (!lastReminder || lastReminder.getTime() < thirtyMinAgoMs) {
                await (0, sendPush_1.sendPushNotification)({
                    userId: priestId,
                    title: "⚠️ Add Meeting Link",
                    body: `"${title}" starts in ${diffMin} min — ` +
                        "add your Google Meet link now!",
                    data: {
                        type: "bible_session_link_reminder",
                        sessionId,
                        route: `/priest/bible/${sessionId}`,
                    },
                });
                await sessionRef.update({
                    lastGeneralLinkReminderAt: admin.firestore.FieldValue.serverTimestamp(),
                });
            }
        }
    }
    // ─────────────────────────────────────────────────────────────
    // AUTO-COMPLETE PASS
    // ─────────────────────────────────────────────────────────────
    //
    // In the new flow, sessions auto-complete `durationMinutes + 15`
    // minutes after the priest hit "Start Meeting". The +15 is the
    // grace window for stragglers — `isJoinable` on the client uses
    // the same offset. Once past that deadline the priest is assumed
    // to have wrapped up and forgotten to mark it completed, so we
    // do it for them.
    //
    // Side effects per auto-completed session:
    //   • status → 'completed', completedAt = server time,
    //     autoCompleted = true (audit flag — distinguishes priest-
    //     completed from cron-completed in case we need to query
    //     for one or the other later).
    //   • One priest inbox doc summarising paid count + revenue.
    //
    // Single-field equality query keeps us index-free. Sessions that
    // were started but never reach the deadline (priest already
    // marked completed) are simply not in the live set on this tick.
    const liveSnap = await db
        .collection("bible_sessions")
        .where("status", "==", "live")
        .get();
    for (const sessionDoc of liveSnap.docs) {
        const session = sessionDoc.data();
        const sessionId = sessionDoc.id;
        const startedTs = session.startedAt;
        const startedAt = startedTs === null || startedTs === void 0 ? void 0 : startedTs.toDate();
        if (!startedAt) {
            // A live session with no startedAt would mean the start CF
            // failed to stamp it — log loudly so this becomes a known
            // anomaly the next time someone audits.
            console.warn("[bibleSessionReminders] live session without startedAt: " +
                `${sessionId}`);
            continue;
        }
        // Default to 60 min if the doc is malformed — matches the
        // model fallback. Math.round to coerce any stray float.
        const durationMinRaw = session.durationMinutes;
        const durationMin = typeof durationMinRaw === "number" && Number.isFinite(durationMinRaw)
            ? Math.max(1, Math.round(durationMinRaw))
            : 60;
        const deadlineMs = startedAt.getTime() + (durationMin + 15) * 60 * 1000;
        if (now.getTime() <= deadlineMs)
            continue;
        try {
            await sessionDoc.ref.update({
                status: "completed",
                completedAt: admin.firestore.FieldValue.serverTimestamp(),
                autoCompleted: true,
            });
        }
        catch (err) {
            console.error("[bibleSessionReminders] auto-complete flip failed for " +
                `${sessionId}:`, err);
            continue;
        }
        // Mirror completeBibleSession: bump the priest's totalSessions
        // counter so a session that ended via the auto-complete cron
        // counts the same as one the priest manually marked done.
        // Without this the dashboard / admin counters undercount
        // every session the priest forgot to wrap up themselves.
        const priestIdForCount = session.priestId;
        if (priestIdForCount) {
            try {
                await db.doc(`priests/${priestIdForCount}`).update({
                    totalSessions: admin.firestore.FieldValue.increment(1),
                });
            }
            catch (err) {
                console.error("[bibleSessionReminders] totalSessions increment failed " +
                    `for priest=${priestIdForCount} session=${sessionId}:`, err);
            }
        }
        // Priest summary — count + revenue. paid registrations only;
        // 'registered' rows are unpaid and don't contribute revenue.
        let paidCount = 0;
        try {
            const paidRegs = await db
                .collection(`bible_sessions/${sessionId}/registrations`)
                .where("status", "==", "paid")
                .get();
            paidCount = paidRegs.size;
        }
        catch (err) {
            console.error("[bibleSessionReminders] paid-count read failed for " +
                `${sessionId}:`, err);
        }
        const price = Number((_d = session.price) !== null && _d !== void 0 ? _d : 0);
        const totalRevenue = paidCount * price;
        const title = String((_e = session.title) !== null && _e !== void 0 ? _e : "Bible Session");
        const priestId = session.priestId;
        if (!priestId)
            continue;
        try {
            const notifRef = db.collection("notifications").doc();
            await notifRef.set({
                userId: priestId,
                type: "bible_session_auto_completed",
                title: "🙌 Session Auto-Completed",
                body: `"${title}" wrapped up — ₹${totalRevenue} from ${paidCount} ` +
                    `attendee${paidCount === 1 ? "" : "s"}.`,
                sessionId,
                data: { sessionId },
                isRead: false,
                createdAt: admin.firestore.FieldValue.serverTimestamp(),
            });
        }
        catch (err) {
            console.error("[bibleSessionReminders] auto-complete notif failed for " +
                `${sessionId}:`, err);
        }
    }
});
//# sourceMappingURL=bibleSessionReminders.js.map