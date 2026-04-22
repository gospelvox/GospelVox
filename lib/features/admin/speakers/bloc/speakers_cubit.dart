// Loads the three speaker lists (pending/approved/suspended) and the
// badge counts in one shot so the list page can drop the user on any
// tab without a loading flash.
//
// Intentionally not using a stream: the admin doesn't need realtime
// for moderation — a pull-to-refresh pattern is cheaper and clearer
// (no silent reorders mid-review).

import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:gospel_vox/features/admin/speakers/bloc/speakers_state.dart';
import 'package:gospel_vox/features/admin/speakers/data/speaker_model.dart';
import 'package:gospel_vox/features/admin/speakers/data/speakers_repository.dart';

class SpeakersCubit extends Cubit<SpeakersState> {
  final SpeakersRepository _repository;

  SpeakersCubit(this._repository) : super(SpeakersInitial());

  Future<void> loadSpeakers() async {
    try {
      // Only flip to Loading on first load / after an error.
      // Refresh-while-loaded keeps the previous lists visible so the
      // RefreshIndicator's own spinner is the only loading UI —
      // avoids the content jumping away under the user's finger.
      if (state is! SpeakersLoaded) {
        emit(SpeakersLoading());
      }

      final results = await Future.wait([
        _repository.getSpeakers('pending'),
        _repository.getSpeakers('approved'),
        _repository.getSpeakers('suspended'),
        _repository.getStatusCounts(),
      ]);

      if (isClosed) return;
      emit(SpeakersLoaded(
        pending: results[0] as List<SpeakerModel>,
        approved: results[1] as List<SpeakerModel>,
        suspended: results[2] as List<SpeakerModel>,
        counts: results[3] as Map<String, int>,
      ));
    } on TimeoutException {
      if (isClosed) return;
      if (state is SpeakersLoaded) return; // keep current data
      emit(SpeakersError('Taking too long. Check your connection.'));
    } catch (_) {
      if (isClosed) return;
      if (state is SpeakersLoaded) return;
      emit(SpeakersError('Failed to load speakers.'));
    }
  }
}
