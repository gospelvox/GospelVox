// Drives the user-side Bible tab list. Loads all three buckets in
// parallel on first mount and on pull-to-refresh; tab switches are
// just a copyWith on the loaded state, no re-fetch.

import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:gospel_vox/features/shared/bloc/bible_session_state.dart';
import 'package:gospel_vox/features/shared/data/bible_session_repository.dart';

class BibleSessionCubit extends Cubit<BibleSessionState> {
  final BibleSessionRepository _repository;

  BibleSessionCubit(this._repository) : super(const BibleSessionInitial());

  Future<void> loadSessions() async {
    if (isClosed) return;
    emit(const BibleSessionLoading());

    try {
      final results = await Future.wait([
        _repository.getUpcomingSessions(),
        _repository.getPastSessions(),
        _repository.getAllSessions(),
      ]);

      if (isClosed) return;
      emit(BibleSessionLoaded(
        upcoming: results[0],
        past: results[1],
        all: results[2],
      ));
    } on TimeoutException {
      if (isClosed) return;
      emit(const BibleSessionError(
          "Taking too long. Check your connection."));
    } catch (_) {
      if (isClosed) return;
      emit(const BibleSessionError("Failed to load sessions."));
    }
  }

  // Tab change is a pure UI transition — keeps the already-loaded
  // lists and just flips the active key.
  void switchTab(String tab) {
    if (isClosed) return;
    final current = state;
    if (current is BibleSessionLoaded) {
      emit(current.copyWith(activeTab: tab));
    }
  }

  Future<void> refresh() => loadSessions();
}
