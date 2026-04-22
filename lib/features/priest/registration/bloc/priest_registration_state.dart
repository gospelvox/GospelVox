// State machine for the 4-step priest registration wizard (personal,
// ministry, documents, review).
//
// Sealed so the page's BlocListener is forced to handle every terminal
// state — forgetting Success or Error would be caught by the analyzer
// rather than at runtime as a stuck upload overlay.

import 'package:gospel_vox/features/priest/registration/data/priest_registration_model.dart';

sealed class PriestRegistrationState {}

class PriestRegInitial extends PriestRegistrationState {}

// The canonical wizard state. `currentStep` is the source of truth for
// which page the PageView should be on — the shell animates in
// response to changes here, not the other way around.
//
// `returnToReview` flips on when the priest taps Edit on the Review
// page. While it's true, completing a step jumps back to the review
// instead of walking through the remaining steps sequentially. Small
// flag, big UX improvement.
class PriestRegInProgress extends PriestRegistrationState {
  final int currentStep;
  final PriestRegistrationModel data;
  final bool isUploading;
  final double uploadProgress;
  final String? uploadingLabel;
  final bool returnToReview;

  PriestRegInProgress({
    required this.currentStep,
    required this.data,
    this.isUploading = false,
    this.uploadProgress = 0.0,
    this.uploadingLabel,
    this.returnToReview = false,
  });

  PriestRegInProgress copyWith({
    int? currentStep,
    PriestRegistrationModel? data,
    bool? isUploading,
    double? uploadProgress,
    String? uploadingLabel,
    bool? returnToReview,
  }) {
    return PriestRegInProgress(
      currentStep: currentStep ?? this.currentStep,
      data: data ?? this.data,
      isUploading: isUploading ?? this.isUploading,
      uploadProgress: uploadProgress ?? this.uploadProgress,
      uploadingLabel: uploadingLabel ?? this.uploadingLabel,
      returnToReview: returnToReview ?? this.returnToReview,
    );
  }
}

class PriestRegSubmitting extends PriestRegistrationState {}

class PriestRegSuccess extends PriestRegistrationState {}

class PriestRegError extends PriestRegistrationState {
  final String message;
  final int returnToStep;
  PriestRegError(this.message, {this.returnToStep = 0});
}
