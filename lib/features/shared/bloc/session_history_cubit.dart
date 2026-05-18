// Cubit for the session-history list. Used by both user and priest
// pages — the only difference is which loader the host calls in
// initState. Filtering is local (no refetch) so flipping chips is
// instant.
//
// Every emit is gated on isClosed because the cubit is a factory
// and the page can pop before a slow Firestore call returns; without
// the guard we'd hit "Cannot emit new states after calling close".
//
// Loads now fan-out: regular sessions, bible sessions, and the
// caller's hidden-id set are fetched in parallel and merged into
// one chronologically-sorted list. The hide actions soft-delete by
// appending composite keys (s:{id} / b:{id}) onto the user's own
// `hiddenSessionIds` array — Firestore rules deny `delete` on
// /sessions and on /bible_sessions/.../registrations, so soft-hide
// is the only client-driven path.

import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:gospel_vox/features/shared/bloc/session_history_state.dart';
import 'package:gospel_vox/features/shared/data/session_history_repository.dart';

class SessionHistoryCubit extends Cubit<SessionHistoryState> {
  final SessionHistoryRepository _repository;

  SessionHistoryCubit(this._repository)
      : super(const SessionHistoryInitial());

  Future<void> loadUserSessions(String userId) async {
    try {
      if (isClosed) return;
      emit(const SessionHistoryLoading());

      // Regular sessions, bible sessions, and the hidden-id set are
      // fetched in parallel — three reads of independent collections.
      // A failure on the bible side returns an empty list (defaulted
      // by the repository's catch blocks); a failure on hidden ids
      // returns an empty set, which means "show everything" — better
      // UX than blocking the page on a hidden-list read.
      final results = await Future.wait([
        _repository.getUserSessions(userId),
        _repository.getUserBibleSessions(userId),
        _repository.getHiddenIds(uid: userId, isUserSide: true),
      ]);

      final regular = results[0] as List;
      final bible = results[1] as List;
      final hidden = results[2] as Set<String>;

      final entries = _mergeAndSort(
        regular: regular.cast(),
        bible: bible.cast(),
        hidden: hidden,
      );

      if (isClosed) return;
      emit(SessionHistoryLoaded(allEntries: entries));
    } on TimeoutException {
      if (isClosed) return;
      emit(const SessionHistoryError(
        'Taking too long. Check your connection.',
      ));
    } catch (_) {
      if (isClosed) return;
      emit(const SessionHistoryError('Failed to load session history.'));
    }
  }

  Future<void> loadPriestSessions(String priestId) async {
    try {
      if (isClosed) return;
      emit(const SessionHistoryLoading());

      final results = await Future.wait([
        _repository.getPriestSessions(priestId),
        _repository.getPriestBibleSessions(priestId),
        _repository.getHiddenIds(uid: priestId, isUserSide: false),
      ]);

      final regular = results[0] as List;
      final bible = results[1] as List;
      final hidden = results[2] as Set<String>;

      final entries = _mergeAndSort(
        regular: regular.cast(),
        bible: bible.cast(),
        hidden: hidden,
      );

      if (isClosed) return;
      emit(SessionHistoryLoaded(allEntries: entries));
    } on TimeoutException {
      if (isClosed) return;
      emit(const SessionHistoryError(
        'Taking too long. Check your connection.',
      ));
    } catch (_) {
      if (isClosed) return;
      emit(const SessionHistoryError('Failed to load session history.'));
    }
  }

  // Merges regular + bible into a single chronologically-sorted list,
  // dropping any entry whose composite key is in the hidden set.
  // Newest first; entries with no resolvable timestamp sink to the
  // bottom (year 2000 fallback).
  List<HistoryEntry> _mergeAndSort({
    required List<dynamic> regular,
    required List<dynamic> bible,
    required Set<String> hidden,
  }) {
    final entries = <HistoryEntry>[
      for (final s in regular) RegularSessionEntry(s),
      ...bible.cast<BibleSessionEntry>(),
    ]..removeWhere((e) => hidden.contains(e.hiddenKey));

    entries.sort((a, b) {
      final aTime = a.sortAt ?? DateTime(2000);
      final bTime = b.sortAt ?? DateTime(2000);
      return bTime.compareTo(aTime);
    });
    return entries;
  }

  // Local filter — operates on the already-loaded list, no refetch.
  // Pre-loaded states (Initial / Loading / Error) are ignored so a
  // fast chip-tap during the very first load doesn't blow up.
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

  // Optimistically removes the entry from the visible list and
  // appends its hiddenKey to the caller's `hiddenSessionIds` array.
  // On failure, re-inserts the entry so the visible state stays
  // honest.
  Future<bool> hideOne({
    required String uid,
    required bool isUserSide,
    required HistoryEntry entry,
  }) async {
    final current = state;
    if (current is! SessionHistoryLoaded) return false;

    final newAll = current.allEntries
        .where((e) => e.hiddenKey != entry.hiddenKey)
        .toList();
    final newFiltered = current.filtered
        .where((e) => e.hiddenKey != entry.hiddenKey)
        .toList();

    if (isClosed) return false;
    emit(current.copyWith(
      allEntries: newAll,
      filtered: newFiltered,
    ));

    try {
      await _repository.hideEntries(
        uid: uid,
        isUserSide: isUserSide,
        hiddenKeys: [entry.hiddenKey],
      );
      return true;
    } catch (_) {
      // Roll back — put the entry back where it was. Re-applying the
      // sort keeps it in the right slot rather than tail-appending.
      if (isClosed) return false;
      final restoredAll = [...newAll, entry]..sort((a, b) {
          final aTime = a.sortAt ?? DateTime(2000);
          final bTime = b.sortAt ?? DateTime(2000);
          return bTime.compareTo(aTime);
        });
      final restoredFiltered = current.activeFilter == 'all'
          ? restoredAll
          : restoredAll.where((e) => e.kind == current.activeFilter).toList();
      if (isClosed) return false;
      emit(current.copyWith(
        allEntries: restoredAll,
        filtered: restoredFiltered,
      ));
      return false;
    }
  }

  // Hides every visible entry (across all filter chips, not just the
  // currently-filtered slice — Clear All clears the entire history,
  // not whatever happens to be filtered in view). Optimistic: clears
  // locally first, rolls back on a write failure.
  Future<bool> hideAll({
    required String uid,
    required bool isUserSide,
  }) async {
    final current = state;
    if (current is! SessionHistoryLoaded) return false;
    if (current.allEntries.isEmpty) return false;

    final snapshot = current.allEntries;
    final keys = snapshot.map((e) => e.hiddenKey).toList();

    if (isClosed) return false;
    emit(current.copyWith(
      allEntries: const [],
      filtered: const [],
    ));

    try {
      await _repository.hideEntries(
        uid: uid,
        isUserSide: isUserSide,
        hiddenKeys: keys,
      );
      return true;
    } catch (_) {
      if (isClosed) return false;
      // Roll back — re-apply the snapshot through the same filter
      // path so the user sees what they were looking at before.
      final restoredFiltered = current.activeFilter == 'all'
          ? snapshot
          : snapshot.where((e) => e.kind == current.activeFilter).toList();
      if (isClosed) return false;
      emit(current.copyWith(
        allEntries: snapshot,
        filtered: restoredFiltered,
      ));
      return false;
    }
  }
}
