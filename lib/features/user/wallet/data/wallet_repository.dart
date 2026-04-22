import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:gospel_vox/features/admin/settings/data/coin_pack_model.dart';

class WalletRepository {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseFunctions _functions = FirebaseFunctions.instanceFor(region: 'asia-south1');

  // Stream of user's coin balance (real-time updates)
  Stream<int> watchBalance(String uid) {
    return _firestore
        .doc('users/$uid')
        .snapshots()
        .map((snap) => (snap.data()?['coinBalance'] as num?)?.toInt() ?? 0);
  }

  // Get current balance (one-time read)
  Future<int> getBalance(String uid) async {
    final doc = await _firestore
        .doc('users/$uid')
        .get()
        .timeout(const Duration(seconds: 10));
    return (doc.data()?['coinBalance'] as num?)?.toInt() ?? 0;
  }

  // Get all active coin packs ordered by 'order' field
  Future<List<CoinPackModel>> getCoinPacks() async {
    final snap = await _firestore
        .collection('app_config')
        .doc('coin_packs')
        .collection('packs')
        .orderBy('order')
        .get()
        .timeout(const Duration(seconds: 10));
    return snap.docs
        .where((doc) => doc.data()['isActive'] == true)
        .map((doc) => CoinPackModel.fromFirestore(doc.id, doc.data()))
        .toList();
  }

  // Check if user has ever purchased coins (for welcome offer)
  Future<bool> hasEverPurchased(String uid) async {
    final snap = await _firestore
        .collection('wallet_transactions')
        .where('userId', isEqualTo: uid)
        .where('type', isEqualTo: 'purchase')
        .limit(1)
        .get()
        .timeout(const Duration(seconds: 10));
    return snap.docs.isNotEmpty;
  }

  // Get welcome offer settings
  Future<Map<String, int>> getWelcomeOffer() async {
    final doc = await _firestore
        .doc('app_config/settings')
        .get()
        .timeout(const Duration(seconds: 10));
    final data = doc.data() ?? {};
    return {
      'coins': (data['welcomeOfferCoins'] as num?)?.toInt() ?? 100,
      'price': (data['welcomeOfferPrice'] as num?)?.toInt() ?? 29,
    };
  }

  // Creates a Razorpay order on the server. Returns the order id
  // and the authoritative amount (in paise) to pass to the checkout
  // sheet. The CF looks up the price from Firestore, so the client
  // cannot fabricate a cheaper order for a more expensive pack.
  Future<CoinOrder> createCoinOrder({required String packId}) async {
    final callable = _functions.httpsCallable('createCoinOrder');
    final result = await callable
        .call({'packId': packId})
        .timeout(const Duration(seconds: 15));
    final data = Map<String, dynamic>.from(result.data as Map);
    return CoinOrder(
      orderId: data['orderId'] as String,
      amountPaise: (data['amount'] as num).toInt(),
      coins: (data['coins'] as num).toInt(),
      priceRupees: (data['priceRupees'] as num).toInt(),
    );
  }

  // Verifies the signature Razorpay returned on successful payment,
  // then credits coins. The `packId` is redundant (the server also
  // has it in the order's notes) but passing it lets the CF reject
  // a payment that was somehow redirected to a different pack.
  Future<int> verifyCoinPurchase({
    required String razorpayPaymentId,
    required String razorpayOrderId,
    required String razorpaySignature,
    required String packId,
  }) async {
    final callable = _functions.httpsCallable('verifyCoinPurchase');
    final result = await callable.call({
      'razorpayPaymentId': razorpayPaymentId,
      'razorpayOrderId': razorpayOrderId,
      'razorpaySignature': razorpaySignature,
      'packId': packId,
    }).timeout(const Duration(seconds: 15));
    final data = Map<String, dynamic>.from(result.data as Map);
    return (data['newBalance'] as num?)?.toInt() ?? 0;
  }
}

class CoinOrder {
  final String orderId;
  final int amountPaise;
  final int coins;
  final int priceRupees;

  const CoinOrder({
    required this.orderId,
    required this.amountPaise,
    required this.coins,
    required this.priceRupees,
  });
}
