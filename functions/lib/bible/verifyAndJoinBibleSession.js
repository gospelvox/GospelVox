"use strict";
// The Play-backed replacement for payAndJoinBibleSession.
//
// Carries over the entire money + notification flow of the legacy
// CF (priest credit, platform commission row, registration flip
// or create, twin inbox docs + pushes, prior-live-notif dismissal)
// and swaps only the rails:
//   • Razorpay HMAC + payments.fetch + capture → Google Play
//     purchaseToken verification via the Android Publisher API
//   • Per-paymentId idempotency → per-purchaseToken idempotency
//     (per-registration check + the new top-level purchases/{token}
//     dedupe doc)
//   • Variable session price → FIXED ₹199 for every bible session.
//     The per-session `price` field on bible_sessions docs is
//     informational only for this Play flow; the charge always
//     happens through the single bible_session_199 SKU.
//   • Default commission percent 20 → 40 (60/40 priest/platform
//     split rolled out alongside the Play migration).
//
// Defences (in order):
//   1. Auth required.
//   2. Session must be `status === 'live'` with a non-empty
//      meetingLink (start path enforces this on the way in).
//   3. Strict productId allowlist — only bible_session_199.
//   4. Per-registration idempotency: same purchaseToken on the
//      same reg → return link, no Play round-trip.
//   5. Cross-session replay defence via purchases/{token}: a token
//      recorded against a DIFFERENT session is rejected.
//   6. Play purchase verification.
//
// Returns {meetingLink, success: true, alreadyProcessed: bool}.
Object.defineProperty(exports, "__esModule", { value: true });
exports.verifyAndJoinBibleSession = void 0;
const https_1 = require("firebase-functions/v2/https");
const admin = require("firebase-admin");
const constants_1 = require("../config/constants");
const playVerify_1 = require("../payments/playVerify");
const sendPush_1 = require("../notifications/sendPush");
const db = admin.firestore();
const BIBLE_PRODUCT_ID = "bible_session_199";
const BIBLE_PRICE_RUPEES = 199;
const DEFAULT_BIBLE_COMMISSION_PERCENT = 40;
exports.verifyAndJoinBibleSession = (0, https_1.onCall)({ region: constants_1.REGION, secrets: ["GOOGLE_PLAY_SERVICE_ACCOUNT"] }, async (request) => {
    var _a, _b, _c, _d, _e, _f, _g, _h, _j, _k;
    const uid = (_a = request.auth) === null || _a === void 0 ? void 0 : _a.uid;
    if (!uid) {
        throw new https_1.HttpsError("unauthenticated", "Must be logged in");
    }
    const { sessionId, productId, verificationData } = request.data;
    if (!sessionId ||
        typeof sessionId !== "string" ||
        !productId ||
        typeof productId !== "string" ||
        !verificationData ||
        typeof verificationData !== "string") {
        throw new https_1.HttpsError("invalid-argument", "sessionId, productId, and verificationData are required");
    }
    // Strict allowlist — every bible session is the same SKU.
    if (productId !== BIBLE_PRODUCT_ID) {
        throw new https_1.HttpsError("failed-precondition", "Unsupported product for bible session");
    }
    const purchaseToken = verificationData;
    // ── 1. Session must be live with a meeting link ─────────────
    const sessionRef = db.doc(`bible_sessions/${sessionId}`);
    const sessionSnap = await sessionRef.get();
    if (!sessionSnap.exists) {
        throw new https_1.HttpsError("not-found", "Session not found");
    }
    const sessionData = (_b = sessionSnap.data()) !== null && _b !== void 0 ? _b : {};
    if (sessionData.status !== "live") {
        throw new https_1.HttpsError("failed-precondition", `Session is ${sessionData.status} — cannot pay to join`);
    }
    const meetingLink = typeof sessionData.meetingLink === "string"
        ? sessionData.meetingLink
        : "";
    if (meetingLink === "") {
        // startBibleSession refuses to flip 'live' without a link, so
        // this should be unreachable in practice — cheap insurance.
        throw new https_1.HttpsError("failed-precondition", "Meeting link not available");
    }
    // ── 1b. Session must still be inside its live window ────────
    // status === 'live' is NOT enough on its own: the auto-complete
    // cron only runs every 2 min, so a doc can still read 'live' for
    // a short window AFTER its promised duration has elapsed (and for
    // much longer if the cron is delayed or down). We reject the
    // payment the instant the duration is up — there is NO grace
    // window — so a user can never be charged for a session that's
    // already over. This is the server-authoritative twin of
    // BibleSessionModel.isJoinable / isPastDeadline on the client; the
    // client hides the button, this guarantees the charge can't land.
    const startedTs = sessionData.startedAt;
    if (startedTs) {
        const durationRaw = sessionData.durationMinutes;
        const durationMin = typeof durationRaw === "number" && Number.isFinite(durationRaw)
            ? Math.max(1, Math.round(durationRaw))
            : 60;
        const deadlineMs = startedTs.toMillis() + durationMin * 60 * 1000;
        if (Date.now() > deadlineMs) {
            throw new https_1.HttpsError("failed-precondition", "This session has ended — payment is closed.");
        }
    }
    const title = String((_c = sessionData.title) !== null && _c !== void 0 ? _c : "Bible Session");
    const priestId = sessionData.priestId;
    // ── 2. Per-registration idempotency ─────────────────────────
    // Fast path for legitimate retries. If the registration is
    // already paid with this exact purchaseToken, return the link
    // without burning a Play round-trip.
    const regRef = db.doc(`bible_sessions/${sessionId}/registrations/${uid}`);
    const regSnap = await regRef.get();
    const wasRegistered = regSnap.exists;
    const regData = (_d = regSnap.data()) !== null && _d !== void 0 ? _d : {};
    if (wasRegistered &&
        regData.status === "paid" &&
        regData.purchaseToken === purchaseToken) {
        try {
            await (0, playVerify_1.consumeProduct)({ productId, purchaseToken });
        }
        catch (err) {
            console.error("[verifyAndJoinBibleSession] idempotent consume rescue failed:", err instanceof Error ? err.message : String(err));
        }
        return { meetingLink, success: true, alreadyProcessed: true };
    }
    // ── 3. Cross-session replay defence ─────────────────────────
    // The purchases/{token} doc is the canonical "this token was
    // used" record. If we see a doc for a DIFFERENT session, the
    // client is replaying a single payment across multiple sessions
    // — reject. If we see a doc for the SAME session (race between
    // two parallel retries), fall through to the idempotent return.
    const purchaseRef = db.doc(`purchases/${purchaseToken}`);
    const purchaseSnap = await purchaseRef.get();
    if (purchaseSnap.exists) {
        const recordedSessionId = (_e = purchaseSnap.data()) === null || _e === void 0 ? void 0 : _e.sessionId;
        if (recordedSessionId && recordedSessionId !== sessionId) {
            throw new https_1.HttpsError("permission-denied", "Purchase token already used for a different session");
        }
        try {
            await (0, playVerify_1.consumeProduct)({ productId, purchaseToken });
        }
        catch (err) {
            console.error("[verifyAndJoinBibleSession] idempotent consume rescue failed:", err instanceof Error ? err.message : String(err));
        }
        return { meetingLink, success: true, alreadyProcessed: true };
    }
    // ── 4. Verify with Google Play ──────────────────────────────
    await (0, playVerify_1.verifyProductPurchase)({ productId, purchaseToken });
    // ── 5. Resolve commission split ─────────────────────────────
    // Source of truth is app_config/settings.bibleCommissionPercent
    // (the ADMIN/platform percentage). The default of 40 produces a
    // 60/40 priest/platform split — different from the legacy 80/20
    // default the Razorpay CF used. The math.floor on the priest
    // side mirrors endSession.ts so any rounding loss lands with
    // the platform.
    let bibleCommissionPercent = DEFAULT_BIBLE_COMMISSION_PERCENT;
    try {
        const configSnap = await db.doc("app_config/settings").get();
        const raw = (_f = configSnap.data()) === null || _f === void 0 ? void 0 : _f.bibleCommissionPercent;
        const parsed = Number(raw);
        if (Number.isFinite(parsed) && parsed >= 0 && parsed <= 100) {
            bibleCommissionPercent = parsed;
        }
    }
    catch (err) {
        console.error("[verifyAndJoinBibleSession] commission config read failed; " +
            `using default ${DEFAULT_BIBLE_COMMISSION_PERCENT}%:`, err);
    }
    const priestEarning = Math.floor(BIBLE_PRICE_RUPEES * (1 - bibleCommissionPercent / 100));
    const platformCommission = BIBLE_PRICE_RUPEES - priestEarning;
    // ── 6. Atomic credit ────────────────────────────────────────
    // Mirrors payAndJoinBibleSession structure exactly: either
    // UPDATE an existing reg or CREATE a new one as 'paid' in the
    // same batch as the ledger rows + inbox docs.
    const batch = db.batch();
    if (wasRegistered) {
        batch.update(regRef, {
            status: "paid",
            purchaseToken,
            productId,
            provider: "play",
            paidAt: admin.firestore.FieldValue.serverTimestamp(),
            amountPaid: BIBLE_PRICE_RUPEES,
            // Tells onBibleRegistrationWrite to skip the "Registration
            // Confirmed 🙏" inbox doc on the cancelled → paid (+1
            // delta) path. Without it the user gets two inbox docs
            // from one re-pay. Mirror of paidOnCreate on the create
            // branch.
            paidViaUpdate: true,
        });
    }
    else {
        // First-time create. Pull display info so the priest's
        // registrant list shows a name instead of a uid.
        const userDoc = await db.doc(`users/${uid}`).get();
        const userInfo = (_g = userDoc.data()) !== null && _g !== void 0 ? _g : {};
        const userName = String((_j = (_h = userInfo.displayName) !== null && _h !== void 0 ? _h : userInfo.name) !== null && _j !== void 0 ? _j : "User");
        const userPhotoUrl = String((_k = userInfo.photoUrl) !== null && _k !== void 0 ? _k : "");
        batch.set(regRef, {
            userName,
            userPhotoUrl,
            status: "paid",
            purchaseToken,
            productId,
            provider: "play",
            paidAt: admin.firestore.FieldValue.serverTimestamp(),
            amountPaid: BIBLE_PRICE_RUPEES,
            registeredAt: admin.firestore.FieldValue.serverTimestamp(),
            // Same flag as the legacy CF: skip the "Registration
            // Confirmed" inbox/push for a direct-pay user — the
            // "You're in! 🙏" doc below covers it.
            paidOnCreate: true,
        });
    }
    // Canonical idempotency / purchase record.
    batch.set(purchaseRef, {
        userId: uid,
        productId,
        kind: "bible_session",
        provider: "play",
        sessionId,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    // Buyer-side ledger row. Mirrors payAndJoinBibleSession so the
    // user's bible session history (session_history_repository
    // .getUserBibleSessions) continues to render this transaction.
    const txRef = db.collection("wallet_transactions").doc();
    batch.set(txRef, {
        userId: uid,
        type: "bible_session",
        provider: "play",
        productId,
        purchaseToken,
        sessionId,
        amountPaid: BIBLE_PRICE_RUPEES,
        description: `Bible Session: ${title}`,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    // Priest wallet credit + priest-side ledger row. Uses the same
    // `coins` field name as endSession.ts so the WalletTransaction
    // model deserialises both shapes without a fork.
    if (priestId) {
        const priestWalletRef = db.doc(`priests/${priestId}`);
        batch.update(priestWalletRef, {
            walletBalance: admin.firestore.FieldValue.increment(priestEarning),
            totalEarnings: admin.firestore.FieldValue.increment(priestEarning),
        });
        const priestTxRef = db.collection("wallet_transactions").doc();
        batch.set(priestTxRef, {
            userId: priestId,
            type: "bible_session_earning",
            provider: "play",
            sessionId,
            purchaseToken,
            coins: priestEarning,
            description: `Bible Session earning: ${title}`,
            createdAt: admin.firestore.FieldValue.serverTimestamp(),
        });
    }
    // Platform commission ledger row. Sentinel uid `__platform__`
    // is rule-safe (Firebase auth uids never contain underscores)
    // and lets the admin dashboard sum platform revenue via a
    // single-field equality query. Skipped when commission is zero
    // so we don't pollute the ledger with ₹0 rows.
    if (platformCommission > 0) {
        const platformTxRef = db.collection("wallet_transactions").doc();
        batch.set(platformTxRef, {
            userId: "__platform__",
            type: "bible_session_commission",
            provider: "play",
            sessionId,
            purchaseToken,
            coins: platformCommission,
            description: `Commission from "${title}"`,
            createdAt: admin.firestore.FieldValue.serverTimestamp(),
        });
    }
    // User-facing inbox doc — "paid + link" as one event so the
    // user sees a single notification, not two.
    const userNotifRef = db.collection("notifications").doc();
    batch.set(userNotifRef, {
        userId: uid,
        type: "bible_session_paid",
        title: "You're in! 🙏",
        body: `Payment confirmed for "${title}". ` +
            "Tap to open the meeting link.",
        sessionId,
        data: { sessionId },
        isRead: false,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    if (priestId) {
        const priestNotifRef = db.collection("notifications").doc();
        batch.set(priestNotifRef, {
            userId: priestId,
            type: "bible_session_payment_received",
            title: "💰 Payment Received",
            body: `Someone paid ₹${BIBLE_PRICE_RUPEES} to join "${title}"`,
            sessionId,
            data: { sessionId },
            isRead: false,
            createdAt: admin.firestore.FieldValue.serverTimestamp(),
        });
    }
    await batch.commit();
    // ── 7. Dismiss prior bible_session_live inbox docs ──────────
    // startBibleSession wrote "Session is LIVE — Pay ₹X to join"
    // to every active registrant. Now that this user has paid, that
    // copy is contradictory. Best-effort dismissal — a failure
    // doesn't roll back the payment, the new "You're in!" doc is
    // the authoritative signal.
    try {
        const liveNotifs = await db
            .collection("notifications")
            .where("userId", "==", uid)
            .where("type", "==", "bible_session_live")
            .where("sessionId", "==", sessionId)
            .where("isRead", "==", false)
            .limit(5)
            .get();
        if (!liveNotifs.empty) {
            const dismissBatch = db.batch();
            for (const doc of liveNotifs.docs) {
                dismissBatch.update(doc.ref, {
                    isRead: true,
                    dismissReason: "superseded_by_payment",
                    dismissedAt: admin.firestore.FieldValue.serverTimestamp(),
                });
            }
            await dismissBatch.commit();
        }
    }
    catch (err) {
        console.error("[verifyAndJoinBibleSession] dismiss prior live notif failed for " +
            `${sessionId} uid=${uid}:`, err);
    }
    // ── 8. Consume the consumable ───────────────────────────────
    // Releases the SKU at Play so the user can buy entry to a
    // future bible session. Best-effort — credit has landed; a
    // consume failure would surface as ITEM_ALREADY_OWNED on the
    // next bible-session buy, but the next CF call's idempotent
    // consume rescue (step 2 or 3 above) clears it.
    await (0, playVerify_1.consumeProduct)({ productId, purchaseToken });
    // ── 9. Pushes (best-effort, post-commit) ────────────────────
    await (0, sendPush_1.sendPushNotification)({
        userId: uid,
        title: "You're in! 🙏",
        body: `Payment confirmed for "${title}". Tap to join.`,
        data: {
            type: "bible_session_paid",
            sessionId,
            route: `/bible/detail/${sessionId}`,
        },
    });
    if (priestId) {
        await (0, sendPush_1.sendPushNotification)({
            userId: priestId,
            title: "💰 Payment Received",
            body: `Someone paid ₹${BIBLE_PRICE_RUPEES} to join "${title}"`,
            data: {
                type: "bible_session_payment_received",
                sessionId,
                route: `/priest/bible/${sessionId}`,
            },
        });
    }
    return {
        meetingLink,
        success: true,
        alreadyProcessed: false,
    };
});
//# sourceMappingURL=verifyAndJoinBibleSession.js.map