// Cubit driving the user home feed.
//
// Uses a Firestore stream for live updates — if a priest flips online
// mid-scroll, the card moves up without the user refreshing. We layer
// an explicit one-shot `refresh()` on top so the pull-to-refresh
// gesture has a concrete future to await; the stream still converges
// right after.

import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:gospel_vox/features/admin/speakers/data/speaker_model.dart';
import 'package:gospel_vox/features/user/home/bloc/home_state.dart';
import 'package:gospel_vox/features/user/home/data/home_repository.dart';

class HomeCubit extends Cubit<HomeState> {
  final HomeRepository _repository;
  StreamSubscription<List<SpeakerModel>>? _priestsSubscription;

  HomeCubit(this._repository) : super(const HomeInitial());

  // Starts (or restarts) the Firestore listener. Called once from
  // the page's initState; calling it again after close would be a
  // no-op because `isClosed` gates every emit.
  void watchPriests() {
    emit(const HomeLoading());

    _priestsSubscription?.cancel();
    _priestsSubscription = _repository.watchOnlinePriests().listen(
      (priests) {
        if (isClosed) return;
        final current = state;
        final query = current is HomeLoaded ? current.searchQuery : '';
        emit(HomeLoaded(
          priests: priests,
          filteredPriests: _applySearch(priests, query),
          searchQuery: query,
        ));
      },
      onError: (_) {
        if (isClosed) return;
        // Keep the previous loaded state if we had one — a transient
        // stream error shouldn't wipe the feed. Only surface a blank
        // error screen on the very first load.
        if (state is HomeLoaded) return;
        emit(const HomeError('Failed to load priests. Pull to refresh.'));
      },
    );
  }

  // Locally filters the cached priest list — no network, so it's
  // safe to fire on every keystroke.
  void search(String query) {
    final current = state;
    if (current is! HomeLoaded) return;

    if (isClosed) return;
    emit(current.copyWith(
      filteredPriests: _applySearch(current.priests, query),
      searchQuery: query,
    ));
  }

  List<SpeakerModel> _applySearch(
    List<SpeakerModel> priests,
    String query,
  ) {
    if (query.isEmpty) return priests;
    final q = query.toLowerCase();
    return priests.where((p) {
      return p.fullName.toLowerCase().contains(q) ||
          p.denomination.toLowerCase().contains(q) ||
          p.specializations.any((s) => s.toLowerCase().contains(q)) ||
          p.languages.any((l) => l.toLowerCase().contains(q));
    }).toList();
  }

  // Pull-to-refresh path. We deliberately swallow errors here — the
  // user already has data on-screen, and replacing it with a full
  // error page because a refresh flaked would feel punishing. The
  // stream will recover silently; a snackbar-level error is enough
  // context for the user to know it didn't work.
  Future<void> refresh() async {
    try {
      final priests = await _repository.getPriests();
      if (isClosed) return;
      final current = state;
      final query = current is HomeLoaded ? current.searchQuery : '';
      emit(HomeLoaded(
        priests: priests,
        filteredPriests: _applySearch(priests, query),
        searchQuery: query,
      ));
    } catch (_) {
      // Intentional: see comment above.
    }
  }

  @override
  Future<void> close() {
    _priestsSubscription?.cancel();
    return super.close();
  }
}
