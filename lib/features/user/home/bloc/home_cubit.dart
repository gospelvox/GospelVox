// Cubit driving the user home feed.
//
// Uses a Firestore stream for live updates — if a priest flips online
// mid-scroll, the card moves up without the user refreshing. We layer
// an explicit one-shot `refresh()` on top so the pull-to-refresh
// gesture has a concrete future to await; the stream still converges
// right after.
//
// Two independent live sources feed every emit:
//   1. priests stream — the canonical approved+activated list
//   2. blocked-priest-ids stream — the current user's blocklist
// When either changes we recompute filtered priests by subtracting
// blocked ids from the priest list before applying the search query.
// Block changes therefore reflect on the feed instantly (no manual
// refresh) so a user who just tapped Block on a profile sees the
// card disappear the moment they pop back here.

import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:gospel_vox/features/admin/speakers/data/speaker_model.dart';
import 'package:gospel_vox/features/user/home/bloc/home_state.dart';
import 'package:gospel_vox/features/user/home/data/home_repository.dart';

class HomeCubit extends Cubit<HomeState> {
  final HomeRepository _repository;
  StreamSubscription<List<SpeakerModel>>? _priestsSubscription;
  StreamSubscription<Set<String>>? _blockedSubscription;

  // Latest snapshot of each upstream stream. The block filter is
  // computed on demand from these two whenever either fires, so the
  // user feels the change immediately without us re-querying anything.
  List<SpeakerModel> _allPriests = const [];
  Set<String> _blockedIds = const {};
  bool _priestsLoaded = false;

  HomeCubit(this._repository) : super(const HomeInitial());

  // Starts (or restarts) the Firestore listeners. Called once from
  // the page's initState; calling it again after close would be a
  // no-op because `isClosed` gates every emit.
  void watchPriests() {
    emit(const HomeLoading());

    _priestsSubscription?.cancel();
    _blockedSubscription?.cancel();
    _priestsLoaded = false;

    _priestsSubscription = _repository.watchOnlinePriests().listen(
      (priests) {
        if (isClosed) return;
        _allPriests = priests;
        _priestsLoaded = true;
        _emitLoaded();
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

    // Block stream only runs while the user is signed in. Unsigned
    // sessions (rare — every entry point gates on auth) just see the
    // unfiltered feed; the server-side gate in createSessionRequest
    // is the source of truth either way.
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid != null) {
      _blockedSubscription = _repository.watchBlockedPriestIds(uid).listen(
        (ids) {
          if (isClosed) return;
          _blockedIds = ids;
          if (_priestsLoaded) _emitLoaded();
        },
        // Block stream is best-effort — a transient failure should
        // never collapse the feed. We just keep the last known set.
        onError: (_) {},
      );
    }
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

  // Recomputes the loaded state from the in-memory snapshots, applying
  // the block filter BEFORE the search filter so a blocked priest is
  // hidden regardless of what the user types.
  void _emitLoaded() {
    final query = state is HomeLoaded
        ? (state as HomeLoaded).searchQuery
        : '';
    final visible = _applyBlock(_allPriests, _blockedIds);
    emit(HomeLoaded(
      priests: visible,
      filteredPriests: _applySearch(visible, query),
      searchQuery: query,
    ));
  }

  List<SpeakerModel> _applyBlock(
    List<SpeakerModel> priests,
    Set<String> blocked,
  ) {
    if (blocked.isEmpty) return priests;
    return priests.where((p) => !blocked.contains(p.uid)).toList();
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
      _allPriests = priests;
      _priestsLoaded = true;
      _emitLoaded();
    } catch (_) {
      // Intentional: see comment above.
    }
  }

  @override
  Future<void> close() {
    _priestsSubscription?.cancel();
    _blockedSubscription?.cancel();
    return super.close();
  }
}
