// Drives the speaker detail page (pending | active | suspended).
//
// Every mutation (approve/reject/suspend/unsuspend) funnels through
// the Cloud Function. The CF throws typed HttpsError codes we
// translate to friendly copy — e.g. "already approved" gets a
// dedicated message instead of the generic "something went wrong".

import 'dart:async';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:gospel_vox/features/admin/speakers/bloc/speakers_state.dart';
import 'package:gospel_vox/features/admin/speakers/data/speaker_model.dart';
import 'package:gospel_vox/features/admin/speakers/data/speakers_repository.dart';

class SpeakerDetailCubit extends Cubit<SpeakerDetailState> {
  final SpeakersRepository _repository;

  // Live subscription to the priest doc, kept open for the page's
  // lifetime so a profile edit by the priest (or a status change from
  // the moderation CF) reflects on the admin screen within ~1s with no
  // manual refresh. Cancelled in close().
  StreamSubscription<SpeakerModel>? _detailSub;

  SpeakerDetailCubit(this._repository) : super(SpeakerDetailInitial());

  // Subscribes to the live priest doc. The first snapshot replaces the
  // loading shimmer; every later snapshot keeps the profile fresh.
  //
  // We deliberately DON'T overwrite a moderation action that's in
  // flight (SpeakerDetailActionInProgress) or the success state that's
  // about to pop the page (SpeakerDetailActionSuccess) — a passive
  // data refresh only matters while the admin is actually viewing the
  // profile, and clobbering those transient states would either hide
  // the progress spinner or cancel the auto-pop.
  Future<void> loadDetail(String uid) async {
    emit(SpeakerDetailLoading());
    await _detailSub?.cancel();
    _detailSub = _repository.watchSpeakerDetail(uid).listen(
      (speaker) {
        if (isClosed) return;
        final current = state;
        if (current is SpeakerDetailActionInProgress ||
            current is SpeakerDetailActionSuccess) {
          return;
        }
        emit(SpeakerDetailLoaded(speaker));
      },
      onError: (Object e, StackTrace st) {
        if (isClosed) return;
        final existing = _currentSpeaker();
        if (e is FirebaseException && e.code == 'not-found') {
          // Server-confirmed removal — surface it, but keep any
          // profile we already have so the admin isn't dumped to a
          // blank error screen mid-review.
          emit(SpeakerDetailError('Speaker not found.', speaker: existing));
        } else if (existing == null) {
          // No profile on screen yet (failure on first load) — show
          // the full-screen error so the shimmer doesn't hang forever.
          debugPrint('[SpeakerDetailCubit] watch failed: $e\n$st');
          emit(SpeakerDetailError('Failed to load speaker details.'));
        } else {
          // Transient listener blip while a profile is already shown —
          // log it but keep the profile visible.
          debugPrint('[SpeakerDetailCubit] watch error (kept profile): $e');
        }
      },
    );
  }

  Future<void> approve() async {
    await _runAction(
      actionName: 'approving',
      successMessage: 'Speaker approved successfully',
      call: () => _repository.approve(_currentSpeakerUid!),
    );
  }

  Future<void> reject(String reason) async {
    await _runAction(
      actionName: 'rejecting',
      successMessage: 'Speaker application rejected',
      call: () => _repository.reject(_currentSpeakerUid!, reason),
    );
  }

  Future<void> suspend() async {
    await _runAction(
      actionName: 'suspending',
      successMessage: 'Speaker suspended',
      call: () => _repository.suspend(_currentSpeakerUid!),
    );
  }

  Future<void> unsuspend() async {
    await _runAction(
      actionName: 'unsuspending',
      successMessage: 'Speaker reactivated',
      call: () => _repository.unsuspend(_currentSpeakerUid!),
    );
  }

  // Resolves the current speaker from whichever state we're in.
  // Includes SpeakerDetailError(speaker: ...) so retry-after-error
  // actually works — without this, the first CF failure would strand
  // the admin on an error state with no way to retry short of
  // reopening the page.
  SpeakerModel? _currentSpeaker() {
    final current = state;
    if (current is SpeakerDetailLoaded) return current.speaker;
    if (current is SpeakerDetailActionInProgress) return current.speaker;
    if (current is SpeakerDetailError) return current.speaker;
    return null;
  }

  String? get _currentSpeakerUid => _currentSpeaker()?.uid;

  // Shared runner so the four mutation methods above don't each
  // duplicate the same try/catch mess. Carries the prior speaker
  // through every state transition so the page never goes blank,
  // and accepts Error(speaker: ...) as a valid starting point so
  // a transient network failure doesn't trap the admin.
  Future<void> _runAction({
    required String actionName,
    required String successMessage,
    required Future<void> Function() call,
  }) async {
    final speaker = _currentSpeaker();
    if (speaker == null) return;

    try {
      emit(SpeakerDetailActionInProgress(speaker, actionName));
      await call();
      if (isClosed) return;
      emit(SpeakerDetailActionSuccess(speaker, successMessage));
    } on TimeoutException {
      if (isClosed) return;
      emit(SpeakerDetailError(
        'The server took too long to respond. '
        'Check your connection and try again.',
        speaker: speaker,
      ));
    } on SocketException {
      if (isClosed) return;
      emit(SpeakerDetailError(
        'No internet connection. Please reconnect and try again.',
        speaker: speaker,
      ));
    } on FirebaseFunctionsException catch (e) {
      if (isClosed) return;
      emit(SpeakerDetailError(
        _humaniseCfError(e),
        speaker: speaker,
      ));
    } catch (e, st) {
      debugPrint('[SpeakerDetailCubit] action failed: $e\n$st');
      if (isClosed) return;
      emit(SpeakerDetailError(
        'Something went wrong. Please try again.',
        speaker: speaker,
      ));
    }
  }

  // Translates the Cloud Function's typed error codes into copy the
  // admin can act on. We ALSO debugPrint the raw exception so that
  // when an admin reports "it says Action failed", we can trace the
  // actual code without asking them to reproduce.
  //
  // The "approveRejectPriest" CF must be deployed for any moderation
  // to work; if it's still the old unimplemented stub the caller
  // sees 'unimplemented' and we say so clearly.
  String _humaniseCfError(FirebaseFunctionsException e) {
    debugPrint(
      '[SpeakerDetailCubit] CF error: code="${e.code}" '
      'message="${e.message}" details="${e.details}"',
    );

    switch (e.code) {
      case 'failed-precondition':
        // e.message is written by the CF itself (e.g. "Cannot suspend
        // a speaker whose status is 'pending'") and is always
        // admin-readable.
        return e.message ?? 'This action is no longer valid.';
      case 'not-found':
        return 'Speaker not found. They may have been removed.';
      case 'permission-denied':
        return "You don't have permission. "
            'Make sure you are signed in as an admin.';
      case 'invalid-argument':
        return e.message ?? 'Invalid input.';
      case 'unauthenticated':
        return 'Your session expired. Please sign in again.';
      case 'unimplemented':
        // Almost always means the CF hasn't been deployed (or was
        // redeployed from an old branch). Point the admin at the
        // likely cause instead of "please try again" which doesn't
        // help because trying again won't fix a missing deploy.
        return 'This action is not available yet. '
            'Please contact support if the issue persists.';
      case 'unavailable':
        return 'Service is temporarily unavailable. '
            'Please try again in a moment.';
      case 'deadline-exceeded':
        return 'The server took too long. Please try again.';
      case 'internal':
        return e.message ?? 'A server error occurred. Please try again.';
      default:
        // Surface whatever the CF wrote rather than a generic
        // message — the CF author usually said something useful.
        return e.message ?? 'Action failed. Please try again.';
    }
  }

  // Tear down the live priest-doc listener when the page closes so the
  // snapshot subscription doesn't outlive the cubit.
  @override
  Future<void> close() {
    _detailSub?.cancel();
    return super.close();
  }
}
