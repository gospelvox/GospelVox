// State machine for the session-history list. The Loaded state holds
// both the full list and the type-filtered slice so the filter chips
// can flip without a refetch — the unfiltered list is the cubit's
// source of truth for totals (we never want a "Voice only" filter to
// shrink the totalSpent / totalEarned summary).

import 'package:gospel_vox/features/shared/data/session_model.dart';

sealed class SessionHistoryState {
  const SessionHistoryState();
}

class SessionHistoryInitial extends SessionHistoryState {
  const SessionHistoryInitial();
}

class SessionHistoryLoading extends SessionHistoryState {
  const SessionHistoryLoading();
}

class SessionHistoryLoaded extends SessionHistoryState {
  final List<SessionModel> allSessions;
  final List<SessionModel> filtered;
  // 'all' | 'chat' | 'voice'
  final String activeFilter;

  SessionHistoryLoaded({
    required this.allSessions,
    List<SessionModel>? filtered,
    this.activeFilter = 'all',
  }) : filtered = filtered ?? allSessions;

  int get totalSessions => allSessions.length;

  // Totals are deliberately computed from the unfiltered list so
  // the summary card doesn't change when the user flips between
  // All/Chat/Voice — that would feel like the filter is hiding
  // earnings rather than just narrowing the rows.
  int get totalSpent => allSessions
      .where((s) => s.status == 'completed')
      .fold(0, (sum, s) => sum + s.totalCharged);

  int get totalEarned => allSessions
      .where((s) => s.status == 'completed')
      .fold(0, (sum, s) => sum + s.priestEarnings);

  SessionHistoryLoaded copyWith({
    List<SessionModel>? allSessions,
    List<SessionModel>? filtered,
    String? activeFilter,
  }) =>
      SessionHistoryLoaded(
        allSessions: allSessions ?? this.allSessions,
        filtered: filtered ?? this.filtered,
        activeFilter: activeFilter ?? this.activeFilter,
      );
}

class SessionHistoryError extends SessionHistoryState {
  final String message;
  const SessionHistoryError(this.message);
}
