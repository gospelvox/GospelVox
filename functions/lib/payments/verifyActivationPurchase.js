"use strict";
// Verifies a Google Play purchase of the priest_activation
// product and flips priests/{uid}.isActivated = true.
//
// Activation is now a CONSUMABLE flow at the Play layer — the
// server is the source of truth for "is this priest activated"
// (via priests/{uid}.isActivated in Firestore). Play's role is
// purely the payment receipt. We CONSUME the token after credit
// so the same Play account can re-purchase activation for a
// DIFFERENT Firebase user (e.g. shared family device, fresh test
// priest on the same Play tester account). Without consume, Play
// would treat the SKU as "owned" forever and block any other
// priest signed into that Play account from activating —
// ITEM_ALREADY_OWNED on every retry.
//
// Reinstall recovery on a new device does NOT require Play to
// remember activation: the app reads `priests/{uid}.isActivated`
// from Firestore on launch, and a priest who's already activated
// never reaches the paywall. Per-entitlement state lives where
// it belongs — on the server, not on Play.
//
// Mirrors verifyCoinPurchase's structure, with three departures:
//   • Strict productId allowlist — exactly 'priest_activation'.
//     Anything else is rejected before we touch Play.
//   • CONSUME on the Play side (not acknowledge), to let
//     different Firebase users re-purchase on the same Play
//     account. See header above for why.
//   • Idempotency key is the new top-level `purchases/{token}`
//     collection rather than wallet_transactions. The activation
//     flow doesn't credit a wallet, so a dedicated dedupe doc keeps
//     the ledger clean and the dedupe explicit.
//
// Defences (in order):
//   1. Auth required.
//   2. Strict productId allowlist (early-fail before Play call).
//   3. Priest profile must exist and be `status === 'approved'`.
//   4. If priests/{uid}.isActivated === true → idempotent OK +
//      best-effort consume to release the SKU at Play even if an
//      earlier consume silently failed.
//   5. purchases/{purchaseToken} doc → if the token was already
//      processed for THIS priest, idempotent OK. If it was already
//      processed for a DIFFERENT priest, permission-denied — but
//      we still attempt a consume on the way out so the SKU is
//      released at Play (otherwise it stays "owned" forever and
//      blocks the rightful Play account holder from any other
//      activation purchase).
//   6. Play purchase verification (verifyProductPurchase). A
//      tampered client cannot fabricate a token that resolves to a
//      successful purchaseState=0 priest_activation purchase.
//
// After verification, atomically:
//   • flip priests/{uid}.isActivated = true + activatedAt
//   • mirror users/{uid}.isActivated = true (role-gated UI reads
//     from the user doc, not the priest doc)
//   • write purchases/{token} idempotency doc
//   • write a wallet_transactions audit row (kept for the admin
//     transactions view; mirrors the legacy verifyActivationFee
//     row shape)
//   • write a notifications inbox doc
// then CONSUME the Play purchase, then best-effort push the
// priest's device.
Object.defineProperty(exports, "__esModule", { value: true });
exports.verifyActivationPurchase = void 0;
const https_1 = require("firebase-functions/v2/https");
const admin = require("firebase-admin");
const constants_1 = require("../config/constants");
const playVerify_1 = require("./playVerify");
const sendPush_1 = require("../notifications/sendPush");
const db = admin.firestore();
const ACTIVATION_PRODUCT_ID = "priest_activation";
exports.verifyActivationPurchase = (0, https_1.onCall)({ region: constants_1.REGION, secrets: ["GOOGLE_PLAY_SERVICE_ACCOUNT"] }, async (request) => {
    var _a, _b, _c, _d, _e;
    const uid = (_a = request.auth) === null || _a === void 0 ? void 0 : _a.uid;
    if (!uid) {
        throw new https_1.HttpsError("unauthenticated", "Must be logged in");
    }
    const { productId, verificationData } = request.data;
    if (!productId ||
        typeof productId !== "string" ||
        !verificationData ||
        typeof verificationData !== "string") {
        throw new https_1.HttpsError("invalid-argument", "productId and verificationData are required");
    }
    // ── 1. Strict productId allowlist ───────────────────────────
    // Activation has exactly one SKU. A coin-pack token submitted
    // here must be rejected before we burn an Android Publisher
    // round-trip on it.
    if (productId !== ACTIVATION_PRODUCT_ID) {
        throw new https_1.HttpsError("failed-precondition", "Unsupported product for activation");
    }
    const purchaseToken = verificationData;
    // ── 2. Priest profile must exist and be approved ────────────
    // The legacy verifyActivationFee enforces both gates. Keeping
    // them here as defence-in-depth — without `status === 'approved'`
    // a rejected applicant could short-circuit moderation by paying
    // directly through Play.
    const priestRef = db.doc(`priests/${uid}`);
    const priestSnap = await priestRef.get();
    if (!priestSnap.exists) {
        throw new https_1.HttpsError("not-found", "Speaker profile not found");
    }
    const priestData = (_b = priestSnap.data()) !== null && _b !== void 0 ? _b : {};
    if (priestData.status !== "approved") {
        throw new https_1.HttpsError("failed-precondition", "Your application must be approved before activation");
    }
    // ── 3. Already-activated idempotent path ────────────────────
    // Possible in two scenarios: (a) legitimate retry from the
    // client after a network blip on the previous response, or
    // (b) priest activated via the legacy Razorpay flow before the
    // Play migration. In either case the entitlement is real; we
    // just need to consume the Play token so it doesn't stay
    // "owned" on the Play account (blocking other priests on the
    // same account from activating) and so Google doesn't auto-
    // refund it in 72h.
    if (priestData.isActivated === true) {
        try {
            await (0, playVerify_1.consumeProduct)({ productId, purchaseToken });
        }
        catch (err) {
            console.error("[verifyActivationPurchase] idempotent consume rescue failed:", err instanceof Error ? err.message : String(err));
        }
        return {
            success: true,
            isActivated: true,
            alreadyProcessed: true,
        };
    }
    // ── 4. purchases/{token} idempotency / replay check ─────────
    // The token is globally unique per Play purchase. The dedupe
    // doc lives at purchases/{token}; if it's present for THIS
    // priest, this is a retry — return OK. If it's present for
    // a DIFFERENT priest, the client is replaying someone else's
    // purchase token to activate themselves for free.
    const purchaseRef = db.doc(`purchases/${purchaseToken}`);
    const purchaseSnap = await purchaseRef.get();
    if (purchaseSnap.exists) {
        const existingUid = (_c = purchaseSnap.data()) === null || _c === void 0 ? void 0 : _c.userId;
        if (existingUid && existingUid !== uid) {
            // Cross-user replay attempt. Reject — we won't credit this
            // priest. But ALSO release the SKU at Play (defensive
            // consume) so the rightful Play account holder isn't stuck
            // with an owned-but-unusable SKU. The credit already
            // happened for `existingUid`; consuming here just frees
            // Play's ownership state for future purchases on this
            // account by any Firebase user.
            try {
                await (0, playVerify_1.consumeProduct)({ productId, purchaseToken });
            }
            catch (err) {
                console.error("[verifyActivationPurchase] cross-user rescue consume failed:", err instanceof Error ? err.message : String(err));
            }
            throw new https_1.HttpsError("permission-denied", "Purchase token already used by another user");
        }
        try {
            await (0, playVerify_1.consumeProduct)({ productId, purchaseToken });
        }
        catch (err) {
            console.error("[verifyActivationPurchase] idempotent consume rescue failed:", err instanceof Error ? err.message : String(err));
        }
        return {
            success: true,
            isActivated: true,
            alreadyProcessed: true,
        };
    }
    // ── 5. Verify with Google Play ──────────────────────────────
    // Throws HttpsError on any failure (network, invalid token,
    // wrong productId, purchaseState != 0).
    await (0, playVerify_1.verifyProductPurchase)({ productId, purchaseToken });
    // ── 6. Atomic: flip isActivated + audit + idempotency doc ──
    const batch = db.batch();
    batch.update(priestRef, {
        isActivated: true,
        activatedAt: admin.firestore.FieldValue.serverTimestamp(),
        activationPurchaseToken: purchaseToken,
    });
    // Mirror on users/{uid} so role-gated UI doesn't need a second
    // read to check activation. Admin SDK bypasses the locked-field
    // rule on this doc.
    const userRef = db.doc(`users/${uid}`);
    batch.update(userRef, {
        isActivated: true,
    });
    // Canonical purchase record. Doc id IS the purchaseToken so any
    // future replay attempt collides on the doc id and resolves
    // deterministically via step 4 above.
    batch.set(purchaseRef, {
        userId: uid,
        productId,
        kind: "priest_activation",
        provider: "play",
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    // Audit row — mirrors the legacy verifyActivationFee shape so
    // the admin transactions view continues to surface activations
    // alongside coin and bible-session rows. `amountPaid` is the
    // configured INR fee (not the user's local-currency Play
    // charge, which the Android Publisher API doesn't expose).
    const settingsDoc = await db.doc("app_config/settings").get();
    const feeRupees = Number((_e = (_d = settingsDoc.data()) === null || _d === void 0 ? void 0 : _d.priestActivationFee) !== null && _e !== void 0 ? _e : 500);
    const txRef = db.collection("wallet_transactions").doc();
    batch.set(txRef, {
        userId: uid,
        type: "activation_fee",
        provider: "play",
        productId,
        purchaseToken,
        amountPaid: feeRupees,
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
    // ── 7. Consume the activation purchase on Play ──────────────
    // Releases the SKU at Play so future activations on this Play
    // account work (e.g. a shared family device where a different
    // Firebase user signs in and needs to activate their own
    // priest profile). The server-side priests/{uid}.isActivated
    // flag is the persistent source of truth — Play's "ownership"
    // tracking is not used to remember activation. Best-effort:
    // a failure here is logged but does not roll back the
    // activation that has already landed in Firestore.
    await (0, playVerify_1.consumeProduct)({ productId, purchaseToken });
    // ── 8. Push the priest's device (best-effort, post-commit) ──
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
    return {
        success: true,
        isActivated: true,
        alreadyProcessed: false,
    };
});
//# sourceMappingURL=verifyActivationPurchase.js.map