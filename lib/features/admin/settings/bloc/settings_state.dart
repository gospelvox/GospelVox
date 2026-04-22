// Settings states

sealed class SettingsState {}

class SettingsInitial extends SettingsState {}

class SettingsLoading extends SettingsState {}

class SettingsLoaded extends SettingsState {
  final Map<String, dynamic> data;
  SettingsLoaded(this.data);
}

class SettingsSaving extends SettingsState {}

class SettingsSaved extends SettingsState {}

class SettingsError extends SettingsState {
  final String message;
  SettingsError(this.message);
}
