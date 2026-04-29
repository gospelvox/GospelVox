import {onCall, HttpsError} from "firebase-functions/v2/https";
import * as admin from "firebase-admin";
// CommonJS-style import — see createCoinOrder.ts for the rationale.
import Razorpay = require("razorpay");
import {REGION} from "../config/constants";
import {sendPushNotification} from "../notifications/sendPush";

const db = admin.firestore();

// Verifies a Razorpay payment for a Bible session and flips the
// registration to "paid", which is what unlocks the Meet link on the
// client. Unlike verifyCoinPurchase this flow has no pre-created order
// (the client opens checkout in direct-amount mode), so signature
// verification is replaced with a server-side payments.fetch round-
// trip — Razorpay's record of the payment is the source of truth.
//
// Four things must hold before we credit:
//   1. The registration exists and we haven't already credited THIS
//      session for THIS payment (per-registration idempotency — keeps
//      legitimate retries on the same session safe).
//   2. The paymentId hasn't already been consumed for ANY transaction
//      across the platform (cross-session replay defence — without
//      this, a user could pay once for session A and replay the same
//      paymentId to settle session B for free).
//   3. The payment exists on Razorpay's side, is "captured", in INR,
//      and the captured amount equals the session's server-side
//      price * 100. Server-side price is authoritative; the client's
//      `amount` is advisory only.
export const verifyBibleSessionPayment = onCall(
  {region: REGION},
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Must be logged in");
    }

    const uid = request.auth.uid;
    const {sessionId, paymentId, amount} = request.data as {
      sessionId?: string;
      paymentId?: string;
      amount?: number;
    };

    if (!sessionId || !paymentId) {
      throw new HttpsError(
        "invalid-argument",
        "sessionId and paymentId are required",
      );
    }

    const keyId = process.env.RAZORPAY_KEY_ID;
    const keySecret = process.env.RAZORPAY_KEY_SECRET;
    if (!keyId || !keySecret) {
      throw new HttpsError(
        "failed-precondition",
        "Razorpay not configured on the server",
      );
    }

    // ── 1. Per-session idempotency ──────────────────────────────
    // The registration doc is the natural dedupe key — exactly one
    // per (session, user) — and once we credit, it records the
    // paymentId. A retry from the client (network blip after
    // Razorpay returned) lands here a second time and exits early
    // without re-fetching the payment.
    const regRef = db.doc(
      `bible_sessions/${sessionId}/registrations/${uid}`,
    );
    const regSnap = await regRef.get();
    if (!regSnap.exists) {
      throw new HttpsError(
        "failed-precondition",
        "You are not registered for this session",
      );
    }
    const regData = regSnap.data() ?? {};
    if (regData.status === "paid" && regData.paymentId === paymentId) {
      return {alreadyProcessed: true};
    }

    // ── 2. Cross-session replay defence ─────────────────────────
    // Each Razorpay paymentId is allowed to settle at most ONE
    // transaction across the platform. wallet_transactions is the
    // global ledger (coin purchases write rows here too); if any
    // row already references this paymentId, the user — or a
    // tampered client — is trying to redeem the same payment for
    // a different session. Refuse.
    //
    // This check sits AFTER the per-session idempotency above so
    // that legitimate retries on the same session still succeed
    // (same paymentId on the same registration → returned at step 1
    // before we ever query the ledger).
    const existingTx = await db
      .collection("wallet_transactions")
      .where("paymentId", "==", paymentId)
      .limit(1)
      .get();
    if (!existingTx.empty) {
      throw new HttpsError(
        "permission-denied",
        "Payment already consumed",
      );
    }

    // ── 3. Resolve authoritative session price ──────────────────
    const sessionRef = db.doc(`bible_sessions/${sessionId}`);
    const sessionSnap = await sessionRef.get();
    if (!sessionSnap.exists) {
      throw new HttpsError("not-found", "Session not found");
    }
    const sessionData = sessionSnap.data() ?? {};
    if (sessionData.status === "cancelled") {
      throw new HttpsError(
        "failed-precondition",
        "This session has been cancelled",
      );
    }
    const priceRupees = Number(sessionData.price ?? 0);
    if (!Number.isFinite(priceRupees) || priceRupees <= 0) {
      throw new HttpsError(
        "internal",
        "Session price is not configured",
      );
    }
    const expectedPaise = Math.round(priceRupees * 100);

    // ── 4. Fetch payment from Razorpay ──────────────────────────
    // The fetch is the cryptographic substitute for signature
    // verification: Razorpay's API requires our key_secret, so a
    // tampered client cannot fabricate a paymentId that resolves
    // to a different status or amount than reality.
    const razorpay = new Razorpay({key_id: keyId, key_secret: keySecret});
    let paymentStatus: string;
    let paymentAmountPaise: number;
    let paymentCurrency: string;

    try {
      const payment = await razorpay.payments.fetch(paymentId);
      paymentStatus = String(payment.status);
      paymentAmountPaise = Number(payment.amount);
      paymentCurrency = String(payment.currency);
    } catch (e) {
      throw new HttpsError(
        "internal",
        "Could not verify payment with Razorpay",
      );
    }

    if (paymentStatus !== "captured") {
      throw new HttpsError(
        "failed-precondition",
        `Payment not captured (status=${paymentStatus})`,
      );
    }

    if (paymentCurrency !== "INR") {
      throw new HttpsError(
        "failed-precondition",
        `Unexpected currency: ${paymentCurrency}`,
      );
    }

    if (paymentAmountPaise !== expectedPaise) {
      // Refuse to credit if the captured amount doesn't match the
      // session price. Logging the diff helps support diagnose a
      // stale price-config or a tampered client.
      throw new HttpsError(
        "failed-precondition",
        `Amount mismatch: paid ${paymentAmountPaise}, expected ${expectedPaise}`,
      );
    }

    // The advisory `amount` from the client is informational — but
    // if it's wildly different from what was actually paid, surface
    // it so we don't silently absorb a price-display bug.
    if (
      typeof amount === "number" &&
      Number.isFinite(amount) &&
      Math.round(amount) !== priceRupees
    ) {
      console.warn(
        `[verifyBibleSessionPayment] client-amount drift uid=${uid} ` +
          `session=${sessionId} client=${amount} server=${priceRupees}`,
      );
    }

    // ── 5. Atomic credit ────────────────────────────────────────
    // The registration flip, the wallet_transactions ledger row
    // (which the cross-session check above relies on), and the
    // in-app notification all go in one batch. If any of them
    // can't be written, none of them are — that's important
    // because the ledger row is what blocks future replays of
    // this paymentId.
    const sessionTitle = String(sessionData.title ?? "Bible Session");
    const batch = db.batch();

    batch.update(regRef, {
      status: "paid",
      paymentId,
      paidAt: admin.firestore.FieldValue.serverTimestamp(),
      amountPaid: priceRupees,
    });

    const txRef = db.collection("wallet_transactions").doc();
    batch.set(txRef, {
      userId: uid,
      type: "bible_session",
      paymentId,
      sessionId,
      amountPaid: priceRupees,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
    });

    const notifRef = db.collection("notifications").doc();
    batch.set(notifRef, {
      userId: uid,
      type: "bible_session_paid",
      title: "You're in!",
      body:
        `Payment confirmed for "${sessionTitle}". ` +
        "The meeting link is now available.",
      data: {sessionId},
      isRead: false,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
    });

    await batch.commit();

    // ── 6. Push (best-effort, post-commit) ──────────────────────
    // The in-app inbox is now authoritative; the OS-level push is
    // a nicety for backgrounded apps. Errors here are swallowed
    // by sendPushNotification and don't roll back the credit.
    await sendPushNotification({
      userId: uid,
      title: "You're in!",
      body: `Payment confirmed for "${sessionTitle}". Tap to join.`,
      data: {
        type: "bible_session_paid",
        sessionId,
        route: `/bible/detail/${sessionId}`,
      },
    });

    return {alreadyProcessed: false};
  },
);
