// States for the admin speaker management list + detail screens.
//
// Split into two sealed families (Speakers and SpeakerDetail) because
// the list and detail pages own independent cubits. Sealed so the
// builder has to render every variant — a missing case surfaces at
// analyze time rather than as a blank screen in prod.

import 'package:gospel_vox/features/admin/speakers/data/speaker_model.dart';

// ─── List states ────────────────────────────────────────────────

sealed class SpeakersState {}

class SpeakersInitial extends SpeakersState {}

class SpeakersLoading extends SpeakersState {}

class SpeakersLoaded extends SpeakersState {
  final List<SpeakerModel> pending;
  final List<SpeakerModel> approved;
  final List<SpeakerModel> suspended;
  final Map<String, int> counts;

  SpeakersLoaded({
    required this.pending,
    required this.approved,
    required this.suspended,
    required this.counts,
  });
}

class SpeakersError extends SpeakersState {
  final String message;
  SpeakersError(this.message);
}

// ─── Detail states ──────────────────────────────────────────────

sealed class SpeakerDetailState {}

class SpeakerDetailInitial extends SpeakerDetailState {}

class SpeakerDetailLoading extends SpeakerDetailState {}

class SpeakerDetailLoaded extends SpeakerDetailState {
  final SpeakerModel speaker;
  SpeakerDetailLoaded(this.speaker);
}

// Carries the previously-loaded speaker so the page can keep rendering
// the profile while showing a localised loading indicator on whichever
// action button was tapped. Beats hiding the whole page behind a
// spinner.
class SpeakerDetailActionInProgress extends SpeakerDetailState {
  final SpeakerModel speaker;
  final String action; // approving | rejecting | suspending | unsuspending
  SpeakerDetailActionInProgress(this.speaker, this.action);
}

class SpeakerDetailActionSuccess extends SpeakerDetailState {
  final SpeakerModel speaker;
  final String message;
  SpeakerDetailActionSuccess(this.speaker, this.message);
}

class SpeakerDetailError extends SpeakerDetailState {
  // Preserves the last-good speaker so the page can show an inline
  // error + retry while still rendering the profile, instead of
  // collapsing to a full-screen error after every transient hiccup.
  final SpeakerModel? speaker;
  final String message;
  SpeakerDetailError(this.message, {this.speaker});
}
