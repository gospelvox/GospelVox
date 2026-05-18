// Drives the user-side Bible tab list. Loads all four buckets in
// parallel on first mount and on pull-to-refresh; tab switches are
// just a copyWith on the loaded state, no re-fetch.

import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:gospel_vox/features/shared/bloc/bible_session_state.dart';
import 'package:gospel_vox/features/shared/data/bible_session_model.dart';
import 'package:gospel_vox/features/shared/data/bible_session_repository.dart';

class BibleSessionCubit extends Cubit<BibleSessionState> {
  final BibleSessionRepository _repository;

  BibleSessionCubit(this._repository) : super(const BibleSessionInitial());

  // Static signal used by other surfaces (e.g. home page's "Live"
  // pill) to pre-select a sub-tab when the user switches to the
  // Bible tab. The BibleTab widget listens to this and consumes
  // the value on each change. Lives here (not on the widget) so
  // any caller can publish without holding a cubit reference —
  // the shell's IndexedStack keeps a single BibleTab instance
  // alive, so the listener is always attached.
  //
  // Set BEFORE calling `UserShellScope.switchToTab(2)` — the
  // listener fires synchronously and the tab is already loaded.
  static final ValueNotifier<String?> pendingInitialTab =
      ValueNotifier<String?>(null);

  // Past sessions older than this are hidden from the Past tab.
  // 7-day window is a UI-only filter — the docs stay in Firestore
  // for admin / analytics / revenue reports indefinitely.
  static const _pastWindow = Duration(days: 7);

  Future<void> loadSessions() async {
    if (isClosed) return;
    emit(const BibleSessionLoading());

    try {
      final results = await Future.wait([
        _repository.getUpcomingSessions(),
        _repository.getLiveSessions(),
        _repository.getPastSessions(),
        _repository.getAllSessions(),
      ]);

      if (isClosed) return;
      final pastFiltered = _filterRecentPast(results[2]);
      // For every LIVE session, fan-read the current user's reg doc
      // and collect ids where status=='paid'. Drives the live card's
      // "Open Meeting ✅" vs "Join Now · ₹X" branch — without this
      // the list card has no way to know the viewer already paid
      // and re-prompts them on every refresh. Best-effort: a per-doc
      // read failure leaves that id out of the set, which degrades
      // to the existing "Join Now" CTA rather than crashing.
      final paidIds = await _resolvePaidSessionIds(results[1]);
      if (isClosed) return;
      emit(BibleSessionLoaded(
        upcoming: results[0],
        live: results[1],
        past: pastFiltered,
        all: results[3],
        paidSessionIds: paidIds,
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

  // Reads the current user's registration on each live session in
  // parallel and returns the set of session ids where status=='paid'.
  // Anonymous / signed-out users get an empty set (they can't have
  // paid anything). Per-session failures are swallowed — a missing
  // reg simply means "not paid" which is the safe default for the
  // CTA branch.
  Future<Set<String>> _resolvePaidSessionIds(
    List<BibleSessionModel> liveSessions,
  ) async {
    if (liveSessions.isEmpty) return const {};
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return const {};

    final results = await Future.wait(liveSessions.map((s) async {
      try {
        final reg = await _repository.getRegistration(s.id, uid);
        return (reg != null && reg.isPaid) ? s.id : null;
      } catch (_) {
        return null;
      }
    }));
    return results.whereType<String>().toSet();
  }

  // Drops past sessions whose scheduled end falls outside the
  // _pastWindow. Sessions with no scheduledAt are dropped because
  // we can't tell how old they are. Cancelled sessions use
  // `cancelledAt` (if present) as a fallback end-time so a
  // cancelled-yesterday session still shows even though its
  // scheduledAt may be days away. Completed sessions use
  // `completedAt` similarly when available.
  List<BibleSessionModel> _filterRecentPast(
    List<BibleSessionModel> past,
  ) {
    final cutoff = DateTime.now().subtract(_pastWindow);
    return past.where((s) {
      DateTime? endRef;
      if (s.completedAt != null) {
        endRef = s.completedAt;
      } else if (s.cancelledAt != null) {
        endRef = s.cancelledAt;
      } else if (s.scheduledAt != null) {
        endRef = s.scheduledAt!.add(Duration(minutes: s.durationMinutes));
      }
      return endRef != null && endRef.isAfter(cutoff);
    }).toList();
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
