// Talks to the activation Cloud Functions + the settings doc.
//
// Play Billing flow (live):
//   1. Cubit calls verifyActivationPurchase below with the
//      productId + Play purchaseToken collected after the Play
//      sheet returns success.
//   2. The CF acknowledges (NOT consumes — activation is a
//      non-consumable, permanent entitlement) on the Play side
//      and flips priests/{uid}.isActivated.
//
// Razorpay flow (legacy, kept until Step 5 deletes it):
//   1. createActivationOrder → server-signed Razorpay order
//   2. client opens Razorpay checkout
//   3. verifyActivationFee → HMAC check + flip isActivated
// The two Razorpay methods (createOrder + verifyPayment) below are
// orphaned — no live caller — but kept to avoid touching the
// retired CF wiring before its dedicated cleanup step.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';

import 'package:gospel_vox/core/services/iap_service.dart';

// Matches functions/src/config/constants.ts. Hard-coded because a
// region mismatch would surface as a confusing "function not found"
// rather than a clear error.
const String _kRegion = 'asia-south1';

// Result of createActivationOrder — everything the client needs to
// open Razorpay checkout. `amountPaise` is authoritative; we never
// trust the client's view of the price.
class ActivationOrder {
  final String orderId;
  final int amountPaise;
  final int priceRupees;

  const ActivationOrder({
    required this.orderId,
    required this.amountPaise,
    required this.priceRupees,
  });
}

class ActivationRepository {
  FirebaseFunctions get _functions =>
      FirebaseFunctions.instanceFor(region: _kRegion);

  // Used by the paywall to render the "Activate for ₹X" button while
  // still loading. The CF also validates this value on the server —
  // an out-of-date client price can't actually underpay because
  // createActivationOrder pins the authoritative amount.
  Future<int> getActivationFee() async {
    final doc = await FirebaseFirestore.instance
        .doc('app_config/settings')
        .get()
        .timeout(const Duration(seconds: 10));
    return (doc.data()?['priestActivationFee'] as num?)?.toInt() ?? 500;
  }

  Future<ActivationOrder> createOrder() async {
    final result = await _functions
        .httpsCallable('createActivationOrder')
        .call()
        .timeout(const Duration(seconds: 15));

    final data = result.data as Map<Object?, Object?>;
    return ActivationOrder(
      orderId: data['orderId'] as String,
      amountPaise: (data['amount'] as num).toInt(),
      priceRupees: (data['priceRupees'] as num).toInt(),
    );
  }

  Future<void> verifyPayment({
    required String razorpayPaymentId,
    required String razorpayOrderId,
    required String razorpaySignature,
  }) async {
    await _functions
        .httpsCallable('verifyActivationFee')
        .call({
          'razorpayPaymentId': razorpayPaymentId,
          'razorpayOrderId': razorpayOrderId,
          'razorpaySignature': razorpaySignature,
        })
        .timeout(const Duration(seconds: 15));
  }

  // Adapter to the IapService verifier contract. Calls the
  // verifyActivationPurchase CF with the Play purchaseToken and
  // returns a `consume`-mode IapVerifyResult — activation is a
  // CONSUMABLE flow at the Play layer (the server's
  // priests/{uid}.isActivated flag is the source of truth for the
  // entitlement). Consuming releases the SKU at Play so different
  // Firebase users on the same Play account can each pay for their
  // own activation — without consume, Play would block any second
  // activation on the account with ITEM_ALREADY_OWNED.
  //
  // Reinstall / fresh-device recovery does NOT depend on Play
  // remembering activation: the app reads isActivated from
  // Firestore on launch, and an already-activated priest never
  // reaches the paywall. Per-entitlement state lives on the
  // server, not on Play.
  //
  // The CF returns {success, isActivated, alreadyProcessed}.
  // `isActivated` is true on both fresh activation and idempotent
  // re-delivery (the CF guarantees this). The `?? true` is a
  // belt-and-suspenders fallback for an unexpectedly-shaped
  // response — if the CF's contract ever changes shape, the worst
  // outcome is we treat the response as activated, which is what
  // the user is paying for.
  Future<IapVerifyResult> verifyActivationPurchase({
    required String productId,
    required String purchaseToken,
  }) async {
    final result = await _functions
        .httpsCallable('verifyActivationPurchase')
        .call({
          'productId': productId,
          'verificationData': purchaseToken,
        })
        .timeout(const Duration(seconds: 20));
    final data = Map<String, dynamic>.from(result.data as Map);
    return IapVerifyResult(
      consumeMode: IapConsumeMode.consume,
      isActivated: data['isActivated'] as bool? ?? true,
    );
  }
}
