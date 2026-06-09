// Google Play Billing verification helpers.
//
// Authenticates to the Android Publisher API via the service-account
// JSON from the GOOGLE_PLAY_SERVICE_ACCOUNT secret (declared on each
// callable that uses these helpers). The JWT client is cached at
// module scope so warm invocations don't re-parse the secret or
// re-run the auth handshake.
//
// Scope: this file deals ONLY with the Google API round-trip. It
// does not touch Firestore, does not credit anything, does not know
// about coin packs. The callable that orchestrates the migration
// (verifyCoinPurchase) layers the business logic on top.

import {HttpsError} from "firebase-functions/v2/https";
import {google, androidpublisher_v3} from "googleapis";

// Hard-coded to keep us off the per-call lookup path. Mirrors the
// applicationId in android/app/build.gradle.kts. Changing this
// without updating the Play console listing would resolve to a
// "package not found" from Google.
const PACKAGE_NAME = "com.gospelvox.gospel_vox";
const ANDROID_PUBLISHER_SCOPE =
  "https://www.googleapis.com/auth/androidpublisher";

let cachedClient: androidpublisher_v3.Androidpublisher | undefined;

function getAndroidPublisher(): androidpublisher_v3.Androidpublisher {
  if (cachedClient) return cachedClient;

  const raw = process.env.GOOGLE_PLAY_SERVICE_ACCOUNT;
  if (!raw) {
    // Misconfiguration: the secret wasn't attached to the function.
    // Fail loudly rather than silently skipping verification.
    throw new HttpsError(
      "failed-precondition",
      "Play verification not configured on the server",
    );
  }

  let credentials: {client_email?: string; private_key?: string};
  try {
    credentials = JSON.parse(raw);
  } catch (_) {
    throw new HttpsError(
      "internal",
      "Play service account secret is not valid JSON",
    );
  }

  if (!credentials.client_email || !credentials.private_key) {
    throw new HttpsError(
      "internal",
      "Play service account secret is missing required fields",
    );
  }

  const auth = new google.auth.JWT({
    email: credentials.client_email,
    key: credentials.private_key,
    scopes: [ANDROID_PUBLISHER_SCOPE],
  });

  cachedClient = google.androidpublisher({version: "v3", auth});
  return cachedClient;
}

// Verifies a one-time product purchase with Google Play.
//
// Returns the underlying purchase resource on success. A successful
// resolve is the cryptographic substitute for the Razorpay HMAC
// signature check — Google's API requires our private key, so a
// tampered client cannot fabricate a purchaseToken that resolves to
// a different productId or purchaseState than reality.
//
// `purchaseState` semantics (per Android Publisher API):
//   0 → Purchased
//   1 → Canceled
//   2 → Pending (deferred payment, voucher pending settlement, etc.)
//
// We treat ONLY state=0 as creditable. Pending purchases come back
// later via a fresh client call when the user completes payment;
// canceled ones never become valid.
export async function verifyProductPurchase(args: {
  productId: string;
  purchaseToken: string;
}): Promise<androidpublisher_v3.Schema$ProductPurchase> {
  const client = getAndroidPublisher();

  let purchase: androidpublisher_v3.Schema$ProductPurchase;
  try {
    const res = await client.purchases.products.get({
      packageName: PACKAGE_NAME,
      productId: args.productId,
      token: args.purchaseToken,
    });
    purchase = res.data;
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    throw new HttpsError(
      "internal",
      `Could not verify purchase with Google Play: ${msg}`,
    );
  }

  if (purchase.purchaseState !== 0) {
    throw new HttpsError("failed-precondition", "purchase_not_valid");
  }

  return purchase;
}

// Consumes a one-time product after we've granted the entitlement.
//
// Two roles, one call:
//   1. Marks the consumable as "spent" so the user can repurchase
//      the same product later (without this, Play refuses a second
//      purchase of an un-consumed item — the user buys, gets coins,
//      then sees the next buy of the same pack fail).
//   2. Satisfies Google's 3-day acknowledgement requirement.
//      Consuming an item implicitly acknowledges it; without one or
//      the other, Play auto-refunds the user 72 hours later and we
//      get a chargeback against the credit we already issued.
//
// Best-effort: failures here are swallowed because the user-facing
// credit has already landed in the Firestore batch. A second call
// against an already-consumed token errors with a recognisable
// message which we treat as success (concurrent calls race).
export async function consumeProduct(args: {
  productId: string;
  purchaseToken: string;
}): Promise<void> {
  const client = getAndroidPublisher();
  try {
    await client.purchases.products.consume({
      packageName: PACKAGE_NAME,
      productId: args.productId,
      token: args.purchaseToken,
    });
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    const lower = msg.toLowerCase();
    if (
      lower.includes("already consumed") ||
      lower.includes("already acknowledged") ||
      lower.includes("already been consumed") ||
      lower.includes("already been acknowledged")
    ) {
      return;
    }
    // Unknown errors: log but don't throw. The credit has already
    // landed; refusing to acknowledge would just mean Google auto-
    // refunds in 72h. That's worth logging loudly so the operator
    // notices, but it must not roll back the (already-committed)
    // ledger write or surface a confusing error to the user.
    console.error("[playVerify] consume failed:", msg);
  }
}
