"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.verifyCoinPurchase = void 0;
const https_1 = require("firebase-functions/v2/https");
const admin = require("firebase-admin");
const constants_1 = require("../config/constants");
const playVerify_1 = require("./playVerify");
const creditCoins_1 = require("./creditCoins");
const db = admin.firestore();
// Detects the Firestore ALREADY_EXISTS failure raised when the
// creditCoins batch.create() on purchases/{token} collides with a
// doc a CONCURRENT verify call already wrote. gRPC status 6 is
// ALREADY_EXISTS; we also match the message/string code defensively
// so a minor SDK version change can't turn an idempotent race into a
// hard failure.
function isAlreadyExists(err) {
    const code = err === null || err === void 0 ? void 0 : err.code;
    if (code === 6 || code === "already-exists")
        return true;
    const msg = err instanceof Error ? err.message : String(err);
    return /already.?exists/i.test(msg);
}
// Maps a Play product id (coins_<N>) to its Firestore pack doc id
// (pack_<N>). The store catalog is the customer-facing source of
// price; the Firestore pack doc is the source of truth for how many
// coins to grant. The two IDs are kept aligned by convention —
// the admin who edits one must also edit the other in Play Console.
function productIdToPackId(productId) {
    const match = productId.match(/^coins_(\d+)$/);
    if (!match)
        return null;
    return `pack_${match[1]}`;
}
// Credits coins to the user after verifying a Google Play purchase
// token. Three security layers:
//   1. The Android Publisher API call requires our service-account
//      signed key — a tampered client cannot fabricate a token that
//      resolves to a successful (purchaseState===0) purchase for the
//      claimed productId.
//   2. We resolve the coin count from the SERVER-SIDE pack doc keyed
//      off the productId. A client cannot grant itself more coins by
//      reporting a higher-tier productId than what it actually paid
//      for — the productId is part of the Play-verified token, so
//      the cross-check happens implicitly inside the Android
//      Publisher response.
//   3. Idempotency on purchaseToken — a network retry from the client
//      (or a second tap on Verify) doesn't double-credit because
//      wallet_transactions already carries the token.
//
// After a successful credit we consume the token via the Play API
// so the consumable can be repurchased and so Google's 3-day
// acknowledgement requirement is satisfied (avoids the auto-refund
// chargeback path).
exports.verifyCoinPurchase = (0, https_1.onCall)({ region: constants_1.REGION, secrets: ["GOOGLE_PLAY_SERVICE_ACCOUNT"] }, async (request) => {
    var _a, _b, _c, _d, _e, _f, _g;
    const uid = (_a = request.auth) === null || _a === void 0 ? void 0 : _a.uid;
    if (!uid) {
        throw new https_1.HttpsError("unauthenticated", "Must be logged in");
    }
    const { productId, purchaseToken } = request.data;
    if (!productId ||
        typeof productId !== "string" ||
        !purchaseToken ||
        typeof purchaseToken !== "string") {
        throw new https_1.HttpsError("invalid-argument", "productId and purchaseToken are required");
    }
    // ── 1. Idempotency check on purchaseToken ───────────────────
    // The Play purchaseToken is globally unique per purchase. Using
    // it as the dedupe key means a legitimate retry from the client
    // (network blip after Play returned) lands here a second time
    // and exits early without re-running the Play round-trip or
    // re-crediting.
    const existingTx = await db
        .collection("wallet_transactions")
        .where("purchaseToken", "==", purchaseToken)
        .limit(1)
        .get();
    if (!existingTx.empty) {
        // Already credited. Re-attempt consume in case the original
        // consumeProduct call after credit silently failed (Play API
        // transient, network blip) — without this the purchaseStream
        // would keep re-delivering this token on every app launch and
        // the user would hit ITEM_ALREADY_OWNED on any new buy of the
        // same SKU. consumeProduct is idempotent on the Play side
        // (its own error filter swallows "already consumed"). The
        // outer try/catch is purely defensive: we never want a retry
        // attempt on the already-credited path to FAIL the request —
        // the user is entitled to their existing balance regardless of
        // whether this stuck-purchase rescue succeeds.
        try {
            await (0, playVerify_1.consumeProduct)({ productId, purchaseToken });
        }
        catch (err) {
            console.error("[verifyCoinPurchase] idempotent consume rescue failed:", err instanceof Error ? err.message : String(err));
        }
        const userDoc = await db.doc(`users/${uid}`).get();
        return {
            newBalance: Number((_c = (_b = userDoc.data()) === null || _b === void 0 ? void 0 : _b.coinBalance) !== null && _c !== void 0 ? _c : 0),
            alreadyProcessed: true,
        };
    }
    // ── 2. Verify with Google Play ──────────────────────────────
    // Throws HttpsError on any failure (network, invalid token,
    // purchaseState != 0). Returns the purchase resource on success.
    await (0, playVerify_1.verifyProductPurchase)({ productId, purchaseToken });
    // ── 3. Resolve pack from Firestore ──────────────────────────
    // The store catalog supplies the user-facing price; the pack
    // doc is the authoritative source for the coin count we grant.
    // Never derive the grant from the amount paid — local currency
    // amounts make that unsafe, and the productId is the verified
    // contract from the Play response.
    const packId = productIdToPackId(productId);
    if (!packId) {
        throw new https_1.HttpsError("failed-precondition", "unknown_or_inactive_pack");
    }
    const packDoc = await db
        .doc(`app_config/coin_packs/packs/${packId}`)
        .get();
    if (!packDoc.exists) {
        throw new https_1.HttpsError("failed-precondition", "unknown_or_inactive_pack");
    }
    const packData = (_d = packDoc.data()) !== null && _d !== void 0 ? _d : {};
    if (packData.isActive !== true) {
        throw new https_1.HttpsError("failed-precondition", "unknown_or_inactive_pack");
    }
    const coins = Number(packData.coins);
    if (!Number.isFinite(coins) || coins <= 0) {
        throw new https_1.HttpsError("internal", "Invalid coins in pack config");
    }
    const priceRupees = Number((_e = packData.price) !== null && _e !== void 0 ? _e : 0);
    // ── 4. Credit + record + notify atomically ─────────────────
    // creditCoins runs the exact same batch the legacy Razorpay path
    // ran (balance increment + wallet_transactions row + inbox
    // notification + push), plus stamps the new provider/token/
    // productId fields on the ledger row via ledgerExtra.
    let newBalance;
    try {
        const credited = await (0, creditCoins_1.creditCoins)({
            uid,
            coins,
            packId,
            amountPaidRupees: priceRupees,
            // Drives the atomic purchases/{token} create-guard inside the
            // credit batch — the deterministic dedupe that stops two
            // concurrent calls from both crediting this token.
            purchaseToken,
            ledgerExtra: {
                provider: "play",
                purchaseToken,
                productId,
            },
        });
        newBalance = credited.newBalance;
    }
    catch (err) {
        // A concurrent verify for the SAME token won the race and
        // already credited — the create-guard made this batch fail with
        // ALREADY_EXISTS. The user has their coins; treat as idempotent
        // success rather than surfacing an error. Best-effort consume,
        // then return the live balance.
        if (isAlreadyExists(err)) {
            try {
                await (0, playVerify_1.consumeProduct)({ productId, purchaseToken });
            }
            catch (consumeErr) {
                console.error("[verifyCoinPurchase] post-race consume rescue failed:", consumeErr instanceof Error ?
                    consumeErr.message :
                    String(consumeErr));
            }
            const userDoc = await db.doc(`users/${uid}`).get();
            return {
                newBalance: Number((_g = (_f = userDoc.data()) === null || _f === void 0 ? void 0 : _f.coinBalance) !== null && _g !== void 0 ? _g : 0),
                alreadyProcessed: true,
            };
        }
        throw err;
    }
    // ── 5. Consume on Play ──────────────────────────────────────
    // Marks the consumable as spent (so it can be repurchased) AND
    // implicitly acknowledges the purchase, avoiding the 3-day
    // auto-refund. Best-effort — failures are logged inside
    // consumeProduct, never re-thrown. The credit has already
    // landed; a retried verify will short-circuit on idempotency
    // and (importantly) not re-credit.
    await (0, playVerify_1.consumeProduct)({ productId, purchaseToken });
    return { newBalance, alreadyProcessed: false };
});
//# sourceMappingURL=verifyCoinPurchase.js.map