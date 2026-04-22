// Drives the 4-step priest wizard: personal → ministry → documents →
// review. Resume-from-draft, compress-before-upload, return-to-review
// on edit, retry-on-error. Every await is isClosed-guarded because the
// user can go_router away at any point during the multi-minute upload.
//
// Why sequential uploads: priest networks (rural India, church Wi-Fi)
// are bandwidth-starved, and parallel PUTs starve each other out.
// Going one file at a time also lets the overlay narrate real progress
// ("Compressing... Uploading ID proof...") instead of a mystery spinner.

import 'dart:async';
import 'dart:io';

import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:gospel_vox/core/utils/draft_storage.dart';
import 'package:gospel_vox/core/utils/image_utils.dart';
import 'package:gospel_vox/features/priest/registration/bloc/priest_registration_state.dart';
import 'package:gospel_vox/features/priest/registration/data/priest_registration_model.dart';
import 'package:gospel_vox/features/priest/registration/data/priest_registration_repository.dart';

// Step indices — named so callers don't sprinkle magic 0/1/2/3.
const int _kStepPersonal = 0;
const int _kStepMinistry = 1;
const int _kStepDocuments = 2;
const int _kStepReview = 3;

class PriestRegistrationCubit extends Cubit<PriestRegistrationState> {
  final PriestRegistrationRepository _repository;

  PriestRegistrationCubit(this._repository) : super(PriestRegInitial());

  // Loads any saved draft (text fields only) and seeds the wizard.
  // Photo pre-fill from Firebase Auth is deliberately skipped — we want
  // a real uploaded portrait, not a stale Google avatar.
  Future<void> startRegistration({
    required String email,
    String? displayName,
  }) async {
    final draft = await DraftStorage.loadDraft();

    final initialData = draft != null
        ? PriestRegistrationModel.fromDraft(draft).copyWith(email: email)
        : PriestRegistrationModel(
            email: email,
            fullName: displayName ?? '',
          );

    final startStep = draft != null ? _determineStep(initialData) : 0;

    if (isClosed) return;
    emit(PriestRegInProgress(
      currentStep: startStep,
      data: initialData,
    ));
  }

  // Resume heuristic: jump back to the earliest step with missing
  // data so the user doesn't have to re-walk completed screens. The
  // documents step (2) can't be resumed from draft because file
  // paths don't survive an app restart, so we never jump there —
  // users always pick documents fresh.
  int _determineStep(PriestRegistrationModel data) {
    if (data.fullName.isEmpty || data.phone.isEmpty) return _kStepPersonal;
    if (data.denomination.isEmpty || data.bio.isEmpty) return _kStepMinistry;
    return _kStepDocuments;
  }

  void completeStep1({
    required String fullName,
    required String phone,
    required String email,
    String? photoPath,
  }) {
    final current = state;
    if (current is! PriestRegInProgress || isClosed) return;

    final updated = current.data.copyWith(
      fullName: fullName,
      phone: phone,
      email: email,
      photoPath: photoPath,
    );

    emit(current.copyWith(
      currentStep: _nextStepAfter(current, _kStepPersonal),
      data: updated,
      returnToReview: false,
    ));
    DraftStorage.saveDraft(updated.toDraft());
  }

  void completeStep2({
    required String denomination,
    required String subDenomination,
    required String churchName,
    required String diocese,
    required String location,
    required int yearsOfExperience,
    required String bio,
    required List<String> languages,
    required List<String> specializations,
  }) {
    final current = state;
    if (current is! PriestRegInProgress || isClosed) return;

    final updated = current.data.copyWith(
      denomination: denomination,
      subDenomination: subDenomination,
      churchName: churchName,
      diocese: diocese,
      location: location,
      yearsOfExperience: yearsOfExperience,
      bio: bio,
      languages: languages,
      specializations: specializations,
    );

    emit(current.copyWith(
      currentStep: _nextStepAfter(current, _kStepMinistry),
      data: updated,
      returnToReview: false,
    ));
    DraftStorage.saveDraft(updated.toDraft());
  }

  // Step 3 doesn't upload yet — it just captures the picked file paths
  // into the model so Step 4 (review) can show thumbnails and the
  // actual submit can read paths from state instead of being passed
  // them again.
  void completeStep3({
    required String? idProofPath,
    required String? certificatePath,
  }) {
    final current = state;
    if (current is! PriestRegInProgress || isClosed) return;

    final updated = current.data.copyWith(
      idProofPath: idProofPath,
      certificatePath: certificatePath,
    );

    emit(current.copyWith(
      currentStep: _kStepReview,
      data: updated,
      returnToReview: false,
    ));
  }

  // If the priest is editing from the review page, every step's
  // Continue should snap them back to review instead of walking the
  // wizard forward — they explicitly asked to fix one thing.
  int _nextStepAfter(PriestRegInProgress current, int completedStep) {
    if (current.returnToReview) return _kStepReview;
    return completedStep + 1;
  }

  void goBack() {
    final current = state;
    if (current is! PriestRegInProgress || isClosed) return;
    if (current.currentStep > 0) {
      emit(current.copyWith(currentStep: current.currentStep - 1));
    }
  }

  // Called when the priest taps Edit on a card in the review page.
  // Jumps to the requested step and arms returnToReview so their
  // next Continue sends them straight back.
  void goToEditFromReview(int step) {
    final current = state;
    if (current is! PriestRegInProgress || isClosed) return;
    if (step < 0 || step > _kStepDocuments) return;
    emit(current.copyWith(currentStep: step, returnToReview: true));
  }

  // Runs the full upload + Firestore write. Called from Step 4's
  // confirmation sheet, so paths live on `current.data` already.
  Future<void> submitRegistration({required String uid}) async {
    final initial = state;
    if (initial is! PriestRegInProgress) return;

    try {
      var updatedData = initial.data;
      var stage = initial;

      // 1) Profile photo — compress then upload.
      if (initial.data.photoPath != null &&
          initial.data.photoPath!.isNotEmpty) {
        if (isClosed) return;
        stage = stage.copyWith(
          isUploading: true,
          uploadingLabel: 'Compressing photo...',
          uploadProgress: 0.05,
        );
        emit(stage);

        final compressed =
            await ImageUtils.compressImage(initial.data.photoPath!);

        if (isClosed) return;
        stage = stage.copyWith(
          uploadingLabel: 'Uploading photo...',
          uploadProgress: 0.15,
        );
        emit(stage);

        final photoUrl = await _repository.uploadFile(
          uid: uid,
          filePath: compressed,
          storagePath: 'photo.jpg',
        );
        updatedData = updatedData.copyWith(photoUrl: photoUrl);
      }

      // 2) ID proof — required at the UI level but still guarded.
      final idPath = initial.data.idProofPath;
      if (idPath != null && idPath.isNotEmpty) {
        if (isClosed) return;
        stage = stage.copyWith(
          isUploading: true,
          uploadingLabel: 'Uploading ID proof...',
          uploadProgress: 0.4,
          data: updatedData,
        );
        emit(stage);

        final compressed = await ImageUtils.compressImage(idPath);
        final idUrl = await _repository.uploadFile(
          uid: uid,
          filePath: compressed,
          storagePath: 'id_proof.jpg',
        );
        updatedData = updatedData.copyWith(idProofUrl: idUrl);
      }

      // 3) Optional ordination certificate.
      final certPath = initial.data.certificatePath;
      if (certPath != null && certPath.isNotEmpty) {
        if (isClosed) return;
        stage = stage.copyWith(
          isUploading: true,
          uploadingLabel: 'Uploading certificate...',
          uploadProgress: 0.7,
          data: updatedData,
        );
        emit(stage);

        final compressed = await ImageUtils.compressImage(certPath);
        final certUrl = await _repository.uploadFile(
          uid: uid,
          filePath: compressed,
          storagePath: 'certificate.jpg',
        );
        updatedData = updatedData.copyWith(certificateUrl: certUrl);
      }

      // 4) Firestore write.
      if (isClosed) return;
      stage = stage.copyWith(
        isUploading: true,
        uploadingLabel: 'Submitting application...',
        uploadProgress: 0.9,
        data: updatedData,
      );
      emit(stage);

      await _repository.submitRegistration(uid: uid, data: updatedData);

      // Draft has served its purpose — wipe it so a re-registration
      // after rejection doesn't resurrect old text.
      await DraftStorage.clearDraft();

      if (isClosed) return;
      emit(PriestRegSuccess());
    } on TimeoutException {
      if (isClosed) return;
      emit(PriestRegError(
        'Upload timed out. Your progress is saved — please check '
        'your internet connection and try again.',
        returnToStep: _kStepReview,
      ));
    } on SocketException {
      if (isClosed) return;
      emit(PriestRegError(
        'No internet connection. Your progress is saved — '
        'reconnect and try again.',
        returnToStep: _kStepReview,
      ));
    } catch (_) {
      if (isClosed) return;
      emit(PriestRegError(
        'Something went wrong. Your progress is saved — '
        'please try again.',
        returnToStep: _kStepReview,
      ));
    }
  }

  // Flips the error state back to interactive in-progress so the
  // user can retry. Rehydrates text fields from the on-disk draft;
  // file paths were already on the in-memory model so they survive.
  Future<void> resumeAfterError() async {
    final current = state;
    if (current is! PriestRegError || isClosed) return;
    final step = current.returnToStep;
    final draft = await DraftStorage.loadDraft();
    if (isClosed) return;
    final data = draft != null
        ? PriestRegistrationModel.fromDraft(draft)
        : const PriestRegistrationModel();
    emit(PriestRegInProgress(currentStep: step, data: data));
  }
}
