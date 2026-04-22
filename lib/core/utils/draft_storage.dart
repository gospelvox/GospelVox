// Local draft persistence for the priest registration wizard.
//
// Registrations take 5-10 minutes of typing across 3 steps. If the
// phone rings, the screen dims, the OS kills the app for memory — any
// of that without a draft means the priest has to re-enter everything.
// We write to SharedPreferences after every completed step and wipe on
// successful submit. File paths are deliberately excluded (local paths
// don't survive an app restart), so only text data is preserved.

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

class DraftStorage {
  DraftStorage._();

  static const String _key = 'priest_registration_draft';

  static Future<void> saveDraft(Map<String, dynamic> data) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, jsonEncode(data));
    } catch (_) {
      // Draft save is advisory — never fail the wizard because
      // SharedPreferences had a hiccup.
    }
  }

  static Future<Map<String, dynamic>?> loadDraft() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final json = prefs.getString(_key);
      if (json == null) return null;
      final decoded = jsonDecode(json);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  static Future<void> clearDraft() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_key);
    } catch (_) {
      // Same rationale as save — don't throw.
    }
  }
}
