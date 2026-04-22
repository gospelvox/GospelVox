// Wraps the Razorpay Flutter SDK with clean lifecycle semantics.
//
// Why a fresh instance per widget instead of a singleton:
// Razorpay.on() appends listeners — calling it twice on the same
// instance (e.g., after a hot reload or revisit) registers the
// handler twice and fires callbacks twice. Giving each widget its
// own instance + disposing it in `dispose()` keeps the listener
// set clean without needing manual off() calls.

import 'package:flutter/foundation.dart';
import 'package:razorpay_flutter/razorpay_flutter.dart';

import 'package:gospel_vox/core/config/payment_config.dart';

class RazorpayService {
  Razorpay? _razorpay;

  // Callbacks set by the caller before opening checkout. Kept
  // nullable so the caller can reset them on dispose without
  // leaking closures that capture BuildContext.
  void Function(PaymentSuccessResponse)? onSuccess;
  void Function(PaymentFailureResponse)? onFailure;
  void Function(ExternalWalletResponse)? onWallet;

  void init() {
    _razorpay = Razorpay();
    _razorpay!.on(Razorpay.EVENT_PAYMENT_SUCCESS, _handleSuccess);
    _razorpay!.on(Razorpay.EVENT_PAYMENT_ERROR, _handleFailure);
    _razorpay!.on(Razorpay.EVENT_EXTERNAL_WALLET, _handleWallet);
  }

  void _handleSuccess(PaymentSuccessResponse response) {
    onSuccess?.call(response);
  }

  void _handleFailure(PaymentFailureResponse response) {
    onFailure?.call(response);
  }

  void _handleWallet(ExternalWalletResponse response) {
    onWallet?.call(response);
  }

  // Opens the Razorpay checkout sheet.
  //
  // `razorpayOrderId` is the `order_<xxx>` id returned from the
  // createCoinOrder Cloud Function. Passing it here is what causes
  // Razorpay to return `razorpay_signature` in the success callback
  // — without it, the server has no cryptographic way to verify the
  // payment, so the entire secure-flow collapses into "trust the
  // client", which is not acceptable for money.
  //
  // Passing `amountInPaise` (not rupees) so callers coming from a CF
  // response can forward the authoritative amount Razorpay already
  // quoted, instead of risking a rupee-vs-paise mismatch.
  void openCheckout({
    required String razorpayOrderId,
    required int amountInPaise,
    required String description,
    required String userEmail,
    required String userName,
    String? userPhone,
  }) {
    final razorpay = _razorpay;
    if (razorpay == null) {
      debugPrint('[Razorpay] openCheckout called before init()');
      return;
    }

    final options = <String, dynamic>{
      'key': PaymentConfig.razorpayKeyId,
      'order_id': razorpayOrderId,
      'amount': amountInPaise,
      'currency': 'INR',
      'name': PaymentConfig.companyName,
      'description': description,
      'prefill': <String, dynamic>{
        'email': userEmail,
        'contact': userPhone ?? '',
        'name': userName,
      },
      'theme': <String, dynamic>{
        'color': PaymentConfig.checkoutThemeHex,
      },
      // Do NOT pass `external.wallets`. That key hands the payment
      // off to the merchant (us) after Razorpay closes its sheet —
      // we'd need native PhonePe/Paytm/GPay SDKs wired through
      // onExternalWallet to actually complete the transaction, and
      // we don't have those. Without merchant-side integration,
      // tapping an external wallet just silently closes the sheet.
      //
      // UPI (which covers PhonePe/GPay/Paytm/BHIM/any UPI app) is
      // already offered by Razorpay's built-in checkout — no config
      // needed, and Razorpay completes the flow end-to-end in-sheet.
    };

    try {
      razorpay.open(options);
    } catch (e) {
      debugPrint('[Razorpay] open() failed: $e');
    }
  }

  // Must be called when the widget using this service is disposed.
  // Without this, the native Razorpay activity keeps references to
  // the handler closures, which in turn capture the old BuildContext
  // and leak the entire page.
  void dispose() {
    _razorpay?.clear();
    _razorpay = null;
    onSuccess = null;
    onFailure = null;
    onWallet = null;
  }
}
