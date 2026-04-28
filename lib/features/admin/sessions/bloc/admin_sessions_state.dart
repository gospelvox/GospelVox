// States for the admin session monitor. Sealed so missing variants
// fail at analyze time instead of as a blank screen in prod.

import 'package:gospel_vox/features/admin/sessions/data/admin_session_model.dart';

sealed class AdminSessionsState {}

class AdminSessionsInitial extends AdminSessionsState {}

class AdminSessionsLoading extends AdminSessionsState {}

class AdminSessionsLoaded extends AdminSessionsState {
  // The current tab's payload. The cubit reloads on tab switch
  // (the tabs share neither queries nor result shapes) so we
  // don't carry all three lists in state at once.
  final List<AdminSessionModel> sessions;
  // 'active' | 'completed' | 'all' — driven from the tab. Held in
  // state so the UI can derive empty-state copy without re-asking
  // the cubit.
  final String filter;
  // Live count for the Active tab badge — kept separate from
  // `sessions` because it updates from the same active stream
  // even when the user is on a different tab.
  final int activeCount;

  AdminSessionsLoaded({
    required this.sessions,
    required this.filter,
    this.activeCount = 0,
  });

  AdminSessionsLoaded copyWith({
    List<AdminSessionModel>? sessions,
    String? filter,
    int? activeCount,
  }) {
    return AdminSessionsLoaded(
      sessions: sessions ?? this.sessions,
      filter: filter ?? this.filter,
      activeCount: activeCount ?? this.activeCount,
    );
  }
}

class AdminSessionsError extends AdminSessionsState {
  final String message;
  AdminSessionsError(this.message);
}
