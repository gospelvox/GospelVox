// User's live voice call screen. Counterpart to ChatSessionPage —
// thin wrapper around the shared VoiceCallView that wires up the
// cubit with isUserSide: true and decides where to navigate when
// the call ends.
//
// AgoraService and VoiceCallCubit are constructed inline (not from
// the DI container) because the engine holds native audio resources
// that must be lifecycle-bound to this widget instance. See the
// note in injection_container.dart for the same reason RazorpayService
// is constructed per-page rather than registered globally.

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import 'package:gospel_vox/core/services/agora_service.dart';
import 'package:gospel_vox/core/services/injection_container.dart';
import 'package:gospel_vox/features/shared/bloc/voice_call_cubit.dart';
import 'package:gospel_vox/features/shared/bloc/voice_call_state.dart';
import 'package:gospel_vox/features/shared/data/session_repository.dart';
import 'package:gospel_vox/features/shared/widgets/voice_call_view.dart';

class VoiceCallPage extends StatelessWidget {
  final String sessionId;

  const VoiceCallPage({super.key, required this.sessionId});

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) => VoiceCallCubit(
        sl<SessionRepository>(),
        AgoraService(),
      )..startCall(sessionId: sessionId, isUserSide: true),
      child: VoiceCallView(
        sessionId: sessionId,
        isUserSide: true,
        onEnded: _onEnded,
      ),
    );
  }

  void _onEnded(BuildContext context, VoiceCallEnded state) {
    // go (not push) so the call screen can't be reached via back —
    // the post-session screen is a fresh starting point.
    context.go(
      '/session/post',
      extra: {
        'summary': state.summary,
        'session': state.session,
        'endReason': state.endReason,
      },
    );
  }
}
