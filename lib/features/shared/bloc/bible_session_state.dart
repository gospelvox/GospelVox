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
  final List<BibleSessionModel> past;
  final List<BibleSessionModel> all;
  // "upcoming" / "past" / "all" — drives which list the tab renders.
  final String activeTab;

  const BibleSessionLoaded({
    required this.upcoming,
    required this.past,
    required this.all,
    this.activeTab = 'upcoming',
  });

  List<BibleSessionModel> get activeList {
    switch (activeTab) {
      case 'upcoming':
        return upcoming;
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
    List<BibleSessionModel>? past,
    List<BibleSessionModel>? all,
    String? activeTab,
  }) {
    return BibleSessionLoaded(
      upcoming: upcoming ?? this.upcoming,
      past: past ?? this.past,
      all: all ?? this.all,
      activeTab: activeTab ?? this.activeTab,
    );
  }
}

class BibleSessionError extends BibleSessionState {
  final String message;
  const BibleSessionError(this.message);
}
