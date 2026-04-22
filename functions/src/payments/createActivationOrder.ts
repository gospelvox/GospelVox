// Creates a Razorpay order for the priest activation fee.
//
// Mirrors createCoinOrder's pattern deliberately — going through the
// Razorpay Orders API (rather than a client-only `amount` field) is
// what makes server-side HMAC signature verification possible. Without
// a server-generated order_id, razorpay_signature is not produced and
// there's no cryptographic way for verifyActivationFee to know the
// payment is genuine. The activation fee is real money, so skipping
// this step would mean anyone could flip their own `isActivated` flag
// by submitting any payment_id.
//
// We resolve the activation fee from app_config/settings — never
// trust a client-submitted amount.

import {onCall, HttpsError} from "firebase-functions/v2/https";
import * as admin from "firebase-admin";
// CommonJS-style import — matches createCoinOrder (no esModuleInterop).
import Razorpay = require("razorpay");
import {REGION} from "../config/constants";

const db = admin.firestore();

export const createActivationOrder = onCall(
  {region: REGION},
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Must be logged in");
    }

    const uid = request.auth.uid;

    // ── 1. Priest must be approved but not yet activated ──
    // Creating an order for an already-activated priest is a bug in
    // the client; surface it rather than silently charging them again.
    const priestDoc = await db.doc(`priests/${uid}`).get();
    if (!priestDoc.exists) {
      throw new HttpsError("not-found", "Speaker profile not found");
    }

    const priestData = priestDoc.data() ?? {};
    if (priestData.status !== "approved") {
      throw new HttpsError(
        "failed-precondition",
        "Your application must be approved before activation",
      );
    }
    if (priestData.isActivated === true) {
      throw new HttpsError(
        "failed-precondition",
        "Your account is already activated",
      );
    }

    // ── 2. Razorpay credentials ──
    const keyId = process.env.RAZORPAY_KEY_ID;
    const keySecret = process.env.RAZORPAY_KEY_SECRET;
    if (!keyId || !keySecret) {
      throw new HttpsError(
        "failed-precondition",
        "Razorpay not configured on the server",
      );
    }

    // ── 3. Resolve authoritative fee from config ──
    const settingsDoc = await db.doc("app_config/settings").get();
    const priceRupees = Number(
      settingsDoc.data()?.priestActivationFee ?? 500,
    );
    if (!Number.isFinite(priceRupees) || priceRupees <= 0) {
      throw new HttpsError("internal", "Invalid activation fee in config");
    }

    const razorpay = new Razorpay({key_id: keyId, key_secret: keySecret});

    // Receipt field capped at 40 chars. uid is up to 28 chars, so a
    // short prefix + base36 timestamp keeps us under the limit.
    const receipt = `act_${uid.substring(0, 10)}_${Date.now().toString(36)}`;

    try {
      const order = await razorpay.orders.create({
        amount: priceRupees * 100, // paise
        currency: "INR",
        receipt,
        notes: {
          uid,
          purpose: "priest_activation",
        },
      });

      return {
        orderId: order.id,
        amount: order.amount,
        currency: order.currency,
        keyId,
        priceRupees,
      };
    } catch (e) {
      const msg = e instanceof Error ? e.message : "unknown";
      throw new HttpsError(
        "internal",
        `Razorpay order creation failed: ${msg}`,
      );
    }
  },
);
