// State machine for the Bible-tab list view. The detail pages
// don't use this cubit — they manage their own widget-local state
// because each detail mount has its own load/refresh lifecycle.

import 'package:gospel_vox/features/shared/data/bible_session_model.dart';

sealed class BibleSessionState {
  const BibleSessionState();
}

class BibleSessionInitial extends BibleSessionState {
  const BibleSessionInitial();
}

class BibleSessionLoading extends BibleSessionState {
  const BibleSessionLoading();
}

class BibleSessionLoaded extends BibleSessionState {
  final List<BibleSessionModel> upcoming;
  // Sessions the priest has actually started — surfaced as a separate
  // bucket so the user-side tab can show a "Live Now" strip distinct
  // from the upcoming list. Typically very small (one per priest at
  // most), so we don't pre-compute a sort key here.
  final List<BibleSessionModel> live;
  final List<BibleSessionModel> past;
  final List<BibleSessionModel> all;
  // Session ids the CURRENT user has already paid for. Drives the
  // live card CTA — paid sessions show "Open Meeting ✅" instead of
  // "Join Now · ₹X". Without this the list nags every paid user to
  // pay again on every refresh until auto-complete.
  final Set<String> paidSessionIds;
  // Session ids the CURRENT user has registered for (non-cancelled).
  // Drives the upcoming card CTA — registered sessions show
  // "Registered ✓" outlined-green instead of the amber "Register
  // Free" prompt that would tell an already-registered user to
  // re-register. Empty for anonymous / signed-out users.
  final Set<String> registeredSessionIds;
  // "upcoming" / "live" / "past" / "all" — drives which list the
  // tab renders. The bible tab will likely fold "live" into the
  // top of "upcoming" rather than render a dedicated tab; both
  // approaches are supported because the field is just a string.
  final String activeTab;

  const BibleSessionLoaded({
    required this.upcoming,
    required this.live,
    required this.past,
    required this.all,
    this.paidSessionIds = const {},
    this.registeredSessionIds = const {},
    this.activeTab = 'upcoming',
  });

  List<BibleSessionModel> get activeList {
    switch (activeTab) {
      case 'upcoming':
        return upcoming;
      case 'live':
        return live;
      case 'past':
        return past;
      case 'all':
        return all;
      default:
        return upcoming;
    }
  }

  BibleSessionLoaded copyWith({
    List<BibleSessionModel>? upcoming,
    List<BibleSessionModel>? live,
    List<BibleSessionModel>? past,
    List<BibleSessionModel>? all,
    Set<String>? paidSessionIds,
    Set<String>? registeredSessionIds,
    String? activeTab,
  }) {
    return BibleSessionLoaded(
      upcoming: upcoming ?? this.upcoming,
      live: live ?? this.live,
      past: past ?? this.past,
      all: all ?? this.all,
      paidSessionIds: paidSessionIds ?? this.paidSessionIds,
      registeredSessionIds:
          registeredSessionIds ?? this.registeredSessionIds,
      activeTab: activeTab ?? this.activeTab,
    );
  }
}

class BibleSessionError extends BibleSessionState {
  final String message;
  const BibleSessionError(this.message);
}
