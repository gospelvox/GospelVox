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
import 'package:gospel_vox/features/user/session/widgets/session_rating_dialog.dart';

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

  // Show the rating dialog inline instead of routing to a dedicated
  // post-session page. The dialog has no easy dismiss path other
  // than Submit / "Maybe later", so the user is nudged to rate but
  // never trapped. Once the dialog closes (either path) we replace
  // the route with /user so the back stack can't bounce into the
  // settled call screen.
  Future<void> _onEnded(BuildContext context, VoiceCallEnded state) async {
    await SessionRatingDialog.show(context, state.session);
    if (!context.mounted) return;
    context.go('/user');
  }
}
