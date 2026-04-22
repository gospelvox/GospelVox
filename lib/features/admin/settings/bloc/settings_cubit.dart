// Settings cubit — loads and saves admin configuration

import 'dart:async';

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
    } catch (e) {
      debugPrint('[Settings] save failed: $e');
      emit(SettingsError('Failed to save settings.'));
    }
  }
}
