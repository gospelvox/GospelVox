// Shared chat UI used by both user and priest sides. The only
// side-specific knobs are:
//   • `isUserSide` — toggles the low-balance warning strip and picks
//     which party's photo/name renders in the top bar
//   • the post-end navigation target — handled by the surrounding
//     page, not this widget
//
// Keeping it shared means bubbles, input bar, timer pill, and the
// end-session sheet all stay identical between sides, which is a
// real trust signal for the user ("what I see is what the priest
// sees").

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:gospel_vox/core/theme/app_colors.dart';
import 'package:gospel_vox/core/widgets/app_snackbar.dart';
import 'package:gospel_vox/features/shared/bloc/chat_session_cubit.dart';
import 'package:gospel_vox/features/shared/bloc/chat_session_state.dart';
import 'package:gospel_vox/features/shared/data/session_model.dart';

// Forest green used only for the "In session" online dot here.
// Promoting this to AppColors would be premature for a one-off.
const Color _kSessionGreen = Color(0xFF2E7D4F);

typedef ChatEndedCallback = void Function(
  BuildContext context,
  ChatSessionEnded state,
);

class ChatSessionView extends StatefulWidget {
  final String sessionId;
  final bool isUserSide;
  final String currentUid;
  // Called when the session transitions to ChatSessionEnded. The
  // surrounding page decides where to navigate (user → post-session;
  // priest → session-summary) so this widget stays route-agnostic.
  final ChatEndedCallback onEnded;

  const ChatSessionView({
    super.key,
    required this.sessionId,
    required this.isUserSide,
    required this.currentUid,
    required this.onEnded,
  });

  @override
  State<ChatSessionView> createState() => _ChatSessionViewState();
}

class _ChatSessionViewState extends State<ChatSessionView> {
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final FocusNode _focusNode = FocusNode();

  // Track the last message id we've seen so we only auto-scroll when
  // a new one actually arrives, not on every state rebuild (the
  // elapsed timer rebuilds every second).
  String? _lastMessageId;

  @override
  void dispose() {
    _messageController.dispose();
    _scrollController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  // Senders are identified by uid on the wire. For `senderName` we
  // prefer the denormalised name already on the session doc so both
  // sides see a consistent label even if Firebase Auth hasn't
  // populated displayName yet.
  String _currentName(SessionModel session) {
    if (widget.isUserSide) {
      return session.userName.isNotEmpty ? session.userName : 'User';
    }
    return session.priestName.isNotEmpty ? session.priestName : 'Speaker';
  }

  Future<void> _sendMessage(SessionModel session) async {
    final text = _messageController.text.trim();
    if (text.isEmpty) return;

    final cubit = context.read<ChatSessionCubit>();
    final name = _currentName(session);

    try {
      await cubit.sendMessage(
        senderId: widget.currentUid,
        senderName: name,
        text: text,
      );
      if (!mounted) return;
      _messageController.clear();
    } catch (_) {
      if (!mounted) return;
      AppSnackBar.error(context, 'Could not send. Try again.');
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // The user must explicitly tap End Session — silent hardware-
      // back exits would leave a live session open on the server.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _showEndConfirmation();
      },
      child: Scaffold(
        backgroundColor: AppColors.background,
        body: BlocConsumer<ChatSessionCubit, ChatSessionState>(
          listenWhen: (prev, next) =>
              next is ChatSessionEnded || next is ChatSessionError,
          listener: (context, state) {
            if (state is ChatSessionEnded) {
              widget.onEnded(context, state);
            } else if (state is ChatSessionError) {
              AppSnackBar.error(context, state.message);
            }
          },
          builder: (context, state) {
            if (state is ChatSessionActive) {
              _maybeAutoScroll(state.messages);
              return _buildActive(state);
            }
            if (state is ChatSessionEnded) {
              // Brief bridge state — the listener has already fired
              // navigation, we just render a neutral screen instead
              // of a black flash.
              return const _CenteredLoader();
            }
            return const _CenteredLoader();
          },
        ),
      ),
    );
  }

  Widget _buildActive(ChatSessionActive state) {
    final session = state.session;
    final otherPhoto = widget.isUserSide
        ? session.priestPhotoUrl
        : session.userPhotoUrl;
    final otherName = widget.isUserSide
        ? (session.priestName.isNotEmpty ? session.priestName : 'Speaker')
        : (session.userName.isNotEmpty ? session.userName : 'User');
    final showLowBalance =
        widget.isUserSide && state.isLowBalance && !state.isEnding;

    return SafeArea(
      bottom: false,
      top: false,
      child: Column(
        children: [
          _ChatTopBar(
            photoUrl: otherPhoto,
            name: otherName,
            elapsed: state.formattedTime,
            isEnding: state.isEnding,
            onEndTap: _showEndConfirmation,
          ),
          if (showLowBalance)
            _LowBalanceStrip(
              remaining: state.remainingBalance,
            ),
          Expanded(
            child: state.messages.isEmpty
                ? const _EmptyChat()
                : _MessageList(
                    controller: _scrollController,
                    messages: state.messages,
                    currentUid: widget.currentUid,
                  ),
          ),
          _MessageInputBar(
            controller: _messageController,
            focusNode: _focusNode,
            isSending: state.isSendingMessage || state.isEnding,
            onSend: () => _sendMessage(session),
          ),
        ],
      ),
    );
  }

  void _maybeAutoScroll(List<ChatMessage> messages) {
    if (messages.isEmpty) {
      _lastMessageId = null;
      return;
    }
    final latestId = messages.last.id;
    if (latestId == _lastMessageId) return;
    _lastMessageId = latestId;

    // Post-frame so the layout settles before we jump — otherwise
    // position.maxScrollExtent is the pre-insert value and we stop
    // one bubble short.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOutCubic,
      );
    });
  }

  void _showEndConfirmation() {
    final cubit = context.read<ChatSessionCubit>();
    final state = cubit.state;
    if (state is! ChatSessionActive || state.isEnding) return;

    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surfaceWhite,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) {
        return _EndSessionSheet(
          formattedTime: state.formattedTime,
          currentCost: state.currentCost,
          isUserSide: widget.isUserSide,
          onCancel: () => Navigator.of(sheetContext).pop(),
          onConfirm: () {
            Navigator.of(sheetContext).pop();
            cubit.endSession(
              reason: widget.isUserSide ? 'user_ended' : 'priest_ended',
            );
          },
        );
      },
    );
  }
}

// ─── Top bar ──────────────────────────────────────────────

class _ChatTopBar extends StatelessWidget {
  final String photoUrl;
  final String name;
  final String elapsed;
  final bool isEnding;
  final VoidCallback onEndTap;

  const _ChatTopBar({
    required this.photoUrl,
    required this.name,
    required this.elapsed,
    required this.isEnding,
    required this.onEndTap,
  });

  @override
  Widget build(BuildContext context) {
    final topInset = MediaQuery.of(context).padding.top;

    return Container(
      padding: EdgeInsets.fromLTRB(16, topInset + 8, 16, 12),
      decoration: BoxDecoration(
        color: AppColors.surfaceWhite,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          _Avatar(photoUrl: photoUrl, name: name),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.inter(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: AppColors.deepDarkBrown,
                  ),
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    Container(
                      width: 6,
                      height: 6,
                      decoration: const BoxDecoration(
                        shape: BoxShape.circle,
                        color: _kSessionGreen,
                      ),
                    ),
                    const SizedBox(width: 5),
                    Text(
                      'In session',
                      style: GoogleFonts.inter(
                        fontSize: 12,
                        fontWeight: FontWeight.w400,
                        color: _kSessionGreen,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          _TimerPill(elapsed: elapsed),
          const SizedBox(width: 10),
          _EndButton(onTap: onEndTap, disabled: isEnding),
        ],
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  final String photoUrl;
  final String name;

  const _Avatar({required this.photoUrl, required this.name});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: const Color(0xFFF7F5F2),
        image: photoUrl.isNotEmpty
            ? DecorationImage(
                image: NetworkImage(photoUrl),
                fit: BoxFit.cover,
              )
            : null,
      ),
      child: photoUrl.isEmpty
          ? Center(
              child: Text(
                name.isNotEmpty ? name[0].toUpperCase() : '?',
                style: GoogleFonts.inter(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: AppColors.primaryBrown,
                ),
              ),
            )
          : null,
    );
  }
}

class _TimerPill extends StatelessWidget {
  final String elapsed;
  const _TimerPill({required this.elapsed});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.primaryBrown.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.access_time_rounded,
            size: 14,
            color: AppColors.primaryBrown,
          ),
          const SizedBox(width: 6),
          Text(
            elapsed,
            style: GoogleFonts.inter(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: AppColors.primaryBrown,
            ),
          ),
        ],
      ),
    );
  }
}

class _EndButton extends StatefulWidget {
  final VoidCallback onTap;
  final bool disabled;

  const _EndButton({required this.onTap, required this.disabled});

  @override
  State<_EndButton> createState() => _EndButtonState();
}

class _EndButtonState extends State<_EndButton> {
  double _scale = 1.0;

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (_) {
        if (!widget.disabled) setState(() => _scale = 0.95);
      },
      onPointerUp: (_) => setState(() => _scale = 1.0),
      onPointerCancel: (_) => setState(() => _scale = 1.0),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.disabled ? null : widget.onTap,
        child: AnimatedScale(
          scale: _scale,
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
          child: Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: AppColors.errorRed.withValues(
                alpha: widget.disabled ? 0.04 : 0.08,
              ),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              'End',
              style: GoogleFonts.inter(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: AppColors.errorRed.withValues(
                  alpha: widget.disabled ? 0.4 : 1.0,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Low-balance strip ─────────────────────────────────────

class _LowBalanceStrip extends StatelessWidget {
  final int remaining;
  const _LowBalanceStrip({required this.remaining});

  @override
  Widget build(BuildContext context) {
    return AnimatedSize(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOutCubic,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        color: AppColors.errorRed.withValues(alpha: 0.06),
        child: Row(
          children: [
            Icon(
              Icons.warning_amber_rounded,
              size: 16,
              color: AppColors.errorRed,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Low balance: $remaining coins remaining',
                style: GoogleFonts.inter(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: AppColors.errorRed,
                ),
              ),
            ),
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              // Can't leave a live session to top up — end first.
              // Surfacing that explicitly stops the user walking
              // into a dead route.
              onTap: () => AppSnackBar.info(
                context,
                'End the session first to add coins.',
              ),
              child: Text(
                'Add Coins',
                style: GoogleFonts.inter(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: AppColors.primaryBrown,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Message list + bubbles ────────────────────────────────

class _MessageList extends StatelessWidget {
  final ScrollController controller;
  final List<ChatMessage> messages;
  final String currentUid;

  const _MessageList({
    required this.controller,
    required this.messages,
    required this.currentUid,
  });

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      controller: controller,
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      itemCount: messages.length,
      itemBuilder: (_, index) {
        final msg = messages[index];
        final isMe = msg.senderId == currentUid;
        final showTimestamp = _shouldShowTimestamp(index, messages);
        return _ChatBubble(
          message: msg,
          isMe: isMe,
          showTimestamp: showTimestamp,
        );
      },
    );
  }

  // First message always gets a date stamp. Subsequent ones get one
  // only when there's a >5-minute gap — keeps the transcript
  // readable without cluttering a fast back-and-forth.
  bool _shouldShowTimestamp(int index, List<ChatMessage> messages) {
    if (index == 0) return true;
    final prev = messages[index - 1].createdAt;
    final curr = messages[index].createdAt;
    if (prev == null || curr == null) return false;
    return curr.difference(prev).inMinutes >= 5;
  }
}

class _ChatBubble extends StatelessWidget {
  final ChatMessage message;
  final bool isMe;
  final bool showTimestamp;

  const _ChatBubble({
    required this.message,
    required this.isMe,
    required this.showTimestamp,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        bottom: 6,
        left: isMe ? 48 : 0,
        right: isMe ? 0 : 48,
      ),
      child: Column(
        crossAxisAlignment:
            isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          if (showTimestamp)
            Padding(
              padding: const EdgeInsets.only(bottom: 8, top: 4),
              child: Center(
                child: Text(
                  _formatTimestamp(message.createdAt),
                  style: GoogleFonts.inter(
                    fontSize: 11,
                    fontWeight: FontWeight.w400,
                    color: AppColors.muted,
                  ),
                ),
              ),
            ),
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: isMe
                  ? AppColors.primaryBrown
                  : AppColors.surfaceWhite,
              borderRadius: BorderRadius.only(
                topLeft: const Radius.circular(16),
                topRight: const Radius.circular(16),
                bottomLeft: Radius.circular(isMe ? 16 : 4),
                bottomRight: Radius.circular(isMe ? 4 : 16),
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.04),
                  blurRadius: 6,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Text(
              message.text,
              style: GoogleFonts.inter(
                fontSize: 14,
                fontWeight: FontWeight.w400,
                height: 1.45,
                color: isMe ? Colors.white : AppColors.deepDarkBrown,
              ),
            ),
          ),
          const SizedBox(height: 2),
          Text(
            _formatTime(message.createdAt),
            style: GoogleFonts.inter(
              fontSize: 10,
              fontWeight: FontWeight.w400,
              color: AppColors.muted.withValues(alpha: 0.5),
            ),
          ),
        ],
      ),
    );
  }
}

String _formatTimestamp(DateTime? dt) {
  if (dt == null) return '';
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final sameDay = DateTime(dt.year, dt.month, dt.day) == today;
  if (sameDay) return 'Today';
  const weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  final wd = weekdays[dt.weekday - 1];
  final mo = months[dt.month - 1];
  return '$wd, $mo ${dt.day}';
}

String _formatTime(DateTime? dt) {
  if (dt == null) return '';
  final hour24 = dt.hour;
  final isAm = hour24 < 12;
  var hour = hour24 % 12;
  if (hour == 0) hour = 12;
  final minute = dt.minute.toString().padLeft(2, '0');
  return '$hour:$minute ${isAm ? 'AM' : 'PM'}';
}

// ─── Empty state ──────────────────────────────────────────

class _EmptyChat extends StatelessWidget {
  const _EmptyChat();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.chat_bubble_outline_rounded,
            size: 48,
            color: AppColors.muted.withValues(alpha: 0.2),
          ),
          const SizedBox(height: 16),
          Text(
            'Start the conversation',
            style: GoogleFonts.inter(
              fontSize: 15,
              fontWeight: FontWeight.w500,
              color: AppColors.muted,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Say hello to begin your session',
            style: GoogleFonts.inter(
              fontSize: 13,
              fontWeight: FontWeight.w400,
              color: AppColors.muted.withValues(alpha: 0.6),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Input bar ────────────────────────────────────────────

class _MessageInputBar extends StatefulWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final bool isSending;
  final VoidCallback onSend;

  const _MessageInputBar({
    required this.controller,
    required this.focusNode,
    required this.isSending,
    required this.onSend,
  });

  @override
  State<_MessageInputBar> createState() => _MessageInputBarState();
}

class _MessageInputBarState extends State<_MessageInputBar> {
  double _sendScale = 1.0;

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).padding.bottom;

    return Container(
      padding: EdgeInsets.fromLTRB(16, 8, 8, bottomInset + 8),
      decoration: BoxDecoration(
        color: AppColors.surfaceWhite,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 8,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Container(
              constraints: const BoxConstraints(maxHeight: 100),
              decoration: BoxDecoration(
                color: const Color(0xFFF7F5F2),
                borderRadius: BorderRadius.circular(24),
              ),
              child: TextField(
                controller: widget.controller,
                focusNode: widget.focusNode,
                maxLines: null,
                minLines: 1,
                textCapitalization: TextCapitalization.sentences,
                textInputAction: TextInputAction.newline,
                inputFormatters: [
                  LengthLimitingTextInputFormatter(1000),
                ],
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.w400,
                  color: AppColors.deepDarkBrown,
                ),
                decoration: InputDecoration(
                  hintText: 'Type a message…',
                  hintStyle: GoogleFonts.inter(
                    fontSize: 14,
                    fontWeight: FontWeight.w400,
                    color: AppColors.muted.withValues(alpha: 0.5),
                  ),
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 18,
                    vertical: 10,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Listener(
            onPointerDown: (_) {
              if (!widget.isSending) setState(() => _sendScale = 0.9);
            },
            onPointerUp: (_) => setState(() => _sendScale = 1.0),
            onPointerCancel: (_) => setState(() => _sendScale = 1.0),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: widget.isSending ? null : widget.onSend,
              child: AnimatedScale(
                scale: _sendScale,
                duration: const Duration(milliseconds: 120),
                curve: Curves.easeOut,
                child: Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: AppColors.primaryBrown.withValues(
                      alpha: widget.isSending ? 0.5 : 1.0,
                    ),
                    boxShadow: widget.isSending
                        ? null
                        : [
                            BoxShadow(
                              color: AppColors.primaryBrown
                                  .withValues(alpha: 0.2),
                              blurRadius: 8,
                              offset: const Offset(0, 2),
                            ),
                          ],
                  ),
                  child: widget.isSending
                      ? const Center(
                          child: SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              color: Colors.white,
                              strokeWidth: 2,
                            ),
                          ),
                        )
                      : const Icon(
                          Icons.send_rounded,
                          size: 20,
                          color: Colors.white,
                        ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── End-session confirmation sheet ───────────────────────

class _EndSessionSheet extends StatelessWidget {
  final String formattedTime;
  final int currentCost;
  final bool isUserSide;
  final VoidCallback onCancel;
  final VoidCallback onConfirm;

  const _EndSessionSheet({
    required this.formattedTime,
    required this.currentCost,
    required this.isUserSide,
    required this.onCancel,
    required this.onConfirm,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.muted.withValues(alpha: 0.25),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 20),
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.errorRed.withValues(alpha: 0.08),
              ),
              child: Icon(
                Icons.call_end_rounded,
                size: 28,
                color: AppColors.errorRed,
              ),
            ),
            const SizedBox(height: 20),
            Text(
              'End Session?',
              style: GoogleFonts.inter(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: AppColors.deepDarkBrown,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              isUserSide
                  ? 'You will be charged for the time spent so far. '
                      'This action cannot be undone.'
                  : 'The user will be charged for the time spent so far. '
                      'This action cannot be undone.',
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(
                fontSize: 13,
                fontWeight: FontWeight.w400,
                height: 1.5,
                color: AppColors.muted,
              ),
            ),
            const SizedBox(height: 16),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.background,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Duration',
                        style: GoogleFonts.inter(
                          fontSize: 13,
                          fontWeight: FontWeight.w400,
                          color: AppColors.muted,
                        ),
                      ),
                      Text(
                        formattedTime,
                        style: GoogleFonts.inter(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: AppColors.deepDarkBrown,
                        ),
                      ),
                    ],
                  ),
                  if (isUserSide) ...[
                    const SizedBox(height: 6),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'Est. charge',
                          style: GoogleFonts.inter(
                            fontSize: 13,
                            fontWeight: FontWeight.w400,
                            color: AppColors.muted,
                          ),
                        ),
                        Text(
                          '$currentCost coins',
                          style: GoogleFonts.inter(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: AppColors.errorRed,
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 24),
            Row(
              children: [
                Expanded(
                  child: _SheetBtn(
                    label: 'Continue',
                    filled: false,
                    color: AppColors.primaryBrown,
                    onTap: onCancel,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _SheetBtn(
                    label: 'End Session',
                    filled: true,
                    color: AppColors.errorRed,
                    onTap: onConfirm,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SheetBtn extends StatefulWidget {
  final String label;
  final bool filled;
  final Color color;
  final VoidCallback onTap;

  const _SheetBtn({
    required this.label,
    required this.filled,
    required this.color,
    required this.onTap,
  });

  @override
  State<_SheetBtn> createState() => _SheetBtnState();
}

class _SheetBtnState extends State<_SheetBtn> {
  double _scale = 1.0;

  @override
  Widget build(BuildContext context) {
    final filled = widget.filled;
    return Listener(
      onPointerDown: (_) => setState(() => _scale = 0.97),
      onPointerUp: (_) => setState(() => _scale = 1.0),
      onPointerCancel: (_) => setState(() => _scale = 1.0),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _scale,
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
          child: Container(
            height: 50,
            decoration: BoxDecoration(
              color: filled ? widget.color : Colors.transparent,
              borderRadius: BorderRadius.circular(14),
              border: filled
                  ? null
                  : Border.all(
                      color: widget.color.withValues(alpha: 0.35),
                      width: 1.5,
                    ),
            ),
            child: Center(
              child: Text(
                widget.label,
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: filled ? Colors.white : widget.color,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Loader ────────────────────────────────────────────────

class _CenteredLoader extends StatelessWidget {
  const _CenteredLoader();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: CircularProgressIndicator(
        color: AppColors.primaryBrown,
        strokeWidth: 2.5,
      ),
    );
  }
}
