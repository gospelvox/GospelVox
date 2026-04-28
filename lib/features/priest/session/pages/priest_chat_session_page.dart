// Priest's live chat screen. Counterpart to the user's
// ChatSessionPage — same shared view, different cubit wiring
// (isUserSide: false) and different terminal route.

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:gospel_vox/features/shared/bloc/chat_session_state.dart';
import 'package:gospel_vox/features/shared/widgets/chat_session_view.dart';

class PriestChatSessionPage extends StatelessWidget {
  final String sessionId;

  const PriestChatSessionPage({super.key, required this.sessionId});

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';

    return ChatSessionView(
      sessionId: sessionId,
      isUserSide: false,
      currentUid: uid,
      onEnded: (ctx, state) => _onEnded(ctx, state),
    );
  }

  void _onEnded(BuildContext context, ChatSessionEnded state) {
    // Branch based on who/what ended the session:
    //   • priest_ended → priest deliberately tapped End → normal
    //     summary page (their own action, no surprise).
    //   • everything else (user_ended, balance_zero,
    //     watchdog_timeout, external) → SessionDroppedPage so we
    //     can reassure the priest the drop wasn't their fault and
    //     show them what they earned.
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
