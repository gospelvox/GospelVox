"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.createCoinOrder = void 0;
const https_1 = require("firebase-functions/v2/https");
const admin = require("firebase-admin");
// CommonJS-style import — the razorpay package's default export doesn't
// cooperate with ES module default-import unless esModuleInterop is on,
// and the rest of the functions codebase is set up without it.
const Razorpay = require("razorpay");
const constants_1 = require("../config/constants");
const db = admin.firestore();
// Creates a Razorpay order on the server BEFORE the client opens
// checkout. Going through the Orders API (rather than a client-only
// `amount` field) is what makes server-side signature verification
// possible — without an order_id, razorpay_signature is not generated
// and there is no cryptographic way for verifyCoinPurchase to know
// the payment is genuine.
//
// We also pin the authoritative amount to coin_packs config here,
// so a tampered client cannot ask for 10,000 coins for ₹1.
exports.createCoinOrder = (0, https_1.onCall)({ region: constants_1.REGION }, async (request) => {
    var _a, _b, _c, _d;
    if (!request.auth) {
        throw new https_1.HttpsError("unauthenticated", "Must be logged in");
    }
    const { packId } = request.data;
    if (!packId || typeof packId !== "string") {
        throw new https_1.HttpsError("invalid-argument", "packId is required");
    }
    const keyId = process.env.RAZORPAY_KEY_ID;
    const keySecret = process.env.RAZORPAY_KEY_SECRET;
    if (!keyId || !keySecret) {
        // Misconfiguration: the .env file didn't make it to deploy.
        // Fail loudly rather than silently skipping verification.
        throw new https_1.HttpsError("failed-precondition", "Razorpay not configured on the server");
    }
    // Resolve price from Firestore, not from the client. The client's
    // view of the price is advisory only.
    let priceRupees;
    let coins;
    if (packId === "welcome_offer") {
        // One-time offer: reject if this user already has any purchase
        // on record. The client hides the welcome card after the first
        // buy, but the server can't rely on that — a tampered request
        // could otherwise replay ₹29 → 100 coins indefinitely.
        const priorPurchase = await db
            .collection("wallet_transactions")
            .where("userId", "==", request.auth.uid)
            .where("type", "==", "purchase")
            .limit(1)
            .get();
        if (!priorPurchase.empty) {
            throw new https_1.HttpsError("failed-precondition", "Welcome offer already claimed");
        }
        const settingsDoc = await db.doc("app_config/settings").get();
        const s = (_a = settingsDoc.data()) !== null && _a !== void 0 ? _a : {};
        priceRupees = Number((_b = s.welcomeOfferPrice) !== null && _b !== void 0 ? _b : 29);
        coins = Number((_c = s.welcomeOfferCoins) !== null && _c !== void 0 ? _c : 100);
    }
    else {
        const packDoc = await db
            .doc(`app_config/coin_packs/packs/${packId}`)
            .get();
        if (!packDoc.exists) {
            throw new https_1.HttpsError("not-found", "Unknown coin pack");
        }
        const p = (_d = packDoc.data()) !== null && _d !== void 0 ? _d : {};
        if (p.isActive !== true) {
            throw new https_1.HttpsError("failed-precondition", "Pack not available");
        }
        priceRupees = Number(p.price);
        coins = Number(p.coins);
    }
    if (!Number.isFinite(priceRupees) || priceRupees <= 0) {
        throw new https_1.HttpsError("internal", "Invalid pack price in config");
    }
    const razorpay = new Razorpay({ key_id: keyId, key_secret: keySecret });
    // Razorpay receipt field is capped at 40 chars. uid can be 28 chars,
    // so a short prefix + timestamp suffix keeps us safely under.
    const receipt = `cp_${request.auth.uid.substring(0, 10)}_${Date.now().toString(36)}`;
    try {
        const order = await razorpay.orders.create({
            amount: priceRupees * 100, // paise
            currency: "INR",
            receipt,
            notes: {
                uid: request.auth.uid,
                packId,
                coins: String(coins),
            },
        });
        return {
            orderId: order.id,
            amount: order.amount,
            currency: order.currency,
            keyId, // let the client pick it up from the CF response
            coins,
            priceRupees,
        };
    }
    catch (e) {
        const msg = e instanceof Error ? e.message : "unknown";
        throw new https_1.HttpsError("internal", `Razorpay order creation failed: ${msg}`);
    }
});
//# sourceMappingURL=createCoinOrder.js.map