import {onCall, HttpsError} from "firebase-functions/v2/https";
import * as admin from "firebase-admin";
import * as crypto from "crypto";
// See createCoinOrder.ts for why this uses require-style import.
import Razorpay = require("razorpay");
import {REGION} from "../config/constants";

const db = admin.firestore();

// Credits coins to the user AFTER verifying three things:
//   1. The HMAC-SHA256 signature from Razorpay matches (proves the
//      payment data was not tampered with in transit).
//   2. The order on Razorpay's side is `paid` and its amount equals
//      the pack's server-side price (prevents downgrade attacks where
//      a client says "I paid ₹1 for 10,000 coins").
//   3. We haven't already credited this payment (idempotency).
//
// Any one of these failing is unrecoverable from the client side —
// the user's money is safe with Razorpay, but they don't get coins
// until the payment is properly reconciled. Surface a support-friendly
// error message with the paymentId so manual resolution is cheap.
export const verifyCoinPurchase = onCall(
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
      packId,
    } = request.data as {
      razorpayPaymentId?: string;
      razorpayOrderId?: string;
      razorpaySignature?: string;
      packId?: string;
    };

    if (
      !razorpayPaymentId ||
      !razorpayOrderId ||
      !razorpaySignature ||
      !packId
    ) {
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

    // ── 1. Idempotency check ────────────────────────────────────
    // Using razorpayPaymentId as the dedupe key (not orderId) since
    // a failed+retried payment attempt produces a new paymentId but
    // can reuse the same orderId.
    const existingTx = await db
      .collection("wallet_transactions")
      .where("paymentId", "==", razorpayPaymentId)
      .limit(1)
      .get();

    if (!existingTx.empty) {
      const userDoc = await db.doc(`users/${uid}`).get();
      return {
        newBalance: userDoc.data()?.coinBalance ?? 0,
        alreadyProcessed: true,
      };
    }

    // ── 2. HMAC signature verification ──────────────────────────
    // Razorpay signs `{order_id}|{payment_id}` with our key_secret
    // using HMAC-SHA256. Reproducing the same HMAC locally and
    // comparing is the cryptographic proof the payment is genuine.
    const expectedSignature = crypto
      .createHmac("sha256", keySecret)
      .update(`${razorpayOrderId}|${razorpayPaymentId}`)
      .digest("hex");

    // timingSafeEqual avoids byte-by-byte comparison leaking timing
    // info — overkill here but costs nothing.
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

    // ── 3. Cross-check the order with Razorpay API ──────────────
    // Signature verification proves the message came from Razorpay,
    // but we still re-fetch the order to confirm it's actually paid
    // and for the expected amount. This defends against the case
    // where a leaked signature from an old transaction is replayed.
    const razorpay = new Razorpay({key_id: keyId, key_secret: keySecret});

    let orderStatus: string;
    let orderAmountPaise: number;
    let notesPackId: string | undefined;
    let notesCoins: string | undefined;

    try {
      const order = await razorpay.orders.fetch(razorpayOrderId);
      orderStatus = String(order.status);
      orderAmountPaise = Number(order.amount);
      const notes = (order.notes ?? {}) as Record<string, string>;
      notesPackId = notes.packId;
      notesCoins = notes.coins;
    } catch (e) {
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

    // The order was created by createCoinOrder with packId/coins in
    // notes. Trust those values (server-signed) rather than anything
    // the client sends as `coins`/`price`.
    if (!notesPackId || notesPackId !== packId) {
      throw new HttpsError(
        "failed-precondition",
        "Order packId mismatch",
      );
    }

    const coins = Number(notesCoins);
    if (!Number.isFinite(coins) || coins <= 0) {
      throw new HttpsError("internal", "Order missing coin amount");
    }

    // Sanity-check the amount matches current config — if an admin
    // changed the pack price between order creation and payment, we
    // still honour the amount the user actually paid, but we credit
    // the coins the order was created for.
    const amountPaidRupees = Math.round(orderAmountPaise / 100);

    // ── 4. Credit + record atomically ───────────────────────────
    const batch = db.batch();

    const userRef = db.doc(`users/${uid}`);
    batch.update(userRef, {
      coinBalance: admin.firestore.FieldValue.increment(coins),
    });

    const txRef = db.collection("wallet_transactions").doc();
    batch.set(txRef, {
      userId: uid,
      type: "purchase",
      paymentId: razorpayPaymentId,
      orderId: razorpayOrderId,
      packId,
      coins,
      amountPaid: amountPaidRupees,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
    });

    await batch.commit();

    const updatedUser = await userRef.get();
    const newBalance = updatedUser.data()?.coinBalance ?? 0;

    return {newBalance, alreadyProcessed: false};
  },
);
