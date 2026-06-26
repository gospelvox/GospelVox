// Settings repository — reads/writes app_config/settings in Firestore

import 'package:cloud_firestore/cloud_firestore.dart';

class SettingsRepository {
  final _ref = FirebaseFirestore.instance.collection('app_config').doc('settings');

  Future<Map<String, dynamic>> getSettings() async {
    final snap = await _ref.get().timeout(const Duration(seconds: 10));
    return snap.data() ?? {};
  }

  Future<void> saveSettings(Map<String, dynamic> data) async {
    // set(merge:true), NOT update(): update() throws NOT_FOUND when the
    // app_config/settings doc doesn't exist yet (fresh project, or it
    // was never seeded), which surfaced to the admin as a blanket
    // "Failed to save changes". set+merge creates the doc on first save
    // and merges thereafter, so the very first config save works.
    await _ref.set(
      {
        ...data,
        'updatedAt': FieldValue.serverTimestamp(),
      },
      SetOptions(merge: true),
    ).timeout(const Duration(seconds: 10));
  }
}
