// Coin packs repository — CRUD for app_config/coin_packs/packs

import 'package:cloud_firestore/cloud_firestore.dart';

import 'package:gospel_vox/features/admin/settings/data/coin_pack_model.dart';

class CoinPacksRepository {
  final _packsRef = FirebaseFirestore.instance
      .collection('app_config')
      .doc('coin_packs')
      .collection('packs');

  Future<List<CoinPackModel>> getPacks() async {
    final snap =
        await _packsRef.orderBy('order').get().timeout(const Duration(seconds: 10));
    return snap.docs
        .map((d) => CoinPackModel.fromFirestore(d.id, d.data()))
        .toList();
  }

  Future<void> addPack(CoinPackModel pack) async {
    await _packsRef.doc('pack_${pack.coins}').set({
      ...pack.toFirestore(),
      'createdAt': FieldValue.serverTimestamp(),
    }).timeout(const Duration(seconds: 10));
  }

  Future<void> updatePack(CoinPackModel pack) async {
    await _packsRef
        .doc(pack.id)
        .update(pack.toFirestore())
        .timeout(const Duration(seconds: 10));
  }

  Future<void> toggleActive(String packId, bool isActive) async {
    await _packsRef
        .doc(packId)
        .update({'isActive': isActive}).timeout(const Duration(seconds: 10));
  }

  Future<void> setPopular(String packId) async {
    final batch = FirebaseFirestore.instance.batch();
    final allPacks = await _packsRef.get();
    for (final doc in allPacks.docs) {
      batch.update(doc.reference, {'isPopular': doc.id == packId});
    }
    await batch.commit().timeout(const Duration(seconds: 10));
  }

  Future<void> deletePack(String packId) async {
    await _packsRef.doc(packId).delete().timeout(const Duration(seconds: 10));
  }
}
