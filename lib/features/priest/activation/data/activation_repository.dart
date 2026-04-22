// Talks to the two activation Cloud Functions + the settings doc.
//
// The flow mirrors the wallet coin-purchase flow intentionally:
//   1. createActivationOrder → server-signed Razorpay order
//   2. client opens Razorpay checkout
//   3. verifyActivationFee → HMAC check + flip isActivated
// Skipping step 1 would break the entire "prove this payment is
// genuine" chain, so the repo surfaces both callables side by side
// and the cubit is the one that decides when to call each.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';

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
}
