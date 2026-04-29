// Cubit for the session-history list. Used by both user and priest
// pages — the only difference is which loader the host calls in
// initState. Filtering is local (no refetch) so flipping chips is
// instant.
//
// Every emit is gated on isClosed because the cubit is a factory
// and the page can pop before a slow Firestore call returns; without
// the guard we'd hit "Cannot emit new states after calling close".

import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:gospel_vox/features/shared/bloc/session_history_state.dart';
import 'package:gospel_vox/features/shared/data/session_history_repository.dart';
import 'package:gospel_vox/features/shared/data/session_model.dart';

class SessionHistoryCubit extends Cubit<SessionHistoryState> {
  final SessionHistoryRepository _repository;

  SessionHistoryCubit(this._repository)
      : super(const SessionHistoryInitial());

  Future<void> loadUserSessions(String userId) async {
    try {
      if (isClosed) return;
      emit(const SessionHistoryLoading());

      final sessions = await _repository.getUserSessions(userId);

      if (isClosed) return;
      emit(SessionHistoryLoaded(allSessions: sessions));
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

      final sessions = await _repository.getPriestSessions(priestId);

      if (isClosed) return;
      emit(SessionHistoryLoaded(allSessions: sessions));
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

  // Local filter — operates on the already-loaded list, no refetch.
  // Pre-loaded states (Initial / Loading / Error) are ignored so
  // a fast chip-tap during the very first load doesn't blow up.
  void filterByType(String type) {
    final current = state;
    if (current is! SessionHistoryLoaded) return;

    final List<SessionModel> filtered = type == 'all'
        ? current.allSessions
        : current.allSessions.where((s) => s.type == type).toList();

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
