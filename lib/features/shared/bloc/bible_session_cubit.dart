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
      // Three parallel reads — dropped the `getAllSessions()` call
      // that used to fill the now-removed "All" tab. That query was
      // pure waste: a full-collection scan that returned every doc
      // the other three queries already covered, on every refresh.
      final results = await Future.wait([
        _repository.getUpcomingSessions(),
        _repository.getLiveSessions(),
        _repository.getPastSessions(),
      ]);

      if (isClosed) return;
      final pastFiltered = _filterRecentPast(results[2]);
      // Per-session reg lookups for the CURRENT user, batched in
      // parallel:
      //   • paidIds drives the LIVE card's "Open Meeting ✅" vs
      //     "Join Now · ₹X" branch — without it the list keeps
      //     prompting paid users to pay again on every refresh.
      //   • registeredIds drives the UPCOMING card's "Registered ✓"
      //     vs "Register Free" branch — without it the list keeps
      //     telling already-registered users to register again.
      // Both run in parallel to keep the load round-trip short.
      // Best-effort: per-doc read failures leave that id out of the
      // set, which degrades to the prompt-again CTA rather than
      // crashing.
      final results2 = await Future.wait([
        _resolvePaidSessionIds(results[1]),
        _resolveRegisteredSessionIds(results[0]),
      ]);
      if (isClosed) return;
      emit(BibleSessionLoaded(
        upcoming: results[0],
        live: results[1],
        past: pastFiltered,
        // `all` is no longer consumed by the user-side UI; keep the
        // state field for backwards compat (priest-side surfaces may
        // still read it) but populate as empty so the field is just
        // an unused container, not a wasted Firestore read.
        all: const [],
        paidSessionIds: results2[0],
        registeredSessionIds: results2[1],
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

  // Same pattern as _resolvePaidSessionIds but for UPCOMING sessions:
  // returns the set of ids where the current user has a non-cancelled
  // registration. Drives the upcoming card's "Registered ✓" CTA.
  //
  // A reg doc is considered "registered" whenever it exists and isn't
  // status='cancelled' — covers the normal 'registered' state and the
  // edge-case 'paid' state (paid users on an upcoming session
  // shouldn't logically exist in V1, but the check is defensive).
  Future<Set<String>> _resolveRegisteredSessionIds(
    List<BibleSessionModel> upcomingSessions,
  ) async {
    if (upcomingSessions.isEmpty) return const {};
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return const {};

    final results = await Future.wait(upcomingSessions.map((s) async {
      try {
        final reg = await _repository.getRegistration(s.id, uid);
        return (reg != null && !reg.isCancelled) ? s.id : null;
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

  // Public refresh — used by pull-to-refresh, detail-page return,
  // and app-resume. Delegates to the SILENT refresh path so the UI
  // doesn't flash the shimmer placeholder on every kick.
  Future<void> refresh() => _silentRefresh();

  // Silent background refresh.
  //
  // The OLD `refresh = loadSessions` path emitted `BibleSessionLoading`
  // before each refetch, which made the BlocBuilder swap the loaded
  // list out for the shimmer skeleton — every periodic tick (and
  // every pull-to-refresh) caused a visible "page reloading" flicker.
  // Even with no network changes the user saw the list disappear
  // and reappear, which read as a bug.
  //
  // This path keeps the existing Loaded state on screen, fetches in
  // the background, and only emits a NEW Loaded (with copyWith) when
  // the data arrives. Errors are swallowed — a transient connectivity
  // blip leaves the stale list visible instead of throwing the user
  // into the full-screen error state and losing their place. The
  // initial load is still routed through `loadSessions` so first-mount
  // can show the shimmer (there's nothing to display otherwise).
  Future<void> _silentRefresh() async {
    if (isClosed) return;
    final current = state;
    if (current is! BibleSessionLoaded) {
      return loadSessions();
    }

    try {
      final results = await Future.wait([
        _repository.getUpcomingSessions(),
        _repository.getLiveSessions(),
        _repository.getPastSessions(),
      ]);
      if (isClosed) return;
      final pastFiltered = _filterRecentPast(results[2]);
      final results2 = await Future.wait([
        _resolvePaidSessionIds(results[1]),
        _resolveRegisteredSessionIds(results[0]),
      ]);
      if (isClosed) return;
      emit(current.copyWith(
        upcoming: results[0],
        live: results[1],
        past: pastFiltered,
        paidSessionIds: results2[0],
        registeredSessionIds: results2[1],
      ));
    } catch (_) {
      // Soft-fail by design — see header comment.
    }
  }
}
