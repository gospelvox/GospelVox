// Priest's live voice call screen. Counterpart to PriestChatSessionPage
// — same shared view, different cubit wiring (isUserSide: false, so
// no heartbeat or billing here) and a different terminal route.
//
// AgoraService is constructed per-page like in VoiceCallPage; see
// the note in injection_container.dart for why it isn't registered
// globally.

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import 'package:gospel_vox/core/services/agora_service.dart';
import 'package:gospel_vox/core/services/injection_container.dart';
import 'package:gospel_vox/features/shared/bloc/voice_call_cubit.dart';
import 'package:gospel_vox/features/shared/bloc/voice_call_state.dart';
import 'package:gospel_vox/features/shared/data/session_repository.dart';
import 'package:gospel_vox/features/shared/widgets/voice_call_view.dart';

class PriestVoiceCallPage extends StatelessWidget {
  final String sessionId;

  const PriestVoiceCallPage({super.key, required this.sessionId});

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) => VoiceCallCubit(
        sl<SessionRepository>(),
        AgoraService(),
      )..startCall(sessionId: sessionId, isUserSide: false),
      child: VoiceCallView(
        sessionId: sessionId,
        isUserSide: false,
        onEnded: _onEnded,
      ),
    );
  }

  void _onEnded(BuildContext context, VoiceCallEnded state) {
    // Branch on who/what ended the call:
    //   • priest_ended → priest tapped End → normal summary page.
    //   • everything else (user_ended, balance_zero, watchdog_timeout,
    //     external) → SessionDroppedPage so we explain the drop and
    //     show what they earned.
    if (state.endReason == 'priest_ended') {
      context.go(
        '/session/priest-summary',
        extra: {
          'summary': state.summary,
          'session': state.session,
          'endReason': state.endReason,
        },
      );
    } else {
      context.go(
        '/priest/session-dropped',
        extra: {
          'session': state.session,
          'earned': state.summary.priestEarnings,
          'duration': state.summary.durationMinutes,
          'endReason': state.endReason,
        },
      );
    }
  }
}
