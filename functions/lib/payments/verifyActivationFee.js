"use strict";
// Verifies the priest activation payment and flips isActivated = true.
//
// Security layers (mirrors verifyCoinPurchase):
//   1. HMAC-SHA256 signature check proves the payment data came from
//      Razorpay unchanged — without this, a tampered client could
//      submit any payment_id and activate for free.
//   2. Cross-fetch the order from Razorpay and confirm its `paid`
//      status + amount matches the server-side fee.
//   3. Idempotency via wallet_transactions lookup — double tapping
//      verify (e.g. tab switched back-and-forth during verification)
//      doesn't double-count.
//
// After all three pass we atomically:
//   - flip priests/{uid}.isActivated = true
//   - write an audit row to wallet_transactions
//   - drop a notification doc
Object.defineProperty(exports, "__esModule", { value: true });
exports.verifyActivationFee = void 0;
const https_1 = require("firebase-functions/v2/https");
const admin = require("firebase-admin");
const crypto = require("crypto");
// See createCoinOrder.ts for why this uses require-style import.
const Razorpay = require("razorpay");
const constants_1 = require("../config/constants");
const sendPush_1 = require("../notifications/sendPush");
const db = admin.firestore();
exports.verifyActivationFee = (0, https_1.onCall)({ region: constants_1.REGION }, async (request) => {
    var _a, _b, _c, _d;
    if (!request.auth) {
        throw new https_1.HttpsError("unauthenticated", "Must be logged in");
    }
    const uid = request.auth.uid;
    const { razorpayPaymentId, razorpayOrderId, razorpaySignature, } = request.data;
    if (!razorpayPaymentId || !razorpayOrderId || !razorpaySignature) {
        throw new https_1.HttpsError("invalid-argument", "Missing payment fields");
    }
    const keyId = process.env.RAZORPAY_KEY_ID;
    const keySecret = process.env.RAZORPAY_KEY_SECRET;
    if (!keyId || !keySecret) {
        throw new https_1.HttpsError("failed-precondition", "Razorpay not configured on the server");
    }
    // ── 0. Pull priest doc once up-front ──
    const priestRef = db.doc(`priests/${uid}`);
    const priestSnap = await priestRef.get();
    if (!priestSnap.exists) {
        throw new https_1.HttpsError("not-found", "Speaker profile not found");
    }
    const priestData = (_a = priestSnap.data()) !== null && _a !== void 0 ? _a : {};
    if (priestData.status !== "approved") {
        throw new https_1.HttpsError("failed-precondition", "Your application must be approved before activation");
    }
    // Already activated — idempotent: no charge replay, just say OK.
    if (priestData.isActivated === true) {
        return { success: true, alreadyActivated: true };
    }
    // ── 1. Idempotency by paymentId ──
    // Dedupe on paymentId because a failed+retried attempt produces
    // a fresh paymentId even if the orderId is reused.
    const existingTx = await db
        .collection("wallet_transactions")
        .where("paymentId", "==", razorpayPaymentId)
        .limit(1)
        .get();
    if (!existingTx.empty) {
        return { success: true, alreadyActivated: true };
    }
    // ── 2. HMAC signature verification ──
    // Razorpay signs `{order_id}|{payment_id}` with our key_secret
    // using HMAC-SHA256. Recomputing locally and comparing is the
    // cryptographic proof this payment is genuine.
    const expectedSignature = crypto
        .createHmac("sha256", keySecret)
        .update(`${razorpayOrderId}|${razorpayPaymentId}`)
        .digest("hex");
    const sigBufA = Buffer.from(expectedSignature, "utf8");
    const sigBufB = Buffer.from(razorpaySignature, "utf8");
    if (sigBufA.length !== sigBufB.length ||
        !crypto.timingSafeEqual(sigBufA, sigBufB)) {
        throw new https_1.HttpsError("permission-denied", "Payment signature mismatch — payment rejected");
    }
    // ── 3. Cross-check order with Razorpay API ──
    // Signature proves the message came from Razorpay, but re-fetching
    // the order confirms it's actually paid and for the expected
    // amount. Defends against replay of a leaked signature.
    const razorpay = new Razorpay({ key_id: keyId, key_secret: keySecret });
    let orderStatus;
    let orderAmountPaise;
    let notesUid;
    let notesPurpose;
    try {
        const order = await razorpay.orders.fetch(razorpayOrderId);
        orderStatus = String(order.status);
        orderAmountPaise = Number(order.amount);
        const notes = ((_b = order.notes) !== null && _b !== void 0 ? _b : {});
        notesUid = notes.uid;
        notesPurpose = notes.purpose;
    }
    catch (_) {
        throw new https_1.HttpsError("internal", "Could not verify order with Razorpay");
    }
    if (orderStatus !== "paid") {
        throw new https_1.HttpsError("failed-precondition", `Order not paid (status=${orderStatus})`);
    }
    // Order must belong to THIS priest — prevents a priest from
    // replaying another priest's activation payment.
    if (notesUid !== uid) {
        throw new https_1.HttpsError("permission-denied", "Order does not belong to this user");
    }
    if (notesPurpose !== "priest_activation") {
        throw new https_1.HttpsError("failed-precondition", "Order is not an activation payment");
    }
    // Confirm the amount matches current configured fee.
    const settingsDoc = await db.doc("app_config/settings").get();
    const expectedRupees = Number((_d = (_c = settingsDoc.data()) === null || _c === void 0 ? void 0 : _c.priestActivationFee) !== null && _d !== void 0 ? _d : 500);
    if (orderAmountPaise !== expectedRupees * 100) {
        throw new https_1.HttpsError("failed-precondition", "Order amount does not match current activation fee");
    }
    const amountPaidRupees = Math.round(orderAmountPaise / 100);
    // ── 4. Atomic activation + audit + notification ──
    const batch = db.batch();
    batch.update(priestRef, {
        isActivated: true,
        activatedAt: admin.firestore.FieldValue.serverTimestamp(),
        activationPaymentId: razorpayPaymentId,
    });
    // Mirror on users/{uid} so role-gated UI elsewhere doesn't need
    // a second read to check activation. Admin SDK bypasses the
    // locked-field rule on this document.
    const userRef = db.doc(`users/${uid}`);
    batch.update(userRef, {
        isActivated: true,
    });
    const txRef = db.collection("wallet_transactions").doc();
    batch.set(txRef, {
        userId: uid,
        type: "activation_fee",
        paymentId: razorpayPaymentId,
        orderId: razorpayOrderId,
        amountPaid: amountPaidRupees,
        description: "Speaker activation fee",
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    const notifRef = db.collection("notifications").doc();
    batch.set(notifRef, {
        userId: uid,
        type: "account_activated",
        title: "Account Activated!",
        body: "Your speaker account is now active. " +
            "You can start accepting sessions.",
        isRead: false,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    await batch.commit();
    // Push the priest's device(s) so they see activation confirmed
    // even if they backgrounded the app during Razorpay's redirect.
    await (0, sendPush_1.sendPushNotification)({
        userId: uid,
        title: "Account Activated!",
        body: "Your speaker account is now active. " +
            "You can start accepting sessions.",
        data: {
            type: "account_activated",
            route: "/priest",
        },
    });
    return { success: true, alreadyActivated: false };
});
//# sourceMappingURL=verifyActivationFee.js.map