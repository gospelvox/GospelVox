// User's live chat screen. Thin wrapper around the shared
// ChatSessionView — exists as its own widget so the route builder
// can provide the cubit, seed it with `isUserSide: true`, and
// decide where to navigate when the session ends.

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:gospel_vox/features/shared/bloc/chat_session_state.dart';
import 'package:gospel_vox/features/shared/widgets/chat_session_view.dart';

class ChatSessionPage extends StatelessWidget {
  final String sessionId;

  const ChatSessionPage({super.key, required this.sessionId});

  @override
  Widget build(BuildContext context) {
    // currentUser is guaranteed non-null here — the router's redirect
    // already bounces unauthenticated traffic to /select-role.
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';

    return ChatSessionView(
      sessionId: sessionId,
      isUserSide: true,
      currentUid: uid,
      onEnded: (ctx, state) => _onEnded(ctx, state),
    );
  }

  void _onEnded(BuildContext context, ChatSessionEnded state) {
    // go (not push) so the chat can't be reached via the back stack
    // after it ends — anything on the post-session screen represents
    // a fresh starting point.
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
