// Shared chat UI used by both user and priest sides. Side-specific
// knobs are limited to:
//   • `isUserSide` — drives the low-balance system message + the
//     in-chat recharge sheet (user only)
//   • `isUserSide` — also picks which party renders in the top bar
//   • the post-end navigation target — handled by the parent page
//
// Premium UX touches in this view:
//   • Burst grouping — consecutive messages from the same sender
//     within 30s share an avatar/name header
//   • Bubble entrance animation — 180ms fade + slide-up on first
//     paint, played once per bubble id (TweenAnimationBuilder)
//   • Typing indicator — soft 3-dot bouncer with "is typing…" or
//     "is composing a longer response…" after 10s of typing
//   • Long-press reactions — 🙏 ❤️ 🕊 popup, written via cubit
//   • Low-balance system message inline in the chat (looks like
//     the priest sent a friendly nudge) with Add Coins button
//   • Sending → sent status icons under outbound bubbles
//   • Haptic feedback on send / receive / low-balance / end
//
// Performance:
//   • Animations use TweenAnimationBuilder (no AnimationController
//     proliferation). One-shot — no rebuild storm.
//   • Auto-scroll only fires when the latest message id changes
//     (see _maybeAutoScroll), so the elapsed-second tick doesn't
//     thrash the list.
//   • Reaction sheet is an Overlay, not a Navigator route — no
//     route transitions, no rebuild of the chat below.

import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:gospel_vox/core/theme/app_colors.dart';
import 'package:gospel_vox/core/widgets/app_snackbar.dart';
import 'package:gospel_vox/features/shared/bloc/chat_session_cubit.dart';
import 'package:gospel_vox/features/shared/bloc/chat_session_state.dart';
import 'package:gospel_vox/features/shared/data/session_model.dart';
import 'package:gospel_vox/features/shared/widgets/recharge_sheet.dart';

// Forest green used only for the "In session" status pill here.
const Color _kSessionGreen = Color(0xFF2E7D4F);

// Reactions menu — kept short and on-brand for spiritual chat.
const List<String> _kReactionEmojis = ['🙏', '❤️', '🕊️'];

typedef ChatEndedCallback = void Function(
  BuildContext context,
  ChatSessionEnded state,
);

class ChatSessionView extends StatefulWidget {
  final String sessionId;
  final bool isUserSide;
  final String currentUid;
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

  // Track the last message id so auto-scroll only fires on a real
  // new message — otherwise the 1-second elapsed tick would thrash
  // the scroll position.
  String? _lastMessageId;

  // Tracks the previous low-balance state so we can fire haptic
  // feedback only on the rising edge (false → true), not every
  // time the chat rebuilds.
  bool _wasLowBalance = false;

  // Live connectivity state. Drives the offline pill in the top
  // bar so the user knows their messages aren't going through
  // before the watchdog quietly ends the session in the background.
  StreamSubscription<List<ConnectivityResult>>? _connSub;
  bool _isOffline = false;

  @override
  void initState() {
    super.initState();
    _setupConnectivity();
  }

  // Initialise + subscribe to connectivity changes. Both the
  // initial check and the stream go through the same _apply()
  // method so we don't have to reason about ordering.
  Future<void> _setupConnectivity() async {
    final conn = Connectivity();
    try {
      final initial = await conn.checkConnectivity();
      if (mounted) _applyConnectivity(initial);
    } catch (_) {
      // Best-effort — if the platform check fails we just leave
      // _isOffline at false. The chat still works; we just don't
      // surface an offline pill until the stream emits.
    }
    _connSub = conn.onConnectivityChanged.listen(_applyConnectivity);
  }

  void _applyConnectivity(List<ConnectivityResult> results) {
    if (!mounted) return;
    // ConnectivityResult.none is the only definitive "no network"
    // signal. We treat the empty-list edge as "unknown / online"
    // so a flaky platform call can't false-positive.
    final offline = results.isNotEmpty &&
        results.every((r) => r == ConnectivityResult.none);
    if (offline != _isOffline) {
      setState(() => _isOffline = offline);
    }
  }

  @override
  void dispose() {
    _connSub?.cancel();
    _messageController.dispose();
    _scrollController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  // Sender name comes from the denormalised session field — keeps
  // both sides consistent even if Firebase Auth's displayName is
  // momentarily missing.
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

    HapticFeedback.lightImpact();
    _messageController.clear();

    try {
      await cubit.sendMessage(
        senderId: widget.currentUid,
        senderName: name,
        text: text,
      );
    } catch (_) {
      if (!mounted) return;
      // Restore the user's text so they can retry instead of
      // having to retype.
      _messageController.text = text;
      AppSnackBar.error(context, 'Could not send. Try again.');
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
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
              _maybeBuzzOnLowBalance(state.isLowBalance);
              return _buildActive(state);
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
    // The OTHER side's typing fields drive our indicator.
    final otherTyping =
        widget.isUserSide ? session.priestTyping : session.userTyping;
    final otherTypingSince = widget.isUserSide
        ? session.priestTypingSince
        : session.userTypingSince;

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
            isOffline: _isOffline,
            onEndTap: _showEndConfirmation,
          ),
          Expanded(
            child: state.messages.isEmpty && !state.showIdleWarning
                ? const _EmptyChat()
                : _MessageList(
                    controller: _scrollController,
                    messages: state.messages,
                    currentUid: widget.currentUid,
                    isUserSide: widget.isUserSide,
                    showLowBalanceCard:
                        widget.isUserSide && state.isLowBalance,
                    showIdleWarning: state.showIdleWarning,
                    remainingBalance: state.remainingBalance,
                    onAddCoins: _openRecharge,
                    onReact: (msgId, emoji) =>
                        context.read<ChatSessionCubit>().toggleReaction(
                              messageId: msgId,
                              userId: widget.currentUid,
                              emoji: emoji,
                            ),
                  ),
          ),
          _TypingFooter(
            otherName: otherName,
            isTyping: otherTyping,
            typingSince: otherTypingSince,
          ),
          _MessageInputBar(
            controller: _messageController,
            focusNode: _focusNode,
            isSending: state.isSendingMessage || state.isEnding,
            onSend: () => _sendMessage(session),
            onChanged: (_) => context.read<ChatSessionCubit>().onUserTyping(),
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

    // Subtle haptic on inbound message arrival — never on our own.
    final latest = messages.last;
    final wasOurs = latest.senderId == widget.currentUid;
    final hadPrevious = _lastMessageId != null;
    if (!wasOurs && hadPrevious && !latest.isPending) {
      HapticFeedback.selectionClick();
    }

    _lastMessageId = latestId;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOutCubic,
      );
    });
  }

  void _maybeBuzzOnLowBalance(bool isLow) {
    if (isLow && !_wasLowBalance) {
      HapticFeedback.mediumImpact();
    }
    _wasLowBalance = isLow;
  }

  Future<void> _openRecharge() async {
    HapticFeedback.lightImpact();
    // Hand contextual copy to the sheet so the headline matches
    // what's actually happening — same pattern voice_call_view
    // uses. Generic copy is the fallback when the cubit isn't
    // in the active state for any reason.
    final cubitState = context.read<ChatSessionCubit>().state;
    int? balance;
    String? headline;
    String? subtext;
    if (cubitState is ChatSessionActive) {
      balance = cubitState.remainingBalance;
      final ctx = recomputeRechargeContext(
        ratePerMinute: cubitState.session.ratePerMinute,
        currentBalance: cubitState.remainingBalance,
      );
      headline =
          'Minimum balance: ₹${ctx.requiredFor5Min} (for 5 minutes)';
      final priestName = cubitState.session.priestName;
      if (ctx.deficit > 0) {
        subtext = priestName.isNotEmpty
            ? 'Add ₹${ctx.deficit} more to keep chatting '
                'with $priestName'
            : 'Add ₹${ctx.deficit} more to keep your chat going';
      }
    }
    await RechargeSheet.show(
      context,
      currentBalance: balance,
      infoHeadline: headline,
      infoSubtext: subtext,
    );
    // The cubit's user-balance stream handles the new balance —
    // we don't need to do anything else here.
  }

  void _showEndConfirmation() {
    final cubit = context.read<ChatSessionCubit>();
    final state = cubit.state;
    if (state is! ChatSessionActive || state.isEnding) return;

    HapticFeedback.lightImpact();
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
            HapticFeedback.heavyImpact();
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
  // True when the device has no network connectivity. Surfaces a
  // small amber pill in the bar so the user understands why their
  // messages aren't going through.
  final bool isOffline;
  final VoidCallback onEndTap;

  const _ChatTopBar({
    required this.photoUrl,
    required this.name,
    required this.elapsed,
    required this.isEnding,
    required this.isOffline,
    required this.onEndTap,
  });

  @override
  Widget build(BuildContext context) {
    final topInset = MediaQuery.of(context).padding.top;

    return Container(
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
      child: Column(
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(16, topInset + 8, 16, 12),
            child: Row(
              children: [
                _Avatar(
                    photoUrl: photoUrl, name: name, size: 40, fontSize: 16),
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
          ),
          // Offline strip slides into the bar from the bottom when
          // connectivity drops. AnimatedSize keeps the transition
          // smooth and reclaims the space when we come back online.
          AnimatedSize(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            child: isOffline
                ? const _OfflineStrip()
                : const SizedBox(width: double.infinity, height: 0),
          ),
        ],
      ),
    );
  }
}

class _OfflineStrip extends StatelessWidget {
  const _OfflineStrip();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: AppColors.amberGold.withValues(alpha: 0.12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.cloud_off_rounded,
            size: 14,
            color: AppColors.amberGold,
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              "You're offline — messages won't send until you reconnect",
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.inter(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: AppColors.amberGold,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  final String photoUrl;
  final String name;
  final double size;
  final double fontSize;

  const _Avatar({
    required this.photoUrl,
    required this.name,
    this.size = 32,
    this.fontSize = 13,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
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
                  fontSize: fontSize,
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

// ─── Message list ────────────────────────────────────────

// Computes burst grouping + injects the idle warning + low-balance
// card as pseudo-rows inside the same scrollable list (so they
// scroll with the messages instead of pinning over the input).
//
// Layout when both cards are present:
//   [...messages] [idle warning] [low-balance card]
// Low-balance sits closest to the input because it's the more
// urgent of the two (it can stop the session entirely).
class _MessageList extends StatelessWidget {
  final ScrollController controller;
  final List<ChatMessage> messages;
  final String currentUid;
  final bool isUserSide;
  final bool showLowBalanceCard;
  final bool showIdleWarning;
  final int remainingBalance;
  final VoidCallback onAddCoins;
  final void Function(String messageId, String emoji) onReact;

  const _MessageList({
    required this.controller,
    required this.messages,
    required this.currentUid,
    required this.isUserSide,
    required this.showLowBalanceCard,
    required this.showIdleWarning,
    required this.remainingBalance,
    required this.onAddCoins,
    required this.onReact,
  });

  @override
  Widget build(BuildContext context) {
    // Index math: messages occupy [0, messages.length).
    // Then the idle row (if any), then the low-balance card (if any).
    final messageCount = messages.length;
    final idleIndex = showIdleWarning ? messageCount : -1;
    final lowBalanceIndex = showLowBalanceCard
        ? messageCount + (showIdleWarning ? 1 : 0)
        : -1;
    final itemCount = messageCount +
        (showIdleWarning ? 1 : 0) +
        (showLowBalanceCard ? 1 : 0);

    return ListView.builder(
      controller: controller,
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      itemCount: itemCount,
      itemBuilder: (_, index) {
        if (index == lowBalanceIndex) {
          return _LowBalanceMessage(
            balance: remainingBalance,
            onAddCoins: onAddCoins,
          );
        }
        if (index == idleIndex) {
          return _IdleWarningMessage(isUserSide: isUserSide);
        }

        final msg = messages[index];
        final isMe = msg.senderId == currentUid;
        final showTimestamp = _shouldShowTimestamp(index, messages);
        // Burst grouping: if previous message was from the same
        // sender within 30s, hide the small timestamp & tighten
        // the gap. The first bubble in a burst gets full spacing.
        final previousFromSameSender =
            _isBurstContinuation(index, messages);

        return _ChatBubble(
          key: ValueKey(msg.id),
          message: msg,
          isMe: isMe,
          showTimestamp: showTimestamp,
          isBurstContinuation: previousFromSameSender,
          onReact: onReact,
        );
      },
    );
  }

  bool _shouldShowTimestamp(int index, List<ChatMessage> messages) {
    if (index == 0) return true;
    final prev = messages[index - 1].createdAt;
    final curr = messages[index].createdAt;
    if (prev == null || curr == null) return false;
    return curr.difference(prev).inMinutes >= 5;
  }

  bool _isBurstContinuation(int index, List<ChatMessage> messages) {
    if (index == 0) return false;
    final prev = messages[index - 1];
    final curr = messages[index];
    if (prev.senderId != curr.senderId) return false;
    final pa = prev.createdAt;
    final ca = curr.createdAt;
    if (pa == null || ca == null) return false;
    return ca.difference(pa).inSeconds <= 30;
  }
}

// ─── Chat bubble ─────────────────────────────────────────

class _ChatBubble extends StatelessWidget {
  final ChatMessage message;
  final bool isMe;
  final bool showTimestamp;
  final bool isBurstContinuation;
  final void Function(String messageId, String emoji) onReact;

  const _ChatBubble({
    super.key,
    required this.message,
    required this.isMe,
    required this.showTimestamp,
    required this.isBurstContinuation,
    required this.onReact,
  });

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      // 0 → 1 over 180ms. Starts the very first time a bubble is
      // mounted; ListView.builder's keyed children mean each id
      // animates exactly once.
      tween: Tween(begin: 0.0, end: 1.0),
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      builder: (_, t, child) {
        return Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset(0, (1 - t) * 8),
            child: child,
          ),
        );
      },
      child: _BubbleBody(
        message: message,
        isMe: isMe,
        showTimestamp: showTimestamp,
        isBurstContinuation: isBurstContinuation,
        onReact: onReact,
      ),
    );
  }
}

class _BubbleBody extends StatelessWidget {
  final ChatMessage message;
  final bool isMe;
  final bool showTimestamp;
  final bool isBurstContinuation;
  final void Function(String messageId, String emoji) onReact;

  const _BubbleBody({
    required this.message,
    required this.isMe,
    required this.showTimestamp,
    required this.isBurstContinuation,
    required this.onReact,
  });

  @override
  Widget build(BuildContext context) {
    final topGap = isBurstContinuation ? 2.0 : 6.0;

    return Padding(
      padding: EdgeInsets.only(
        top: topGap,
        bottom: 0,
        left: isMe ? 48 : 0,
        right: isMe ? 0 : 48,
      ),
      child: Column(
        crossAxisAlignment:
            isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          if (showTimestamp)
            Padding(
              padding: const EdgeInsets.only(bottom: 8, top: 6),
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
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onLongPress: message.isPending
                ? null
                : () => _openReactionPicker(context),
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 14,
                vertical: 10,
              ),
              decoration: BoxDecoration(
                color: isMe
                    ? AppColors.primaryBrown.withValues(
                        alpha: message.isPending ? 0.7 : 1.0)
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
          ),
          if (message.reactions.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: _ReactionChip(reactions: message.reactions),
            ),
          const SizedBox(height: 2),
          _BubbleFooter(message: message, isMe: isMe),
        ],
      ),
    );
  }

  void _openReactionPicker(BuildContext context) {
    HapticFeedback.selectionClick();
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.25),
      builder: (sheetContext) => _ReactionPickerSheet(
        onPick: (emoji) {
          Navigator.of(sheetContext).pop();
          onReact(message.id, emoji);
        },
      ),
    );
  }
}

class _BubbleFooter extends StatelessWidget {
  final ChatMessage message;
  final bool isMe;

  const _BubbleFooter({required this.message, required this.isMe});

  @override
  Widget build(BuildContext context) {
    final time = _formatTime(message.createdAt);
    return Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment:
          isMe ? MainAxisAlignment.end : MainAxisAlignment.start,
      children: [
        Text(
          time,
          style: GoogleFonts.inter(
            fontSize: 10,
            fontWeight: FontWeight.w400,
            color: AppColors.muted.withValues(alpha: 0.5),
          ),
        ),
        if (isMe) ...[
          const SizedBox(width: 4),
          // Pending = single hollow circle / sent = single check.
          // We don't track delivered/read receipts yet, so a single
          // tick means "in Firestore", which is enough to reassure
          // the user the message landed.
          Icon(
            message.isPending ? Icons.schedule : Icons.check,
            size: 11,
            color: AppColors.muted.withValues(alpha: 0.55),
          ),
        ],
      ],
    );
  }
}

// ─── Reaction chip (under bubble) + picker sheet ─────────

class _ReactionChip extends StatelessWidget {
  final Map<String, String> reactions;
  const _ReactionChip({required this.reactions});

  @override
  Widget build(BuildContext context) {
    // Group emojis: { "🙏": 2, "❤️": 1 } so the chip shows
    // counts when both participants reacted with the same emoji.
    final counts = <String, int>{};
    for (final v in reactions.values) {
      counts[v] = (counts[v] ?? 0) + 1;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.surfaceWhite,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: AppColors.muted.withValues(alpha: 0.15),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: counts.entries.map((e) {
          final hasMultiple = e.value > 1;
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  e.key,
                  style: const TextStyle(fontSize: 13),
                ),
                if (hasMultiple) ...[
                  const SizedBox(width: 2),
                  Text(
                    '${e.value}',
                    style: GoogleFonts.inter(
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      color: AppColors.muted,
                    ),
                  ),
                ],
              ],
            ),
          );
        }).toList(),
      ),
    );
  }
}

class _ReactionPickerSheet extends StatelessWidget {
  final void Function(String emoji) onPick;
  const _ReactionPickerSheet({required this.onPick});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: 8,
            vertical: 8,
          ),
          decoration: BoxDecoration(
            color: AppColors.surfaceWhite,
            borderRadius: BorderRadius.circular(36),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.18),
                blurRadius: 22,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: _kReactionEmojis
                .map((e) => _ReactionButton(emoji: e, onTap: () => onPick(e)))
                .toList(),
          ),
        ),
      ),
    );
  }
}

class _ReactionButton extends StatefulWidget {
  final String emoji;
  final VoidCallback onTap;

  const _ReactionButton({required this.emoji, required this.onTap});

  @override
  State<_ReactionButton> createState() => _ReactionButtonState();
}

class _ReactionButtonState extends State<_ReactionButton> {
  double _scale = 1.0;

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (_) => setState(() => _scale = 1.2),
      onPointerUp: (_) => setState(() => _scale = 1.0),
      onPointerCancel: (_) => setState(() => _scale = 1.0),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          HapticFeedback.lightImpact();
          widget.onTap();
        },
        child: AnimatedScale(
          scale: _scale,
          duration: const Duration(milliseconds: 140),
          curve: Curves.easeOut,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Text(
              widget.emoji,
              style: const TextStyle(fontSize: 32),
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Idle-warning system message (inside chat list) ─────
//
// Local-only — never persisted to Firestore. The cubit toggles
// state.showIdleWarning via a 30s timer once the OTHER party has
// been silent for 90+ seconds; this row reflects that flag.

class _IdleWarningMessage extends StatelessWidget {
  final bool isUserSide;
  const _IdleWarningMessage({required this.isUserSide});

  @override
  Widget build(BuildContext context) {
    final copy = isUserSide
        ? "The speaker hasn't responded in a while. You can end "
            'the session anytime using the End button above.'
        : "The user hasn't sent a message in a while. The session "
            'will continue until one of you ends it.';

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 32),
      child: Container(
        padding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: AppColors.amberGold.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: AppColors.amberGold.withValues(alpha: 0.18),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.info_outline_rounded,
              size: 14,
              color: AppColors.amberGold,
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                copy,
                textAlign: TextAlign.center,
                style: GoogleFonts.inter(
                  fontSize: 12,
                  fontWeight: FontWeight.w400,
                  height: 1.4,
                  color: AppColors.amberGold.withValues(alpha: 0.85),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Low-balance system message (inside chat list) ───────

class _LowBalanceMessage extends StatelessWidget {
  final int balance;
  final VoidCallback onAddCoins;

  const _LowBalanceMessage({
    required this.balance,
    required this.onAddCoins,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 14, bottom: 6),
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        decoration: BoxDecoration(
          color: AppColors.amberGold.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: AppColors.amberGold.withValues(alpha: 0.35),
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.amberGold.withValues(alpha: 0.25),
              ),
              child: Icon(
                Icons.bolt_rounded,
                size: 20,
                color: AppColors.amberGold,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '$balance coins left',
                    style: GoogleFonts.inter(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: AppColors.deepDarkBrown,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Top up to keep your conversation going',
                    style: GoogleFonts.inter(
                      fontSize: 12,
                      fontWeight: FontWeight.w400,
                      color: AppColors.muted,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            _AddCoinsButton(onTap: onAddCoins),
          ],
        ),
      ),
    );
  }
}

class _AddCoinsButton extends StatefulWidget {
  final VoidCallback onTap;
  const _AddCoinsButton({required this.onTap});

  @override
  State<_AddCoinsButton> createState() => _AddCoinsButtonState();
}

class _AddCoinsButtonState extends State<_AddCoinsButton> {
  double _scale = 1.0;

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (_) => setState(() => _scale = 0.95),
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
            padding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            decoration: BoxDecoration(
              color: AppColors.primaryBrown,
              borderRadius: BorderRadius.circular(10),
              boxShadow: [
                BoxShadow(
                  color: AppColors.primaryBrown.withValues(alpha: 0.2),
                  blurRadius: 8,
                  offset: const Offset(0, 3),
                ),
              ],
            ),
            child: Text(
              'Add Coins',
              style: GoogleFonts.inter(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: Colors.white,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Typing footer ───────────────────────────────────────

class _TypingFooter extends StatefulWidget {
  final String otherName;
  final bool isTyping;
  final DateTime? typingSince;

  const _TypingFooter({
    required this.otherName,
    required this.isTyping,
    required this.typingSince,
  });

  @override
  State<_TypingFooter> createState() => _TypingFooterState();
}

class _TypingFooterState extends State<_TypingFooter> {
  // The "long composing" status switches over from "typing…" once
  // the other side has been typing for >10 seconds. We re-evaluate
  // the wall clock every 2s so the copy updates without a heavy
  // tween — a stale "typing" string for 1-2s past the 10s line is
  // imperceptible.
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 2), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Treat a missing or very-stale typingSince as "not typing"
    // even if isTyping is true — guards against ghost flags from
    // a cubit that died before clearing its state.
    final since = widget.typingSince;
    final stale = since != null &&
        DateTime.now().difference(since).inSeconds > 30;
    final showing = widget.isTyping && !stale;

    final composing = since != null &&
        DateTime.now().difference(since).inSeconds >= 10;

    return AnimatedSize(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      child: showing
          ? Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const _TypingDots(),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      composing
                          ? '${widget.otherName} is composing a longer response…'
                          : '${widget.otherName} is typing…',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.inter(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: AppColors.muted,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ),
                ],
              ),
            )
          : const SizedBox(width: double.infinity, height: 0),
    );
  }
}

class _TypingDots extends StatefulWidget {
  const _TypingDots();

  @override
  State<_TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<_TypingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctl;

  @override
  void initState() {
    super.initState();
    _ctl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat();
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctl,
      builder: (_, _) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(3, (i) {
            // Each dot's opacity peaks at a different phase of the
            // overall cycle, giving the "wave" feel without three
            // separate controllers.
            final phase = (_ctl.value - i * 0.18) % 1.0;
            final v = (1 - (phase * 2 - 1).abs()).clamp(0.3, 1.0);
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 1.5),
              child: Container(
                width: 5,
                height: 5,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.muted.withValues(alpha: v),
                ),
              ),
            );
          }),
        );
      },
    );
  }
}

// ─── Empty state ─────────────────────────────────────────

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

// ─── Input bar ───────────────────────────────────────────

class _MessageInputBar extends StatefulWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final bool isSending;
  final VoidCallback onSend;
  final ValueChanged<String> onChanged;

  const _MessageInputBar({
    required this.controller,
    required this.focusNode,
    required this.isSending,
    required this.onSend,
    required this.onChanged,
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
                onChanged: widget.onChanged,
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
          // ValueListenableBuilder rebuilds only this small subtree
          // when the text changes, so the rest of the input bar
          // (and the chat above) doesn't churn on every keystroke.
          // The button visually + functionally disables when the
          // trimmed text is empty.
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: widget.controller,
            builder: (_, value, _) {
              final hasText = value.text.trim().isNotEmpty;
              final disabled = widget.isSending || !hasText;
              return Listener(
                onPointerDown: (_) {
                  if (!disabled) setState(() => _sendScale = 0.9);
                },
                onPointerUp: (_) => setState(() => _sendScale = 1.0),
                onPointerCancel: (_) =>
                    setState(() => _sendScale = 1.0),
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: disabled ? null : widget.onSend,
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
                          alpha: disabled ? 0.35 : 1.0,
                        ),
                        boxShadow: disabled
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
              );
            },
          ),
        ],
      ),
    );
  }
}

// ─── End-session sheet ───────────────────────────────────

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

// ─── Loader ──────────────────────────────────────────────

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

// ─── Helpers ─────────────────────────────────────────────

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
