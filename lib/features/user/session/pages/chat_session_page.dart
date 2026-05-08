// User's live chat screen. Thin wrapper around the shared
// ChatSessionView — exists as its own widget so the route builder
// can provide the cubit, seed it with `isUserSide: true`, and
// decide where to navigate when the session ends.

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:gospel_vox/features/shared/bloc/chat_session_state.dart';
import 'package:gospel_vox/features/shared/widgets/chat_session_view.dart';
import 'package:gospel_vox/features/user/session/widgets/session_rating_dialog.dart';

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

  // Show the rating dialog inline instead of routing to a dedicated
  // post-session page. The dialog is non-dismissible-via-backdrop so
  // the user is nudged to rate before going home; "Maybe later"
  // remains as a visible-but-de-emphasised escape hatch. Once the
  // dialog closes we replace with /user so the back stack can't
  // bounce into the settled chat.
  Future<void> _onEnded(
    BuildContext context,
    ChatSessionEnded state,
  ) async {
    await SessionRatingDialog.show(context, state.session);
    if (!context.mounted) return;
    context.go('/user');
  }
}
