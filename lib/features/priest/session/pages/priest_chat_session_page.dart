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
