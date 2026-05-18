"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.payAndJoinBibleSession = void 0;
const https_1 = require("firebase-functions/v2/https");
const admin = require("firebase-admin");
// CommonJS-style import — see createCoinOrder.ts for the rationale.
const Razorpay = require("razorpay");
const constants_1 = require("../config/constants");
const sendPush_1 = require("../notifications/sendPush");
const db = admin.firestore();
// The new-flow payment + join CF. Replaces the verifyBibleSessionPayment
// path for any session that's already LIVE — payment now happens at
// join time, not 15 minutes before start.
//
// Handles two shapes:
//
//   (a) USER WAS REGISTERED. Existing registration doc with status
//       'registered' or 'cancelled' (a re-register through pay). We
//       flip it to 'paid' and stamp the paymentId.
//
//   (b) USER WAS NEVER REGISTERED. The user tapped "Join Now" on the
//       live session detail page without first registering. We create
//       the registration doc directly as 'paid'. Firestore rules
//       deny client-side creates with status != 'registered', but the
//       Admin SDK bypasses rules — this is the only path that can
//       create a paid-on-first-write registration.
//
// Both shapes are idempotent: a retry with the same paymentId returns
// the meeting link without re-charging.
//
// Defences (in order):
//   1. Auth required.
//   2. Session must be LIVE (status flip away from 'live' is a
//      one-way ticket to 'completed' — auto-complete or admin
//      force-complete — so this guards against paying for a session
//      that just ended).
//   3. Per-registration idempotency: same paymentId on the same reg
//      → return link, no Razorpay round-trip.
//   4. Cross-session replay: paymentId already in wallet_transactions
//      → reject. Without this, a captured paymentId could settle
//      multiple sessions at no cost.
//   5. Razorpay payments.fetch — captured, INR, exact session price.
//
// Returns {meetingLink, alreadyProcessed}.
exports.payAndJoinBibleSession = (0, https_1.onCall)({ region: constants_1.REGION }, async (request) => {
    var _a, _b, _c, _d, _e, _f, _g, _h, _j, _k, _l;
    if (!request.auth) {
        throw new https_1.HttpsError("unauthenticated", "Must be logged in");
    }
    const uid = request.auth.uid;
    const { sessionId, paymentId } = request.data;
    if (!sessionId || !paymentId) {
        throw new https_1.HttpsError("invalid-argument", "sessionId and paymentId are required");
    }
    const keyId = process.env.RAZORPAY_KEY_ID;
    const keySecret = process.env.RAZORPAY_KEY_SECRET;
    if (!keyId || !keySecret) {
        throw new https_1.HttpsError("failed-precondition", "Razorpay not configured on the server");
    }
    // ── 1. Session must be live ─────────────────────────────────
    const sessionRef = db.doc(`bible_sessions/${sessionId}`);
    const sessionSnap = await sessionRef.get();
    if (!sessionSnap.exists) {
        throw new https_1.HttpsError("not-found", "Session not found");
    }
    const sessionData = (_a = sessionSnap.data()) !== null && _a !== void 0 ? _a : {};
    if (sessionData.status !== "live") {
        throw new https_1.HttpsError("failed-precondition", `Session is ${sessionData.status} — cannot pay to join`);
    }
    const meetingLink = typeof sessionData.meetingLink === "string"
        ? sessionData.meetingLink
        : "";
    if (meetingLink === "") {
        // Should never happen — startBibleSession refuses to flip to
        // 'live' without a link — but the check is cheap insurance.
        throw new https_1.HttpsError("failed-precondition", "Meeting link not available");
    }
    const priceRupees = Number((_b = sessionData.price) !== null && _b !== void 0 ? _b : 0);
    if (!Number.isFinite(priceRupees) || priceRupees <= 0) {
        throw new https_1.HttpsError("internal", "Session price is not configured");
    }
    const expectedPaise = Math.round(priceRupees * 100);
    // ── 2. Per-registration idempotency ─────────────────────────
    // The registration doc is the natural dedupe key. If it's already
    // 'paid' with this paymentId, return the link without burning a
    // Razorpay round-trip — handles legitimate retries (network blip
    // after Razorpay returned).
    const regRef = db.doc(`bible_sessions/${sessionId}/registrations/${uid}`);
    const regSnap = await regRef.get();
    const wasRegistered = regSnap.exists;
    const regData = (_c = regSnap.data()) !== null && _c !== void 0 ? _c : {};
    if (wasRegistered &&
        regData.status === "paid" &&
        regData.paymentId === paymentId) {
        return { alreadyProcessed: true, meetingLink };
    }
    // ── 3. Cross-session replay defence ─────────────────────────
    // wallet_transactions is the global ledger. If this paymentId
    // already settled any transaction (coin top-up, another bible
    // session, matrimony unlock) we refuse to credit again.
    const existingTx = await db
        .collection("wallet_transactions")
        .where("paymentId", "==", paymentId)
        .limit(1)
        .get();
    if (!existingTx.empty) {
        throw new https_1.HttpsError("permission-denied", "Payment already consumed");
    }
    // ── 4. Verify with Razorpay ─────────────────────────────────
    const razorpay = new Razorpay({ key_id: keyId, key_secret: keySecret });
    let paymentStatus;
    let paymentAmountPaise;
    let paymentCurrency;
    try {
        const payment = await razorpay.payments.fetch(paymentId);
        paymentStatus = String(payment.status);
        paymentAmountPaise = Number(payment.amount);
        paymentCurrency = String(payment.currency);
    }
    catch (e) {
        throw new https_1.HttpsError("internal", "Could not verify payment with Razorpay");
    }
    // Razorpay merchant accounts on manual-capture mode return
    // `authorized` after a successful payment — the funds are held
    // but not settled. We must explicitly capture before crediting,
    // or the user has paid but we'll never see the money.
    //
    // `payments.capture(paymentId, amount, currency)` is idempotent
    // on Razorpay's side: a second call against an already-captured
    // payment errors with "already been captured", which we swallow
    // because it just means we won the race.
    if (paymentStatus === "authorized") {
        try {
            await razorpay.payments.capture(paymentId, expectedPaise, "INR");
        }
        catch (captureErr) {
            const description = (_e = (_d = captureErr === null || captureErr === void 0 ? void 0 : captureErr.error) === null || _d === void 0 ? void 0 : _d.description) !== null && _e !== void 0 ? _e : String(captureErr);
            if (!description.includes("already been captured")) {
                throw new https_1.HttpsError("internal", `Could not capture payment: ${description}`);
            }
        }
    }
    else if (paymentStatus !== "captured") {
        throw new https_1.HttpsError("failed-precondition", `Payment not captured (status=${paymentStatus})`);
    }
    if (paymentCurrency !== "INR") {
        throw new https_1.HttpsError("failed-precondition", `Unexpected currency: ${paymentCurrency}`);
    }
    if (paymentAmountPaise !== expectedPaise) {
        throw new https_1.HttpsError("failed-precondition", `Amount mismatch: paid ${paymentAmountPaise}, expected ${expectedPaise}`);
    }
    // ── 4b. Resolve commission split ────────────────────────────
    // Mirrors the chat/call flow in endSession.ts: the priest keeps
    // (100 - commission)% of the gross price, the platform keeps
    // the rest. Source of truth is `app_config/settings.
    // bibleCommissionPercent`; defaults to 20 so a fresh project
    // with no config doc still computes a sensible split.
    //
    // Math.floor on the priest side mirrors endSession.ts so any
    // rounding loss lands with the platform, never the priest
    // expecting a higher payout than they receive.
    let bibleCommissionPercent = 20;
    try {
        const configSnap = await db.doc("app_config/settings").get();
        const raw = (_f = configSnap.data()) === null || _f === void 0 ? void 0 : _f.bibleCommissionPercent;
        const parsed = Number(raw);
        if (Number.isFinite(parsed) && parsed >= 0 && parsed <= 100) {
            bibleCommissionPercent = parsed;
        }
    }
    catch (err) {
        console.error("[payAndJoinBibleSession] commission config read failed; " +
            "using default 20%:", err);
    }
    const priestEarning = Math.floor(priceRupees * (1 - bibleCommissionPercent / 100));
    const platformCommission = priceRupees - priestEarning;
    // ── 5. Atomic credit ────────────────────────────────────────
    // Either UPDATE an existing reg or CREATE a new one as 'paid'
    // in the same batch as the ledger row. Mirrors the all-or-nothing
    // semantics in verifyBibleSessionPayment.
    const batch = db.batch();
    const title = String((_g = sessionData.title) !== null && _g !== void 0 ? _g : "Bible Session");
    const priestId = sessionData.priestId;
    if (wasRegistered) {
        batch.update(regRef, {
            status: "paid",
            paymentId,
            paidAt: admin.firestore.FieldValue.serverTimestamp(),
            amountPaid: priceRupees,
            // Signals onBibleRegistrationWrite to skip the
            // "Registration Confirmed 🙏" inbox doc on the
            // cancelled → paid (+1 delta) path. Without this flag the
            // user gets two inbox docs from one re-pay: the trigger's
            // "Registration Confirmed" plus this CF's "You're in! 🙏".
            // Mirror of `paidOnCreate` on the create branch.
            paidViaUpdate: true,
        });
    }
    else {
        // First-time create. Pull user display info so the priest's
        // registrant list shows a name instead of a uid. Read happens
        // BEFORE the batch.commit so the fields are immediates.
        const userDoc = await db.doc(`users/${uid}`).get();
        const userInfo = (_h = userDoc.data()) !== null && _h !== void 0 ? _h : {};
        const userName = String((_k = (_j = userInfo.displayName) !== null && _j !== void 0 ? _j : userInfo.name) !== null && _k !== void 0 ? _k : "User");
        const userPhotoUrl = String((_l = userInfo.photoUrl) !== null && _l !== void 0 ? _l : "");
        batch.set(regRef, {
            userName,
            userPhotoUrl,
            status: "paid",
            paymentId,
            paidAt: admin.firestore.FieldValue.serverTimestamp(),
            amountPaid: priceRupees,
            registeredAt: admin.firestore.FieldValue.serverTimestamp(),
            // Flag so the onBibleRegistrationWrite trigger can skip the
            // "Registration Confirmed" inbox/push — a direct-pay user
            // doesn't need a 'registered' acknowledgement on top of the
            // 'paid + link' notification.
            paidOnCreate: true,
        });
    }
    // Buyer-side ledger row. Keyed by buyer uid so the user's bible
    // session history (session_history_repository.getUserBibleSessions)
    // can find it. The `amountPaid` field is the gross the user
    // actually paid — separate from the priest's `coins` row below
    // because the two represent different actors' views of the same
    // transaction.
    const txRef = db.collection("wallet_transactions").doc();
    batch.set(txRef, {
        userId: uid,
        type: "bible_session",
        paymentId,
        sessionId,
        amountPaid: priceRupees,
        description: `Bible Session: ${title}`,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    // Priest wallet credit + priest-side ledger row.
    // Without this, bible session revenue was invisible to the priest
    // wallet (walletBalance stayed at 0, transactions list filtered on
    // userId==priestUid found nothing). Mirror of endSession.ts.
    //
    // We use `coins` for the amount field on the priest row (not
    // amountPaid) because the WalletTransaction model deserialises
    // from the `coins` key — same shape as session_charge rows so
    // the priest's transactions list renders bible earnings without
    // any model fork.
    if (priestId) {
        const priestRef = db.doc(`priests/${priestId}`);
        batch.update(priestRef, {
            walletBalance: admin.firestore.FieldValue.increment(priestEarning),
            totalEarnings: admin.firestore.FieldValue.increment(priestEarning),
        });
        const priestTxRef = db.collection("wallet_transactions").doc();
        batch.set(priestTxRef, {
            userId: priestId,
            type: "bible_session_earning",
            sessionId,
            paymentId,
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
            sessionId,
            paymentId,
            coins: platformCommission,
            description: `Commission from "${title}"`,
            createdAt: admin.firestore.FieldValue.serverTimestamp(),
        });
    }
    // User-facing inbox doc. The "paid + link" combo is the meaningful
    // event — surface both in one notification rather than splitting.
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
    // Priest-facing inbox doc — same shape as verifyBibleSessionPayment
    // for consistency in the priest's inbox.
    if (priestId) {
        const priestNotifRef = db.collection("notifications").doc();
        batch.set(priestNotifRef, {
            userId: priestId,
            type: "bible_session_payment_received",
            title: "💰 Payment Received",
            body: `Someone paid ₹${priceRupees} to join "${title}"`,
            sessionId,
            data: { sessionId },
            isRead: false,
            createdAt: admin.firestore.FieldValue.serverTimestamp(),
        });
    }
    await batch.commit();
    // ── 5b. Dismiss prior "Session is LIVE — Pay ₹X to join"
    //       inbox docs for THIS user + session. startBibleSession
    //       writes one of these to every active registrant; once
    //       this user has paid it's contradictory copy ("Pay ₹X to
    //       join" sitting next to "You're in! 🙏"). We mark them
    //       read and stamp a dismissReason so the inbox UI can hide
    //       them. Best-effort: a failure here doesn't roll back the
    //       payment — the new "You're in!" doc has already landed
    //       and is the authoritative signal.
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
        console.error("[payAndJoinBibleSession] dismiss prior live notif failed for " +
            `${sessionId} uid=${uid}:`, err);
    }
    // ── 6. Pushes (best-effort, post-commit) ────────────────────
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
            body: `Someone paid ₹${priceRupees} to join "${title}"`,
            data: {
                type: "bible_session_payment_received",
                sessionId,
                route: `/priest/bible/${sessionId}`,
            },
        });
    }
    return { meetingLink, alreadyProcessed: false };
});
//# sourceMappingURL=payAndJoinBibleSession.js.map