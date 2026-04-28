// Drives the session monitor. Active tab subscribes to a live
// snapshot stream so the admin sees sessions transition the moment
// a CF flips them; Completed and All tabs use a one-shot fetch
// since history doesn't change underneath the admin.
//
// Stream-error handling: a transient Firestore error used to be
// silently swallowed, leaving the badge frozen at a stale count
// while the admin trusted it. We now retry with a 2s delay up to
// three times, then surface AdminSessionsError so the admin sees
// the problem and can pull-to-retry. The retry counter resets on
// any successful tick so the next outage gets a fresh budget.

import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:gospel_vox/features/admin/sessions/bloc/admin_sessions_state.dart';
import 'package:gospel_vox/features/admin/sessions/data/admin_session_model.dart';
import 'package:gospel_vox/features/admin/sessions/data/admin_sessions_repository.dart';

class AdminSessionsCubit extends Cubit<AdminSessionsState> {
  final AdminSessionsRepository _repository;

  // Long-lived subscription powering the Active tab list and the
  // count badge. Goes null once retries are exhausted so loadSessions
  // can re-establish on the next admin Retry.
  StreamSubscription<List<AdminSessionModel>>? _activeSub;
  Timer? _retryTimer;
  int _retryCount = 0;

  static const int _kMaxRetries = 3;
  static const Duration _kRetryDelay = Duration(seconds: 2);

  AdminSessionsCubit(this._repository) : super(AdminSessionsInitial()) {
    _listenActive();
  }

  void _listenActive() {
    // Tear down any prior sub before reattaching so we never end
    // up with two competing listeners.
    _activeSub?.cancel();
    _activeSub = _repository.watchActiveSessions().listen(
      (sessions) {
        if (isClosed) return;
        // Successful tick — clear the retry budget so the next
        // outage gets the full 3-attempt window again.
        _retryCount = 0;
        final current = state;
        if (current is AdminSessionsLoaded && current.filter == 'active') {
          emit(current.copyWith(
            sessions: sessions,
            activeCount: sessions.length,
          ));
        } else if (current is AdminSessionsLoaded) {
          emit(current.copyWith(activeCount: sessions.length));
        }
        // Initial-state stream tick is ignored — loadSessions seeds
        // the loaded state with the right shape on first call.
      },
      onError: (_) {
        if (isClosed) return;
        if (_retryCount >= _kMaxRetries) {
          // Out of attempts — null the sub so loadSessions can
          // resurrect it when the admin hits Retry, and surface
          // an error state instead of letting the badge sit on a
          // stale value.
          _activeSub?.cancel();
          _activeSub = null;
          emit(AdminSessionsError(
            'Live session monitor disconnected. Pull to retry.',
          ));
          return;
        }
        _retryCount++;
        _retryTimer?.cancel();
        _retryTimer = Timer(_kRetryDelay, () {
          if (isClosed) return;
          _listenActive();
        });
      },
    );
  }

  // Loads a tab. Stays on the previous loaded state during refetch
  // so the user never sees a flash of empty list while the new
  // filter is fetching — only the very first load shows the
  // shimmer placeholder.
  Future<void> loadSessions(String filter) async {
    // Manual reload also clears the retry counter and revives the
    // stream if it died — the admin's Retry button is the recovery
    // path for the live monitor.
    _retryCount = 0;
    if (_activeSub == null) {
      _listenActive();
    }
    try {
      if (state is! AdminSessionsLoaded) {
        emit(AdminSessionsLoading());
      }

      List<AdminSessionModel> sessions;
      if (filter == 'active') {
        // Active tab pulls a one-shot to seed immediately, then the
        // long-lived stream subscription takes over. Avoids waiting
        // on the first stream tick before showing anything.
        sessions = await _repository.getSessions(statusFilter: 'active');
      } else {
        sessions =
            await _repository.getSessions(statusFilter: filter);
      }

      if (isClosed) return;
      final current = state;
      final activeCount = current is AdminSessionsLoaded
          ? current.activeCount
          : (filter == 'active' ? sessions.length : 0);

      emit(AdminSessionsLoaded(
        sessions: sessions,
        filter: filter,
        activeCount: activeCount,
      ));
    } on TimeoutException {
      if (isClosed) return;
      if (state is AdminSessionsLoaded) return;
      emit(AdminSessionsError('Taking too long. Check your connection.'));
    } catch (_) {
      if (isClosed) return;
      if (state is AdminSessionsLoaded) return;
      emit(AdminSessionsError('Failed to load sessions.'));
    }
  }

  @override
  Future<void> close() async {
    _retryTimer?.cancel();
    _retryTimer = null;
    await _activeSub?.cancel();
    _activeSub = null;
    return super.close();
  }
}
