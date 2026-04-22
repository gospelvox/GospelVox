// State shapes for the user home feed.
//
// Sealed so exhaustive switches in the UI force us to handle every
// branch — missing a case is a compile-time error rather than a
// silent blank screen in production.

import 'package:gospel_vox/features/admin/speakers/data/speaker_model.dart';

sealed class HomeState {
  const HomeState();
}

class HomeInitial extends HomeState {
  const HomeInitial();
}

class HomeLoading extends HomeState {
  const HomeLoading();
}

class HomeLoaded extends HomeState {
  // Source of truth from Firestore. We keep this separate from
  // `filteredPriests` so search can be re-applied or cleared without
  // hitting the network again.
  final List<SpeakerModel> priests;
  final List<SpeakerModel> filteredPriests;
  final String searchQuery;

  HomeLoaded({
    required this.priests,
    List<SpeakerModel>? filteredPriests,
    this.searchQuery = '',
  }) : filteredPriests = filteredPriests ?? priests;

  // Three-way split for the feed sections. A priest is either:
  //  • available — online and not paused (ready for a new session)
  //  • busy — online but paused requests (visible but uncontactable)
  //  • offline — not online
  // Computed lazily per-getter because the lists are small (<50
  // realistic priests) and memoisation would complicate the state
  // without buying anything measurable.
  List<SpeakerModel> get availablePriests =>
      filteredPriests.where((p) => p.isAvailable).toList();

  List<SpeakerModel> get busyPriests =>
      filteredPriests.where((p) => p.isOnline && p.isBusy).toList();

  List<SpeakerModel> get offlinePriests =>
      filteredPriests.where((p) => !p.isOnline).toList();

  bool get hasAvailablePriests => availablePriests.isNotEmpty;
  bool get hasAnyPriests => filteredPriests.isNotEmpty;

  HomeLoaded copyWith({
    List<SpeakerModel>? priests,
    List<SpeakerModel>? filteredPriests,
    String? searchQuery,
  }) {
    return HomeLoaded(
      priests: priests ?? this.priests,
      filteredPriests: filteredPriests ?? this.filteredPriests,
      searchQuery: searchQuery ?? this.searchQuery,
    );
  }
}

class HomeError extends HomeState {
  final String message;
  const HomeError(this.message);
}
