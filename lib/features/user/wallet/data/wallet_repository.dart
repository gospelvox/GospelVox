import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:gospel_vox/features/admin/settings/data/coin_pack_model.dart';

class WalletRepository {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseFunctions _functions =
      FirebaseFunctions.instanceFor(region: 'asia-south1');

  // In-memory pack cache. Coin packs change ~once a quarter at most
  // (admin tweaks pricing), but the recharge sheet opens dozens of
  // times in a single session — caching makes the second-onward sheet
  // open render instantly with content instead of a 200-400 ms
  // shimmer. TTL keeps the cache fresh enough for pricing updates
  // mid-session.
  static List<CoinPackModel>? _cachedPacks;
  static DateTime? _cachedPacksAt;
  static const Duration _packsTtl = Duration(minutes: 15);

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

  // Synchronous cache peek for the recharge sheet's instant-render
  // path. Returns null when the cache is empty or stale; the sheet
  // then renders shimmer + kicks off `getCoinPacks()` like before.
  List<CoinPackModel>? getCachedCoinPacks() {
    final at = _cachedPacksAt;
    if (_cachedPacks == null || at == null) return null;
    if (DateTime.now().difference(at) > _packsTtl) return null;
    return _cachedPacks;
  }

  // Get all active coin packs ordered by 'order' field. Result is
  // cached for `_packsTtl`; the next call within that window returns
  // immediately from memory.
  Future<List<CoinPackModel>> getCoinPacks() async {
    final cached = getCachedCoinPacks();
    if (cached != null) return cached;

    final snap = await _firestore
        .collection('app_config')
        .doc('coin_packs')
        .collection('packs')
        .orderBy('order')
        .get()
        .timeout(const Duration(seconds: 10));
    final packs = snap.docs
        .where((doc) => doc.data()['isActive'] == true)
        .map((doc) => CoinPackModel.fromFirestore(doc.id, doc.data()))
        .toList();
    _cachedPacks = packs;
    _cachedPacksAt = DateTime.now();
    return packs;
  }

  // Verifies a Google Play purchase token against the
  // verifyCoinPurchase Cloud Function. The server resolves the coin
  // count from the pack doc keyed off productId and credits
  // server-side — this client NEVER credits coins locally. Throws
  // FirebaseFunctionsException on server-side rejection; callers
  // should handle the stable code/message contract documented on
  // the server.
  Future<VerifyCoinPurchaseResult> verifyCoinPurchase({
    required String productId,
    required String purchaseToken,
  }) async {
    final callable = _functions.httpsCallable('verifyCoinPurchase');
    final result = await callable.call({
      'productId': productId,
      'purchaseToken': purchaseToken,
    }).timeout(const Duration(seconds: 20));
    final data = Map<String, dynamic>.from(result.data as Map);
    return VerifyCoinPurchaseResult(
      newBalance: (data['newBalance'] as num?)?.toInt() ?? 0,
      alreadyProcessed: data['alreadyProcessed'] as bool? ?? false,
    );
  }
}

class VerifyCoinPurchaseResult {
  final int newBalance;
  final bool alreadyProcessed;

  const VerifyCoinPurchaseResult({
    required this.newBalance,
    required this.alreadyProcessed,
  });
}
