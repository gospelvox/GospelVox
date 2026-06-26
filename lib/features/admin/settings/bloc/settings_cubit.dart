// Settings cubit — loads and saves admin configuration

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:gospel_vox/features/admin/settings/bloc/settings_state.dart';
import 'package:gospel_vox/features/admin/settings/data/settings_repository.dart';

class SettingsCubit extends Cubit<SettingsState> {
  final SettingsRepository _repository;

  SettingsCubit(this._repository) : super(SettingsInitial());

  Future<void> loadSettings() async {
    try {
      emit(SettingsLoading());
      final data = await _repository.getSettings();
      emit(SettingsLoaded(data));
    } on TimeoutException {
      emit(SettingsError('Taking too long. Check connection.'));
    } catch (e) {
      debugPrint('[Settings] load failed: $e');
      emit(SettingsError('Failed to load settings.'));
    }
  }

  Future<void> saveSettings(Map<String, dynamic> data) async {
    try {
      emit(SettingsSaving());
      await _repository.saveSettings(data);
      emit(SettingsSaved());
      await loadSettings();
    } on TimeoutException {
      emit(SettingsError('Save timed out. Try again.'));
    } on FirebaseException catch (e) {
      // Surface the actual cause instead of a blanket failure — a
      // permission-denied here almost always means the signed-in
      // account's users/{uid}.role isn't 'admin', which the generic
      // message hid completely.
      debugPrint('[Settings] save failed: ${e.code} — ${e.message}');
      emit(SettingsError(
        e.code == 'permission-denied'
            ? 'Not allowed. Make sure you are signed in as an admin.'
            : 'Failed to save settings. (${e.code})',
      ));
    } catch (e) {
      debugPrint('[Settings] save failed: $e');
      emit(SettingsError('Failed to save settings.'));
    }
  }
}
