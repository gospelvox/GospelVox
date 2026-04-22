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

  SpeakerDetailCubit(this._repository) : super(SpeakerDetailInitial());

  Future<void> loadDetail(String uid) async {
    try {
      emit(SpeakerDetailLoading());
      final speaker = await _repository.getSpeakerDetail(uid);
      if (isClosed) return;
      emit(SpeakerDetailLoaded(speaker));
    } on TimeoutException {
      if (isClosed) return;
      emit(SpeakerDetailError(
        'Taking too long. Check your connection and try again.',
      ));
    } on SocketException {
      if (isClosed) return;
      emit(SpeakerDetailError(
        'No internet connection. Please reconnect and try again.',
      ));
    } on FirebaseException catch (e) {
      if (isClosed) return;
      if (e.code == 'not-found') {
        emit(SpeakerDetailError('Speaker not found.'));
      } else {
        emit(SpeakerDetailError('Failed to load speaker details.'));
      }
    } catch (e, st) {
      // Surface the raw error to logs so a wedged admin client can
      // tell us exactly what went wrong without shipping us a
      // screenshot of a generic error toast.
      debugPrint('[SpeakerDetailCubit] loadDetail failed: $e\n$st');
      if (isClosed) return;
      emit(SpeakerDetailError('Failed to load speaker details.'));
    }
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
}
