// Settings repository — reads/writes app_config/settings in Firestore

import 'package:cloud_firestore/cloud_firestore.dart';

class SettingsRepository {
  final _ref = FirebaseFirestore.instance.collection('app_config').doc('settings');

  Future<Map<String, dynamic>> getSettings() async {
    final snap = await _ref.get().timeout(const Duration(seconds: 10));
    return snap.data() ?? {};
  }

  Future<void> saveSettings(Map<String, dynamic> data) async {
    await _ref.update({
      ...data,
      'updatedAt': FieldValue.serverTimestamp(),
    }).timeout(const Duration(seconds: 10));
  }
}
