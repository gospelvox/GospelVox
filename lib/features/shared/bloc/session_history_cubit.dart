// Cubit for the session-history list. Used by both user and priest
// pages — the only difference is which loader the host calls in
// initState. Filtering is local (no refetch) so flipping chips is
// instant.
//
// Every emit is gated on isClosed because the cubit is a factory
// and the page can pop before a slow Firestore call returns; without
// the guard we'd hit "Cannot emit new states after calling close".
//
// Loads fan-out: regular sessions and bible sessions are fetched in
// parallel and merged into one chronologically-sorted list. Each
// loader catches its own errors and returns an empty list so a
// partial failure (e.g. the bible-sessions composite index is still
// building) never blanks the entire history surface — the working
// half still renders.
//
// History is read-only: there is no hide / dismiss / clear path on
// the page anymore, so the cubit no longer carries hide methods or
// a hidden-id read.

import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:gospel_vox/features/shared/bloc/session_history_state.dart';
import 'package:gospel_vox/features/shared/data/session_history_repository.dart';

class SessionHistoryCubit extends Cubit<SessionHistoryState> {
  final SessionHistoryRepository _repository;

  SessionHistoryCubit(this._repository)
      : super(const SessionHistoryInitial());

  Future<void> loadUserSessions(String userId) async {
    if (isClosed) return;
    emit(const SessionHistoryLoading());

    // Each loader catches its own errors and returns an empty list
    // (see repository). One broken half — for example a missing
    // bible-sessions composite index, a transient permission glitch,
    // or a single corrupt doc that fails fromFirestore — therefore
    // can't blank the whole page. The working half still renders.
    final regular = await _repository.getUserSessions(userId);
    final bible = await _repository.getUserBibleSessions(userId);

    final entries = _mergeAndSort(regular: regular, bible: bible);

    if (isClosed) return;
    emit(SessionHistoryLoaded(allEntries: entries));
  }

  Future<void> loadPriestSessions(String priestId) async {
    if (isClosed) return;
    emit(const SessionHistoryLoading());

    final regular = await _repository.getPriestSessions(priestId);
    final bible = await _repository.getPriestBibleSessions(priestId);
    // Pull the priest's CF-aggregated rating so the summary card
    // can show the same number the dashboard shows. Local averaging
    // would silently drop bible ratings (BibleSessionEntry.rating
    // is null on the priest side because the priest hosts, doesn't
    // register) and any chat/voice rating past the visible window.
    final priestAgg = await _repository.getPriestRatingAggregate(priestId);

    final entries = _mergeAndSort(regular: regular, bible: bible);

    if (isClosed) return;
    emit(SessionHistoryLoaded(
      allEntries: entries,
      priestAvgRating: priestAgg.rating,
      priestReviewCount: priestAgg.reviewCount,
    ));
  }

  // Merges regular + bible into a single chronologically-sorted list.
  // Newest first; entries with no resolvable timestamp sink to the
  // bottom (year 2000 fallback).
  List<HistoryEntry> _mergeAndSort({
    required List<dynamic> regular,
    required List<dynamic> bible,
  }) {
    final entries = <HistoryEntry>[
      for (final s in regular) RegularSessionEntry(s),
      ...bible.cast<BibleSessionEntry>(),
    ];

    entries.sort((a, b) {
      final aTime = a.sortAt ?? DateTime(2000);
      final bTime = b.sortAt ?? DateTime(2000);
      return bTime.compareTo(aTime);
    });
    return entries;
  }

  // Local filter — operates on the already-loaded list, no refetch.
  // Pre-loaded states (Initial / Loading) are ignored so a fast chip-
  // tap during the very first load doesn't blow up.
  void filterByType(String type) {
    final current = state;
    if (current is! SessionHistoryLoaded) return;

    final List<HistoryEntry> filtered = type == 'all'
        ? current.allEntries
        : current.allEntries.where((e) => e.kind == type).toList();

    if (isClosed) return;
    emit(current.copyWith(filtered: filtered, activeFilter: type));
  }

  // Pull-to-refresh: re-runs the same loader the page used originally.
  // We dispatch on isUserSide rather than reading the state because
  // the previous load might have ended in Error, where state has no
  // hint of which side we're on.
  Future<void> refresh(String uid, bool isUserSide) async {
    if (isUserSide) {
      await loadUserSessions(uid);
    } else {
      await loadPriestSessions(uid);
    }
  }
}
