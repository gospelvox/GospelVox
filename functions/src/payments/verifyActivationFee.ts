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

import {onCall, HttpsError} from "firebase-functions/v2/https";
import * as admin from "firebase-admin";
import * as crypto from "crypto";
// See createCoinOrder.ts for why this uses require-style import.
import Razorpay = require("razorpay");
import {REGION} from "../config/constants";
import {sendPushNotification} from "../notifications/sendPush";

const db = admin.firestore();

export const verifyActivationFee = onCall(
  {region: REGION},
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Must be logged in");
    }

    const uid = request.auth.uid;
    const {
      razorpayPaymentId,
      razorpayOrderId,
      razorpaySignature,
    } = request.data as {
      razorpayPaymentId?: string;
      razorpayOrderId?: string;
      razorpaySignature?: string;
    };

    if (!razorpayPaymentId || !razorpayOrderId || !razorpaySignature) {
      throw new HttpsError("invalid-argument", "Missing payment fields");
    }

    const keyId = process.env.RAZORPAY_KEY_ID;
    const keySecret = process.env.RAZORPAY_KEY_SECRET;
    if (!keyId || !keySecret) {
      throw new HttpsError(
        "failed-precondition",
        "Razorpay not configured on the server",
      );
    }

    // ── 0. Pull priest doc once up-front ──
    const priestRef = db.doc(`priests/${uid}`);
    const priestSnap = await priestRef.get();
    if (!priestSnap.exists) {
      throw new HttpsError("not-found", "Speaker profile not found");
    }
    const priestData = priestSnap.data() ?? {};

    if (priestData.status !== "approved") {
      throw new HttpsError(
        "failed-precondition",
        "Your application must be approved before activation",
      );
    }

    // Already activated — idempotent: no charge replay, just say OK.
    if (priestData.isActivated === true) {
      return {success: true, alreadyActivated: true};
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
      return {success: true, alreadyActivated: true};
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
    if (
      sigBufA.length !== sigBufB.length ||
      !crypto.timingSafeEqual(sigBufA, sigBufB)
    ) {
      throw new HttpsError(
        "permission-denied",
        "Payment signature mismatch — payment rejected",
      );
    }

    // ── 3. Cross-check order with Razorpay API ──
    // Signature proves the message came from Razorpay, but re-fetching
    // the order confirms it's actually paid and for the expected
    // amount. Defends against replay of a leaked signature.
    const razorpay = new Razorpay({key_id: keyId, key_secret: keySecret});

    let orderStatus: string;
    let orderAmountPaise: number;
    let notesUid: string | undefined;
    let notesPurpose: string | undefined;

    try {
      const order = await razorpay.orders.fetch(razorpayOrderId);
      orderStatus = String(order.status);
      orderAmountPaise = Number(order.amount);
      const notes = (order.notes ?? {}) as Record<string, string>;
      notesUid = notes.uid;
      notesPurpose = notes.purpose;
    } catch (_) {
      throw new HttpsError(
        "internal",
        "Could not verify order with Razorpay",
      );
    }

    if (orderStatus !== "paid") {
      throw new HttpsError(
        "failed-precondition",
        `Order not paid (status=${orderStatus})`,
      );
    }

    // Order must belong to THIS priest — prevents a priest from
    // replaying another priest's activation payment.
    if (notesUid !== uid) {
      throw new HttpsError(
        "permission-denied",
        "Order does not belong to this user",
      );
    }

    if (notesPurpose !== "priest_activation") {
      throw new HttpsError(
        "failed-precondition",
        "Order is not an activation payment",
      );
    }

    // Confirm the amount matches current configured fee.
    const settingsDoc = await db.doc("app_config/settings").get();
    const expectedRupees = Number(
      settingsDoc.data()?.priestActivationFee ?? 500,
    );
    if (orderAmountPaise !== expectedRupees * 100) {
      throw new HttpsError(
        "failed-precondition",
        "Order amount does not match current activation fee",
      );
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
      body:
        "Your speaker account is now active. " +
        "You can start accepting sessions.",
      isRead: false,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
    });

    await batch.commit();

    // Push the priest's device(s) so they see activation confirmed
    // even if they backgrounded the app during Razorpay's redirect.
    await sendPushNotification({
      userId: uid,
      title: "Account Activated!",
      body:
        "Your speaker account is now active. " +
        "You can start accepting sessions.",
      data: {
        type: "account_activated",
        route: "/priest",
      },
    });

    return {success: true, alreadyActivated: false};
  },
);
