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
    // Every end reason — priest_ended, user_ended, balance_zero,
    // watchdog_timeout, network_disconnected, connection_failed,
    // external — routes to the same summary page so the priest always
    // sees the identical full breakdown (duration, gross, commission,
    // net), no matter how the session ended.
    context.go(
      '/session/priest-summary',
      extra: {
        'summary': state.summary,
        'session': state.session,
        'endReason': state.endReason,
      },
    );
  }
}
