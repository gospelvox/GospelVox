// ═══════════════════════════════════════════
// RAZORPAY CONFIGURATION
// ═══════════════════════════════════════════
//
// HOW TO GET YOUR TEST KEY:
// 1. Go to https://dashboard.razorpay.com/
// 2. Sign up / Log in
// 3. Switch to TEST mode (toggle at top left)
// 4. Go to Settings → API Keys → Generate Test Key
// 5. Copy the Key ID (starts with rzp_test_)
// 6. Paste below replacing the existing key
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
// 3. Replace rzp_test_ key below with the rzp_live_ key
// 4. Update functions/.env RAZORPAY_KEY_ID to match
// 5. For the LIVE secret, migrate to Firebase Secrets Manager:
//      firebase functions:secrets:set RAZORPAY_KEY_SECRET
//    then attach `secrets: ["RAZORPAY_KEY_SECRET"]` to the onCall
//    options in createCoinOrder.ts / verifyCoinPurchase.ts. This
//    keeps the live secret out of plaintext `.env`.
//
// KEY SPLIT (DO NOT CONFUSE):
//   KEY_ID     → public identifier, safe on the client (this file).
//   KEY_SECRET → signs payments, lives in functions/.env only.
//                A leaked secret can drain the merchant account.
// ═══════════════════════════════════════════

class PaymentConfig {
  PaymentConfig._();

  // Razorpay TEST key — replace with your own from the dashboard.
  // Must stay in sync with functions/.env `RAZORPAY_KEY_ID`.
  static const String razorpayKeyId = 'rzp_test_Sfi6ecRbnuqcfW';

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
