// State machine for the session-history list. The Loaded state holds
// both the unified list and the type-filtered slice so the filter
// chips can flip without a refetch — the unfiltered list is the
// cubit's source of truth for totals (we never want a "Voice only"
// filter to shrink the totalSpent / totalEarned summary).
//
// Entries are HistoryEntry, a sealed type that wraps either a regular
// SessionModel (chat / voice) or a BibleSessionEntry (paid bible
// session attendance on the user side, hosted bible session on the
// priest side). Mixing them in one list lets the page render a single
// chronological history surface, with per-row chrome chosen by the
// renderer based on the variant.

import 'package:gospel_vox/features/shared/data/session_history_repository.dart';

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
  final List<HistoryEntry> allEntries;
  final List<HistoryEntry> filtered;
  // 'all' | 'chat' | 'voice' | 'bible'
  final String activeFilter;

  SessionHistoryLoaded({
    required this.allEntries,
    List<HistoryEntry>? filtered,
    this.activeFilter = 'all',
  }) : filtered = filtered ?? allEntries;

  int get totalSessions => allEntries.length;

  // Totals are computed from the unfiltered list so the summary card
  // doesn't change when the user flips between All/Chat/Voice/Bible.
  // Coin totals come from regular sessions; rupee totals come from
  // bible sessions. Mixing units would lie to the user.
  int get coinsSpent =>
      allEntries.fold(0, (sum, e) => sum + e.coinsSpent);
  int get coinsEarned =>
      allEntries.fold(0, (sum, e) => sum + e.coinsEarned);
  int get inrSpent =>
      allEntries.fold(0, (sum, e) => sum + e.inrSpent);
  int get inrEarned =>
      allEntries.fold(0, (sum, e) => sum + e.inrEarned);

  // Backwards-compatible aliases — the legacy summary card on the
  // page reads totalSpent / totalEarned. These now route to the coin
  // totals (regular sessions); the new bible-specific totals sit
  // alongside as inrSpent / inrEarned.
  int get totalSpent => coinsSpent;
  int get totalEarned => coinsEarned;

  SessionHistoryLoaded copyWith({
    List<HistoryEntry>? allEntries,
    List<HistoryEntry>? filtered,
    String? activeFilter,
  }) =>
      SessionHistoryLoaded(
        allEntries: allEntries ?? this.allEntries,
        filtered: filtered ?? this.filtered,
        activeFilter: activeFilter ?? this.activeFilter,
      );
}

class SessionHistoryError extends SessionHistoryState {
  final String message;
  const SessionHistoryError(this.message);
}
