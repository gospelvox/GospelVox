// ═══════════════════════════════════════════
// RAZORPAY CONFIGURATION
// ═══════════════════════════════════════════
//
// The Razorpay Key ID is environment-driven. The default (`rzp_test_…`)
// keeps debug builds working out of the box; production builds inject
// the live key at compile time:
//
//   flutter build appbundle --release \
//       --dart-define=RAZORPAY_KEY_ID=rzp_live_XXXXXXXX
//
// HOW TO GET YOUR TEST KEY:
// 1. https://dashboard.razorpay.com/ → switch to TEST mode
// 2. Settings → API Keys → Generate Test Key
// 3. Copy the Key ID (starts with rzp_test_) — paste below as the
//    `defaultValue` for local development.
//
// HOW TO TEST PAYMENTS:
//   Card:    4111 1111 1111 1111
//   Expiry:  Any future date (e.g., 12/29)
//   CVV:     Any 3 digits (e.g., 123)
//   OTP:     1234 for success, anything else for failure
//
// BEFORE LAUNCH:
// 1. Switch Razorpay dashboard to LIVE mode
// 2. Generate a LIVE API key
// 3. Pass it to the release build via --dart-define=RAZORPAY_KEY_ID=…
// 4. Update functions/.env RAZORPAY_KEY_ID to the same value
// 5. For the LIVE secret, migrate to Firebase Secrets Manager:
//      firebase functions:secrets:set RAZORPAY_KEY_SECRET
//    then attach `secrets: ["RAZORPAY_KEY_SECRET"]` to the onCall
//    options in createCoinOrder.ts / verifyCoinPurchase.ts. This
//    keeps the live secret out of plaintext `.env`.
//
// KEY SPLIT (DO NOT CONFUSE):
//   KEY_ID     → public identifier, safe on the client (this file).
//   KEY_SECRET → signs payments, lives on the server only.
//                A leaked secret can drain the merchant account.
// ═══════════════════════════════════════════

class PaymentConfig {
  PaymentConfig._();

  // Razorpay Key ID. Compile-time constant so it's inlined at build —
  // a release AAB built without --dart-define keeps the test key,
  // which is safe (test keys can't capture real money) but obviously
  // wrong in production. The CI job that runs `flutter build` is
  // responsible for passing the live key.
  static const String razorpayKeyId = String.fromEnvironment(
    'RAZORPAY_KEY_ID',
    defaultValue: 'rzp_test_Sfi6ecRbnuqcfW',
  );

  // True when the build is still on a test key — release builds that
  // forgot --dart-define can be detected at runtime (e.g. a debug
  // banner overlay) without exposing the key value itself.
  static bool get isTestKey => razorpayKeyId.startsWith('rzp_test_');

  // Shown on the Razorpay checkout sheet so the user recognises who
  // they're paying — reduces cart abandonment vs. a raw amount.
  static const String companyName = 'Gospel Vox';
  static const String companyDescription = 'Coin Pack Purchase';

  // Razorpay expects amount in the smallest currency unit.
  // 1 INR = 100 paise, so multiply rupees by 100.
  static int toPaise(int rupees) => rupees * 100;

  // Hex string form of primaryBrown — the Razorpay SDK reads the
  // theme colour as a String, so the hex literal below is the one
  // actually wired into openCheckout. The int form is kept for any
  // Flutter widget that needs the same tint programmatically.
  static const String checkoutThemeHex = '#6B3A2A';
  static const int checkoutColor = 0xFF6B3A2A;
}
