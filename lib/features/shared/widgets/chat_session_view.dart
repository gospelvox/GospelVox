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

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:gospel_vox/core/services/connectivity_service.dart';
import 'package:gospel_vox/core/theme/app_colors.dart';
import 'package:gospel_vox/core/utils/date_format.dart' as df;
import 'package:gospel_vox/core/widgets/app_snackbar.dart';
import 'package:gospel_vox/features/shared/bloc/chat_session_cubit.dart';
import 'package:gospel_vox/features/shared/bloc/chat_session_state.dart';
import 'package:gospel_vox/features/shared/data/session_model.dart';
import 'package:gospel_vox/features/shared/widgets/recharge_sheet.dart';
import 'package:gospel_vox/features/shared/widgets/session_participant_menu.dart';
import 'package:gospel_vox/core/widgets/app_icons.dart';
import 'package:gospel_vox/core/widgets/app_loading_widget.dart';

// Forest green used only for the "In session" status pill here.
const Color _kSessionGreen = AppColors.successGreen;

// Reactions menu — kept short and on-brand for spiritual chat.
const List<String> _kReactionEmojis = ['🙏', '❤️', '🕊️'];

typedef ChatEndedCallback =
    void Function(BuildContext context, ChatSessionEnded state);

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

class _ChatSessionViewState extends State<ChatSessionView>
    with WidgetsBindingObserver {
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
  // Independent latch for the "final minute" haptic — fires once
  // when remaining chat time crosses below 1 minute, re-arms only
  // when balance climbs back above 1 minute (recharge). Heavier
  // than the 5-min entry buzz to signal the final warning.
  bool _wasInFinalMinute = false;

  // Defence-in-depth: prevents two recharge sheets stacking even
  // if the BlocListener somehow fires twice. Cleared the moment
  // the sheet dismisses.
  bool _lowBalanceSheetOpen = false;

  // Live connectivity state. Drives the offline pill in the top
  // bar so the user knows their messages aren't going through
  // before the watchdog quietly ends the session in the background.
  // Reuses the global ConnectivityService singleton — opening a
  // second Connectivity().onConnectivityChanged subscription would
  // duplicate the platform-channel listener (per the singleton's
  // own docstring).
  StreamSubscription<bool>? _connSub;
  bool _isOffline = false;

  // Tracks the other side's typing state so we can follow to the
  // latest message the moment they start typing (WhatsApp-style).
  bool _lastOtherTyping = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _setupConnectivity();
    // Focusing the input opens the keyboard — follow to the latest
    // message so it's never hidden behind the keyboard.
    _focusNode.addListener(_onInputFocusChange);
  }

  @override
  void didChangeMetrics() {
    // The keyboard opening/closing changes the bottom inset. While the
    // input is focused, keep the latest message pinned above the
    // keyboard as it animates in (WhatsApp behaviour). Guarded to focus
    // so an unrelated metrics change never yanks the list.
    if (!_focusNode.hasFocus) return;
    _scrollToLatest(animate: false);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState appState) {
    // Killing / closing the app must end the chat instantly (no
    // foreground service keeps chat alive, unlike voice). On a real
    // termination, end now so the meter stops and the peer is freed
    // immediately rather than waiting on the presence-stale timer.
    // Best-effort: if the process dies first, the peer's own
    // presence-stale check ends it as the backstop. endSession is
    // guarded + the server settle is transactional, so no double-end.
    if (appState != AppLifecycleState.detached) return;
    if (!mounted) return;
    final ChatSessionCubit cubit;
    try {
      cubit = context.read<ChatSessionCubit>();
    } catch (_) {
      return;
    }
    if (cubit.isClosed) return;
    cubit.endSession(reason: 'app_terminated');
  }

  void _setupConnectivity() {
    final svc = ConnectivityService();
    _isOffline = !svc.isOnline;
    _connSub = svc.onChanged.listen((isOnline) {
      if (!mounted) return;
      final offline = !isOnline;
      if (offline != _isOffline) {
        setState(() => _isOffline = offline);
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _connSub?.cancel();
    _focusNode.removeListener(_onInputFocusChange);
    _messageController.dispose();
    _scrollController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  // Always keep the conversation pinned to the newest message. animate
  // for live arrivals / typing / focus; jump for first-open and
  // keyboard tracking so it never flashes through old content.
  void _scrollToLatest({bool animate = true}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      final target = _scrollController.position.maxScrollExtent;
      if (animate) {
        _scrollController.animateTo(
          target,
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOutCubic,
        );
      } else {
        _scrollController.jumpTo(target);
      }
    });
  }

  // Focusing the input (keyboard about to open) → follow to the latest
  // message so it isn't hidden behind the keyboard.
  void _onInputFocusChange() {
    if (_focusNode.hasFocus) _scrollToLatest();
  }

  // The other side starting to type → reveal the typing footer by
  // following to the bottom, the way WhatsApp does.
  void _maybeScrollOnTyping(bool otherTyping) {
    if (otherTyping == _lastOtherTyping) return;
    _lastOtherTyping = otherTyping;
    if (otherTyping) _scrollToLatest();
  }

  // Hide the empty-chat illustration when there's anything else to
  // show in its place — the idle warning OR the low-balance card.
  // Billing starts the moment the priest accepts, so a user with
  // zero messages but low balance still needs to see the recharge
  // nudge; otherwise the session just cuts off mid-thought.
  bool _shouldShowEmpty(ChatSessionActive state) {
    if (state.messages.isNotEmpty) return false;
    if (state.showIdleWarning) return false;
    if (widget.isUserSide && state.isLowBalance) return false;
    return true;
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
          listenWhen: (prev, next) {
            // Terminal / error states navigate away — unchanged behaviour.
            if (next is ChatSessionEnded || next is ChatSessionError) {
              return true;
            }
            // Edge-triggered low-balance prompt: only fire on the
            // false → true transition so re-emits with the flag
            // already true don't stack sheets.
            final prevPrompt =
                (prev is ChatSessionActive) && prev.showLowBalancePrompt;
            final nextPrompt =
                (next is ChatSessionActive) && next.showLowBalancePrompt;
            return !prevPrompt && nextPrompt;
          },
          listener: (context, state) {
            if (state is ChatSessionEnded) {
              widget.onEnded(context, state);
            } else if (state is ChatSessionError) {
              AppSnackBar.error(context, state.message);
            } else if (state is ChatSessionActive &&
                state.showLowBalancePrompt &&
                widget.isUserSide) {
              _showLowBalanceSheet(state);
            }
          },
          builder: (context, state) {
            if (state is ChatSessionActive) {
              _maybeAutoScroll(state.messages);
              _maybeBuzzOnLowBalance(state.isLowBalance);
              _maybeBuzzOnFinalMinute(
                state.remainingBalance,
                state.session.ratePerMinute,
              );
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
    final otherTyping = widget.isUserSide
        ? session.priestTyping
        : session.userTyping;
    final otherTypingSince = widget.isUserSide
        ? session.priestTypingSince
        : session.userTypingSince;
    // Follow to the latest message when the other side starts typing so
    // the "is typing…" footer is always visible.
    _maybeScrollOnTyping(otherTyping);

    return SafeArea(
      bottom: false,
      top: false,
      child: Column(
        children: [
          _ChatTopBar(
            photoUrl: otherPhoto,
            name: otherName,
            elapsed: state.formattedTime,
            ratePerMinute: state.session.ratePerMinute,
            isUserSide: widget.isUserSide,
            isEnding: state.isEnding,
            isOffline: _isOffline,
            onEndTap: _showEndConfirmation,
            // Report / Block lives on the user side only — the user is
            // always the reporter on this surface (direction: user →
            // Speaker). Null hides the ⋮ button for the priest.
            onMenuTap: widget.isUserSide
                ? () => showSessionParticipantMenu(
                    context,
                    priestId: session.priestId,
                    priestName: otherName,
                    reporterUserId: widget.currentUid,
                    reporterName: session.userName.isNotEmpty
                        ? session.userName
                        : 'User',
                    sessionId: widget.sessionId,
                  )
                : null,
          ),
          Expanded(
            child: Stack(
              children: [
                _shouldShowEmpty(state)
                    ? const _EmptyChat()
                    : _MessageList(
                        controller: _scrollController,
                        messages: state.messages,
                        currentUid: widget.currentUid,
                        currentSessionId: widget.sessionId,
                        pastMeta: state.pastMeta,
                        isUserSide: widget.isUserSide,
                        showLowBalanceCard:
                            widget.isUserSide && state.isLowBalance,
                        showIdleWarning: state.showIdleWarning,
                        remainingBalance: state.remainingBalance,
                        ratePerMinute: state.session.ratePerMinute,
                        onAddCoins: _openRecharge,
                        onReact: (msgId, emoji) =>
                            context.read<ChatSessionCubit>().toggleReaction(
                              messageId: msgId,
                              userId: widget.currentUid,
                              emoji: emoji,
                            ),
                        // Swipe-to-reply: gated to current-session,
                        // non-pending, session-type bubbles only.
                        // The cubit re-asserts the same rules as
                        // defence in depth.
                        onSwipeReply: (message) {
                          HapticFeedback.lightImpact();
                          context.read<ChatSessionCubit>().setReplyTarget(
                            message,
                          );
                        },
                      ),
              ],
            ),
          ),
          _TypingFooter(
            otherName: otherName,
            isTyping: otherTyping,
            typingSince: otherTypingSince,
          ),
          // Compose chip slides in via AnimatedSize when the user
          // has an active reply target. Sits flush between the
          // typing footer and the input bar so it reads as part of
          // the input surface rather than the message list.
          AnimatedSize(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            child: state.replyTarget != null
                ? _ReplyComposeChip(
                    target: state.replyTarget!,
                    currentUid: widget.currentUid,
                    onDismiss: () =>
                        context.read<ChatSessionCubit>().clearReplyTarget(),
                  )
                : const SizedBox(width: double.infinity, height: 0),
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

    // Always follow to the newest message. First open (null → real id)
    // jumps so we don't flash through old history; later arrivals
    // animate. The user can still freely scroll up to read older
    // content — the next message brings them back to the latest.
    final isFirstOpen = !hadPrevious;
    _lastMessageId = latestId;
    _scrollToLatest(animate: !isFirstOpen);
  }

  void _maybeBuzzOnLowBalance(bool isLow) {
    if (isLow && !_wasLowBalance) {
      HapticFeedback.mediumImpact();
    }
    _wasLowBalance = isLow;
  }

  // Single sharp haptic the moment the user enters the final
  // minute of chat time. Gated to the user side (priest doesn't
  // see low-balance UI) and edge-detected via _wasInFinalMinute
  // so it fires once per low-balance phase, not on every rebuild.
  // Heavy impact distinguishes this from the medium 5-min entry.
  void _maybeBuzzOnFinalMinute(int balance, int rate) {
    if (!widget.isUserSide) return;
    if (rate <= 0) return;
    final inFinal = (balance ~/ rate) <= 1;
    if (inFinal && !_wasInFinalMinute) {
      HapticFeedback.heavyImpact();
    }
    _wasInFinalMinute = inFinal;
  }

  // Auto-popup recharge sheet, fired by the cubit's low-balance
  // latch the moment the user crosses below 2 minutes of remaining
  // chat time. Renders the same RechargeSheet the manual
  // _openRecharge call uses, but with urgent countdown copy. The
  // cubit owns the "show once per phase" semantics; this method
  // just renders + acknowledges the prompt after dismissal.
  Future<void> _showLowBalanceSheet(ChatSessionActive state) async {
    if (_lowBalanceSheetOpen) return;
    _lowBalanceSheetOpen = true;

    final rate = state.session.ratePerMinute;
    final balance = state.remainingBalance;

    final secondsLeft = rate > 0
        ? ((balance * 60) ~/ rate).clamp(0, 60 * 60)
        : 0;
    final mm = secondsLeft ~/ 60;
    final ss = secondsLeft % 60;
    final countdown = '$mm:${ss.toString().padLeft(2, '0')}';

    HapticFeedback.mediumImpact();
    try {
      // Headline only — the sheet's pack grid + "Low wallet
      // balance!" title already convey the action. The subtext
      // ("Recharge to keep chatting with X") was decorative
      // repetition and added cognitive load.
      await RechargeSheet.show(
        context,
        currentBalance: balance,
        infoHeadline: 'Your chat ends in $countdown',
        // Keep the user in the live chat — no jump to the full wallet.
        showSeeAllPlans: false,
      );
    } finally {
      _lowBalanceSheetOpen = false;
      if (mounted) {
        final cubit = context.read<ChatSessionCubit>();
        if (!cubit.isClosed) cubit.acknowledgeLowBalancePrompt();
      }
    }
  }

  Future<void> _openRecharge() async {
    HapticFeedback.lightImpact();
    // Single-line headline — the verbose "Minimum balance" line
    // and the "with $priestName" subtext were over-text. The user
    // already knows who they're chatting with; the sheet's pack
    // grid + balance pill carry the rest.
    final cubitState = context.read<ChatSessionCubit>().state;
    int? balance;
    String? headline;
    if (cubitState is ChatSessionActive) {
      balance = cubitState.remainingBalance;
      final ctx = recomputeRechargeContext(
        ratePerMinute: cubitState.session.ratePerMinute,
        currentBalance: cubitState.remainingBalance,
      );
      if (ctx.deficit > 0) {
        headline = 'Add ₹${ctx.deficit} more to keep your chat going';
      }
    }
    await RechargeSheet.show(
      context,
      currentBalance: balance,
      infoHeadline: headline,
      // Keep the user in the live chat — no jump to the full wallet.
      showSeeAllPlans: false,
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
  final int ratePerMinute;
  // The rate line is user-only: the priest earns rather than pays, so
  // a per-minute "cost" would be wrong to show them.
  final bool isUserSide;
  final bool isEnding;
  // True when the device has no network connectivity. Surfaces a
  // small amber pill in the bar so the user understands why their
  // messages aren't going through.
  final bool isOffline;
  final VoidCallback onEndTap;
  // Opens the Report / Block menu. Null on the priest side, which
  // hides the ⋮ button entirely.
  final VoidCallback? onMenuTap;

  const _ChatTopBar({
    required this.photoUrl,
    required this.name,
    required this.elapsed,
    required this.ratePerMinute,
    required this.isUserSide,
    required this.isEnding,
    required this.isOffline,
    required this.onEndTap,
    this.onMenuTap,
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
                _Avatar(photoUrl: photoUrl, name: name, size: 40, fontSize: 16),
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
                          // Status + rate live in ONE rich text wrapped
                          // in Flexible, so they share a single width
                          // budget and ellipsis gracefully instead of
                          // overflowing the bar. User side appends the
                          // rate; the priest sees just "In session".
                          Flexible(
                            child: Text.rich(
                              TextSpan(
                                children: [
                                  TextSpan(
                                    text: 'In session',
                                    style: GoogleFonts.inter(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w400,
                                      color: _kSessionGreen,
                                    ),
                                  ),
                                  if (isUserSide)
                                    TextSpan(
                                      text: ' · $ratePerMinute coins/min',
                                      style: GoogleFonts.inter(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w400,
                                        color: AppColors.muted,
                                      ),
                                    ),
                                ],
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                _TimerPill(elapsed: elapsed),
                if (onMenuTap != null) ...[
                  const SizedBox(width: 2),
                  IconButton(
                    onPressed: onMenuTap,
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 36,
                      minHeight: 36,
                    ),
                    tooltip: 'Report or block',
                    icon: AppIcon(
                      AppIcons.more,
                      size: 20,
                      color: AppColors.muted,
                    ),
                  ),
                ],
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
          AppIcon(AppIcons.cloudOff, size: 14, color: AppColors.amberGold),
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
        color: AppColors.fieldFill,
        image: photoUrl.isNotEmpty
            ? DecorationImage(image: NetworkImage(photoUrl), fit: BoxFit.cover)
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
    // Quiet, minimal timer — no filled pill, muted colour and small
    // text. It's secondary context, so it steps back visually and
    // frees horizontal room for the status + rate line.
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        AppIcon(AppIcons.clock, size: 12, color: AppColors.muted),
        const SizedBox(width: 4),
        Text(
          elapsed,
          style: GoogleFonts.inter(
            fontSize: 12,
            fontWeight: FontWeight.w500,
            color: AppColors.muted,
          ),
        ),
      ],
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
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
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
//
// Past-session continuity:
//   • A divider row "── Session · May 1 · 15 min ──" is injected
//     before the FIRST bubble of each past sessionId. No divider
//     for the current session — the conversation flows naturally
//     from the most recent past divider into the live bubbles
//     with no separator.
//   • Past bubbles render exactly the same as live ones (no
//     dimming, no smaller text — confirmed). The only behavioral
//     difference is long-press reactions are disabled on past
//     bubbles, since reactions are a current-session interaction.
class _MessageList extends StatelessWidget {
  final ScrollController controller;
  final List<ChatMessage> messages;
  final String currentUid;
  final String currentSessionId;
  final Map<String, PastSessionMeta> pastMeta;
  final bool isUserSide;
  final bool showLowBalanceCard;
  final bool showIdleWarning;
  final int remainingBalance;
  // Locked rate from the session, threaded through so the low-
  // balance card can render "X minutes left" instead of raw coins.
  final int ratePerMinute;
  final VoidCallback onAddCoins;
  final void Function(String messageId, String emoji) onReact;
  // Fired when a current-session, non-pending bubble has been
  // swiped past the reply threshold. Builder gates the gesture so
  // only eligible bubbles get the wrapper at all.
  final void Function(ChatMessage message) onSwipeReply;

  const _MessageList({
    required this.controller,
    required this.messages,
    required this.currentUid,
    required this.currentSessionId,
    required this.pastMeta,
    required this.isUserSide,
    required this.showLowBalanceCard,
    required this.showIdleWarning,
    required this.remainingBalance,
    required this.ratePerMinute,
    required this.onAddCoins,
    required this.onReact,
    required this.onSwipeReply,
  });

  @override
  Widget build(BuildContext context) {
    // Pre-build the row sequence once. Divider rows are inserted at
    // the start of each past-session group; the rest is messages
    // + (optional) idle warning + (optional) low-balance card.
    final rows = <_Row>[];
    String? prevSessionId;
    for (var i = 0; i < messages.length; i++) {
      final msg = messages[i];
      final sid = msg.sessionId;
      final isPast = sid.isNotEmpty && sid != currentSessionId;
      // Insert a divider whenever we step into a *past* session
      // group — never for the current session (live messages flow
      // straight off the last past divider with no break).
      if (isPast && sid != prevSessionId) {
        final meta = pastMeta[sid];
        if (meta != null) {
          rows.add(
            _DividerRow(date: meta.date, durationMinutes: meta.durationMinutes),
          );
        }
      }
      rows.add(
        _BubbleRow(
          message: msg,
          isMe: msg.senderId == currentUid,
          // A free priest message is read-only too (long-press blocked,
          // reactions disabled). isPast already covers the past-session
          // case; OR with the free-message kind so a single flag drives
          // the inert-bubble rules in the renderer.
          isPast: isPast || msg.isPriestMessage,
          // Burst grouping is per-bubble within a session — never
          // collapse a bubble's avatar gap into a different session's
          // bubble even if the timestamps happen to be within 30s.
          // Free messages also break bursts: a session bubble + a
          // free message that happen to fall <30s apart shouldn't
          // share a burst because they belong to different contexts.
          isBurstContinuation:
              i > 0 &&
              messages[i - 1].sessionId == sid &&
              messages[i - 1].kind == msg.kind &&
              _isBurstContinuationByMessages(messages[i - 1], msg),
          showTimestamp:
              i == 0 ||
              messages[i - 1].sessionId != sid ||
              messages[i - 1].kind != msg.kind ||
              _shouldShowTimestamp(messages[i - 1], msg),
        ),
      );
      prevSessionId = sid;
    }
    if (showIdleWarning) {
      rows.add(const _IdleRow());
    }
    if (showLowBalanceCard) {
      rows.add(const _LowBalanceRow());
    }

    return ListView.builder(
      controller: controller,
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      itemCount: rows.length,
      itemBuilder: (_, index) {
        final row = rows[index];
        if (row is _DividerRow) {
          return _PastSessionDivider(
            date: row.date,
            durationMinutes: row.durationMinutes,
          );
        }
        if (row is _IdleRow) {
          return _IdleWarningMessage(isUserSide: isUserSide);
        }
        if (row is _LowBalanceRow) {
          return _LowBalanceMessage(
            balance: remainingBalance,
            ratePerMinute: ratePerMinute,
            onAddCoins: onAddCoins,
          );
        }
        final bubble = row as _BubbleRow;
        // Call-entry rows are inert in the live chat surface —
        // tapping a past call here would mean starting a new call
        // while we're mid-chat, which isn't a flow we support.
        // The row still shows so the user gets full context.
        if (bubble.message.isCallEntry) {
          return CallEntryBubble(
            key: ValueKey(bubble.message.id),
            message: bubble.message,
            isMe: bubble.isMe,
            onTap: null,
          );
        }
        final chatBubble = _ChatBubble(
          key: ValueKey(bubble.message.id),
          message: bubble.message,
          isMe: bubble.isMe,
          isPast: bubble.isPast,
          showTimestamp: bubble.showTimestamp,
          isBurstContinuation: bubble.isBurstContinuation,
          currentUid: currentUid,
          isUserSide: isUserSide,
          onReact: onReact,
        );
        // Eligible for swipe-to-reply: current session, not a
        // pending/optimistic bubble, not a free message, not past.
        // Anything else renders without the wrapper so we don't pay
        // gesture cost on read-only history.
        final canReply =
            !bubble.isPast &&
            !bubble.message.isPending &&
            !bubble.message.isPriestMessage;
        if (!canReply) return chatBubble;
        return _SwipeToReply(
          onTriggered: () => onSwipeReply(bubble.message),
          child: chatBubble,
        );
      },
    );
  }

  static bool _shouldShowTimestamp(ChatMessage prev, ChatMessage curr) {
    final pa = prev.createdAt;
    final ca = curr.createdAt;
    if (pa == null || ca == null) return false;
    return ca.difference(pa).inMinutes >= 5;
  }

  static bool _isBurstContinuationByMessages(
    ChatMessage prev,
    ChatMessage curr,
  ) {
    if (prev.senderId != curr.senderId) return false;
    final pa = prev.createdAt;
    final ca = curr.createdAt;
    if (pa == null || ca == null) return false;
    return ca.difference(pa).inSeconds <= 30;
  }
}

// Internal row types — keeps the itemBuilder branchless and lets us
// build the row sequence once per state emission instead of running
// the divider math on every itemBuilder invocation.
sealed class _Row {
  const _Row();
}

class _DividerRow extends _Row {
  final DateTime date;
  final int durationMinutes;
  const _DividerRow({required this.date, required this.durationMinutes});
}

class _IdleRow extends _Row {
  const _IdleRow();
}

class _LowBalanceRow extends _Row {
  const _LowBalanceRow();
}

class _BubbleRow extends _Row {
  final ChatMessage message;
  final bool isMe;
  final bool isPast;
  final bool showTimestamp;
  final bool isBurstContinuation;

  const _BubbleRow({
    required this.message,
    required this.isMe,
    required this.isPast,
    required this.showTimestamp,
    required this.isBurstContinuation,
  });
}

// Past-session divider rendered inline in the chat list. Same shape
// as the one in chat_history_page so users see a consistent
// "Session · date · duration" boundary on either surface. We label
// the divider with date + duration; the type is implicit (chat,
// because past_meta is populated only for completed chat sessions).
class _PastSessionDivider extends StatelessWidget {
  final DateTime date;
  final int durationMinutes;

  const _PastSessionDivider({
    required this.date,
    required this.durationMinutes,
  });

  @override
  Widget build(BuildContext context) {
    final label = durationMinutes > 0
        ? 'Session · ${_formatDividerDate(date)} · $durationMinutes min'
        : 'Session · ${_formatDividerDate(date)}';

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 18),
      child: Row(
        children: [
          Expanded(
            child: Container(
              height: 0.5,
              color: AppColors.muted.withValues(alpha: 0.18),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(
              label,
              style: GoogleFonts.inter(
                fontSize: 11,
                fontWeight: FontWeight.w500,
                letterSpacing: 0.3,
                color: AppColors.muted.withValues(alpha: 0.75),
              ),
            ),
          ),
          Expanded(
            child: Container(
              height: 0.5,
              color: AppColors.muted.withValues(alpha: 0.18),
            ),
          ),
        ],
      ),
    );
  }
}

// Past-session divider label. Delegates to the shared date util so
// every chat surface formats dates the same way. See
// lib/core/utils/date_format.dart for the rules.
String _formatDividerDate(DateTime date) => df.formatDayCompact(date);

// ─── Chat bubble ─────────────────────────────────────────

class _ChatBubble extends StatelessWidget {
  final ChatMessage message;
  final bool isMe;
  // True when the bubble belongs to a previously-completed session
  // surfaced via the past-messages prefetch. Past bubbles render
  // identically to live ones; the only behavioral difference is
  // long-press reactions are disabled (reactions are a current-
  // session interaction).
  final bool isPast;
  final bool showTimestamp;
  final bool isBurstContinuation;
  // Threaded through so the in-bubble reply preview can label the
  // quoted sender as "You" vs their actual name.
  final String currentUid;
  // True when this bubble is being rendered for the USER (listener
  // side). Drives the "Free message" tag visibility — only shown on
  // the priest side, since on the user side a free message is just
  // a regular incoming message in the conversation flow.
  final bool isUserSide;
  final void Function(String messageId, String emoji) onReact;

  const _ChatBubble({
    super.key,
    required this.message,
    required this.isMe,
    required this.isPast,
    required this.showTimestamp,
    required this.isBurstContinuation,
    required this.currentUid,
    required this.isUserSide,
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
        isPast: isPast,
        showTimestamp: showTimestamp,
        isBurstContinuation: isBurstContinuation,
        currentUid: currentUid,
        isUserSide: isUserSide,
        onReact: onReact,
      ),
    );
  }
}

class _BubbleBody extends StatelessWidget {
  final ChatMessage message;
  final bool isMe;
  final bool isPast;
  final bool showTimestamp;
  final bool isBurstContinuation;
  final String currentUid;
  // See _ChatBubble.isUserSide — gates the "Free message" tag so
  // it only renders on the priest's side of the conversation.
  final bool isUserSide;
  final void Function(String messageId, String emoji) onReact;

  const _BubbleBody({
    required this.message,
    required this.isMe,
    required this.isPast,
    required this.showTimestamp,
    required this.isBurstContinuation,
    required this.currentUid,
    required this.isUserSide,
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
        crossAxisAlignment: isMe
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
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
          // "Free message" tag above the FIRST bubble of a free-
          // message burst. Shown ONLY on the priest's side — for
          // the priest it's a useful "billing context" signal (this
          // bubble didn't earn coins). For the user it's noise: a
          // free message is just an incoming message in the chat
          // flow, no special treatment needed.
          if (message.isPriestMessage && !isBurstContinuation && !isUserSide)
            Padding(
              padding: EdgeInsets.only(
                bottom: 4,
                left: isMe ? 0 : 4,
                right: isMe ? 4 : 0,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AppIcon(
                    AppIcons.magic,
                    size: 10,
                    color: AppColors.amberGold.withValues(alpha: 0.85),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    'Free message',
                    style: GoogleFonts.inter(
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.2,
                      color: AppColors.amberGold.withValues(alpha: 0.85),
                    ),
                  ),
                ],
              ),
            ),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            // No reactions on past bubbles — they belong to a closed
            // session, so opening the reaction picker would let the
            // user write to a message they no longer participate in.
            onLongPress: (message.isPending || isPast)
                ? null
                : () => _openReactionPicker(context),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: isMe
                    ? AppColors.primaryBrown.withValues(
                        alpha: message.isPending ? 0.7 : 1.0,
                      )
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
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (message.replyTo != null)
                    _ReplyPreviewInBubble(
                      reply: message.replyTo!,
                      currentUid: currentUid,
                      isMineBubble: isMe,
                    ),
                  Text(
                    message.text,
                    style: GoogleFonts.inter(
                      fontSize: 14,
                      fontWeight: FontWeight.w400,
                      height: 1.45,
                      color: isMe ? Colors.white : AppColors.deepDarkBrown,
                    ),
                  ),
                ],
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
      mainAxisAlignment: isMe ? MainAxisAlignment.end : MainAxisAlignment.start,
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
          AppIcon(
            message.isPending ? AppIcons.clock : AppIcons.check,
            size: 11,
            color: AppColors.muted.withValues(alpha: 0.55),
          ),
        ],
      ],
    );
  }
}

// ─── Call-entry bubble (past voice session, inline) ─────

// WhatsApp-style inline row for a past voice call between the user
// and this priest. Shows direction-arrow + duration + time, and
// (when onTap is non-null) a tap-to-redial phone icon on the
// trailing edge. The host page decides whether redial is wired:
//   • chat_history_page (user-side read-only)  → onTap = redial
//   • chat_session_view (live paid chat)       → onTap = null
//   • priest_chat_page  (priest-side history)  → onTap = null
//
// Sizing is intentionally smaller than a text bubble so a long
// thread doesn't get drowned in past-call rows.
class CallEntryBubble extends StatelessWidget {
  final ChatMessage message;
  final bool isMe;
  // Null = inert row (live chat / priest side). Non-null = redial.
  final VoidCallback? onTap;

  const CallEntryBubble({
    super.key,
    required this.message,
    required this.isMe,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final duration = message.callDurationMinutes ?? 0;
    final durationLabel = duration <= 0
        ? 'Voice call'
        : duration == 1
        ? 'Voice call · 1 min'
        : 'Voice call · $duration min';
    // Day-prefixed time so a call from last week doesn't read as
    // "3:00 PM" with no date context. The shared util handles
    // Today / Yesterday / Apr 5 / Apr 5, 2024 + the clock part.
    final timeText = df.formatDayTime(message.createdAt);
    final tappable = onTap != null;

    return Padding(
      padding: EdgeInsets.only(
        top: 6,
        bottom: 0,
        left: isMe ? 48 : 0,
        right: isMe ? 0 : 48,
      ),
      child: Align(
        alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: tappable
              ? () {
                  HapticFeedback.selectionClick();
                  onTap!();
                }
              : null,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: AppColors.surfaceWhite,
              borderRadius: BorderRadius.only(
                topLeft: const Radius.circular(16),
                topRight: const Radius.circular(16),
                bottomLeft: Radius.circular(isMe ? 16 : 4),
                bottomRight: Radius.circular(isMe ? 4 : 16),
              ),
              border: Border.all(
                color: AppColors.primaryBrown.withValues(alpha: 0.12),
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.03),
                  blurRadius: 5,
                  offset: const Offset(0, 1),
                ),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: AppColors.primaryBrown.withValues(alpha: 0.1),
                  ),
                  child: AppIcon(
                    isMe ? AppIcons.phone : AppIcons.phoneIncoming,
                    size: 16,
                    color: AppColors.primaryBrown,
                  ),
                ),
                const SizedBox(width: 10),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      durationLabel,
                      style: GoogleFonts.inter(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: AppColors.deepDarkBrown,
                      ),
                    ),
                    if (timeText.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        timeText,
                        style: GoogleFonts.inter(
                          fontSize: 11,
                          fontWeight: FontWeight.w400,
                          color: AppColors.muted.withValues(alpha: 0.7),
                        ),
                      ),
                    ],
                  ],
                ),
                if (tappable) ...[
                  const SizedBox(width: 14),
                  AppIcon(
                    AppIcons.phone,
                    size: 20,
                    color: AppColors.primaryBrown,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
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
        border: Border.all(color: AppColors.muted.withValues(alpha: 0.15)),
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
                Text(e.key, style: const TextStyle(fontSize: 13)),
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
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
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
            child: Text(widget.emoji, style: const TextStyle(fontSize: 32)),
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
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
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
            AppIcon(AppIcons.info, size: 14, color: AppColors.amberGold),
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
  // Locked rate from the session doc. Lets the card show
  // "X minutes left" — a concrete, actionable number — instead of
  // the raw coin count the user has to mentally divide. Falls back
  // to coin display when rate is non-positive (defensive only).
  final int ratePerMinute;
  final VoidCallback onAddCoins;

  const _LowBalanceMessage({
    required this.balance,
    required this.ratePerMinute,
    required this.onAddCoins,
  });

  String _headlineText() {
    if (ratePerMinute <= 0) return '$balance coins left';
    final minutes = balance ~/ ratePerMinute;
    if (minutes <= 0) return 'Less than 1 minute left';
    if (minutes == 1) return '1 minute of chat left';
    return '$minutes minutes of chat left';
  }

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
              child: AppIcon(
                AppIcons.bolt,
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
                    _headlineText(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
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
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
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
    final stale =
        since != null && DateTime.now().difference(since).inSeconds > 30;
    final showing = widget.isTyping && !stale;

    final composing =
        since != null && DateTime.now().difference(since).inSeconds >= 10;

    return AnimatedSize(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      child: showing
          ? Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
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
          AppIcon(
            AppIcons.chatOutline,
            size: 48,
            color: AppColors.muted.withValues(alpha: 0.2),
          ),
          const SizedBox(height: 16),
          Text(
            'Your session has started',
            style: GoogleFonts.inter(
              fontSize: 15,
              fontWeight: FontWeight.w500,
              color: AppColors.muted,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Take your time',
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
                color: AppColors.fieldFill,
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
                inputFormatters: [LengthLimitingTextInputFormatter(1000)],
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
                onPointerCancel: (_) => setState(() => _sendScale = 1.0),
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
                                  color: AppColors.primaryBrown.withValues(
                                    alpha: 0.2,
                                  ),
                                  blurRadius: 8,
                                  offset: const Offset(0, 2),
                                ),
                              ],
                      ),
                      child: widget.isSending
                          ? const Center(
                              child: SizedBox(
                                width: 29,
                                height: 29,
                                child: AppLoader(),
                              ),
                            )
                          : const AppIcon(
                              AppIcons.send,
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
              child: AppIcon(
                AppIcons.phoneEnd,
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
    return const Center(child: AppLoader());
  }
}

// ─── "↓ New message" pill ────────────────────────────────
//
// Floats over the bottom-center of the message list when an inbound
// message arrives while the user is scrolled up reading older
// content. Tapping hops them to the bottom and dismisses the pill.

// ─── Swipe-to-reply ──────────────────────────────────────

// Wraps a single bubble in a horizontal-drag gesture that, when
// pulled rightward past a threshold, fires onTriggered (the cubit
// stashes the message as the active reply target). The bubble
// rubber-bands during the drag and springs back to origin on
// release — matches the gesture vocabulary users already know
// from WhatsApp / Telegram.
//
// Design rules:
//   • Only rightward drag (negative dx is clamped to 0). Universal
//     direction across mine/theirs bubbles is simpler than two
//     mental models and matches the existing apps.
//   • 0.6× drag-to-translation ratio gives a small "I'm pulling
//     against a spring" feel without the bubble lagging the
//     finger so much it feels broken.
//   • Reply icon fades in proportional to drag distance, fully
//     opaque at the threshold.
//   • Medium-impact haptic exactly once at the moment we cross
//     the threshold — like Telegram's tactile "you've got it".
//   • On release, an AnimationController spring-back; we never
//     leave the bubble offset.
class _SwipeToReply extends StatefulWidget {
  final Widget child;
  final VoidCallback onTriggered;

  const _SwipeToReply({required this.child, required this.onTriggered});

  @override
  State<_SwipeToReply> createState() => _SwipeToReplyState();
}

class _SwipeToReplyState extends State<_SwipeToReply>
    with SingleTickerProviderStateMixin {
  static const double _threshold = 60.0;
  static const double _maxDrag = 90.0;
  static const double _dragRatio = 0.6;

  late final AnimationController _reset;
  double _dragDx = 0.0;
  double _resetFrom = 0.0;
  bool _triggered = false;

  @override
  void initState() {
    super.initState();
    _reset = AnimationController(
      duration: const Duration(milliseconds: 220),
      vsync: this,
    )..addListener(_onReset);
  }

  @override
  void dispose() {
    _reset.removeListener(_onReset);
    _reset.dispose();
    super.dispose();
  }

  void _onReset() {
    if (!mounted) return;
    final t = Curves.easeOutCubic.transform(_reset.value);
    setState(() => _dragDx = _resetFrom * (1 - t));
  }

  void _onUpdate(DragUpdateDetails d) {
    // Stop a pending spring-back if the finger comes back on the
    // glass before the reset finishes.
    if (_reset.isAnimating) _reset.stop();
    setState(() {
      _dragDx = (_dragDx + d.delta.dx * _dragRatio).clamp(0.0, _maxDrag);
      if (!_triggered && _dragDx >= _threshold) {
        _triggered = true;
        HapticFeedback.mediumImpact();
      }
    });
  }

  void _onEnd(DragEndDetails _) {
    final shouldFire = _triggered && _dragDx >= _threshold;
    _triggered = false;
    if (shouldFire) widget.onTriggered();
    _resetFrom = _dragDx;
    _reset.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    final dragT = (_dragDx / _threshold).clamp(0.0, 1.0);
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onHorizontalDragUpdate: _onUpdate,
      onHorizontalDragEnd: _onEnd,
      // CRITICAL: the bubble child must fill the row's full width so
      // its internal Padding + Column(crossAxisAlignment: end) can
      // right-align the sender bubble. Without `SizedBox(width: ∞)`
      // the bubble inside `Transform` shrinks to its intrinsic width
      // and the Stack positions that small chunk at top-start (LEFT)
      // — every wrapped current-session message would end up squashed
      // against the left edge regardless of isMe, even though the
      // bubble's colour (brown) and checkmark (sender) stay correct.
      // Past + pending + free-message bubbles bypass this wrapper, so
      // they were unaffected — that's why only live messages appeared
      // misaligned.
      child: Stack(
        children: [
          // Reply hint icon pinned to the left side, fades in
          // proportional to the drag. Wrapped in IgnorePointer so
          // it never eats gesture events meant for the bubble.
          IgnorePointer(
            child: Opacity(
              opacity: dragT,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Container(
                    width: 32,
                    height: 32,
                    margin: const EdgeInsets.only(left: 4),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: AppColors.primaryBrown.withValues(alpha: 0.12),
                    ),
                    child: AppIcon(
                      AppIcons.reply,
                      size: 16,
                      color: AppColors.primaryBrown.withValues(alpha: 0.85),
                    ),
                  ),
                ),
              ),
            ),
          ),
          Transform.translate(
            offset: Offset(_dragDx, 0),
            child: SizedBox(width: double.infinity, child: widget.child),
          ),
        ],
      ),
    );
  }
}

// ─── Reply compose chip (above the input bar) ────────────

// Sits between the typing footer and the input bar when the user
// has an active reply target. Slim, dismissable, with a left
// border accent matching the in-bubble quote line so the user
// sees the relationship at a glance. AnimatedSize gives the chip
// a smooth slide-in when it appears / out when dismissed; the
// content is only built when the target is non-null.
class _ReplyComposeChip extends StatelessWidget {
  final ChatMessage target;
  final String currentUid;
  final VoidCallback onDismiss;

  const _ReplyComposeChip({
    required this.target,
    required this.currentUid,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    final isMine = target.senderId == currentUid;
    final senderLabel = isMine
        ? 'You'
        : (target.senderName.isNotEmpty ? target.senderName : '');

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
      color: AppColors.surfaceWhite,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Left accent — matches the in-bubble quote line so the
          // user reads the chip as "this is the same quoted block
          // you'll see attached to the message you're typing".
          Container(
            width: 3,
            height: 36,
            decoration: BoxDecoration(
              color: AppColors.primaryBrown,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Replying to $senderLabel',
                  style: GoogleFonts.inter(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: AppColors.primaryBrown,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  target.text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.inter(
                    fontSize: 12,
                    fontWeight: FontWeight.w400,
                    color: AppColors.muted,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: () {
              HapticFeedback.selectionClick();
              onDismiss();
            },
            icon: AppIcon(
              AppIcons.close,
              size: 18,
              color: AppColors.muted.withValues(alpha: 0.7),
            ),
            padding: EdgeInsets.zero,
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
          ),
        ],
      ),
    );
  }
}

// ─── Reply preview inside a bubble ───────────────────────

// Rendered ABOVE the bubble's text when message.replyTo != null.
// Indented left border + small sender label + 2-line text snippet.
// Visual treatment matches the compose chip so the user sees one
// continuous "this is a reply" vocabulary across input and history.
//
// Color shifts based on whether the bubble is mine (brown bg, light
// quote) or theirs (white bg, brown quote) so contrast stays
// readable in both branches.
class _ReplyPreviewInBubble extends StatelessWidget {
  final ReplyTarget reply;
  final String currentUid;
  final bool isMineBubble;

  const _ReplyPreviewInBubble({
    required this.reply,
    required this.currentUid,
    required this.isMineBubble,
  });

  @override
  Widget build(BuildContext context) {
    final replyIsMine = reply.senderId == currentUid;
    final label = replyIsMine
        ? 'You'
        : (reply.senderName.isNotEmpty ? reply.senderName : 'Reply');

    // Minimal, low-visual-weight preview — WhatsApp style. On a
    // brown (mine) bubble everything tints light; on a white
    // (theirs) bubble we use a soft brown accent. Both keep the
    // snippet quieter than the main bubble text so the reply
    // header reads as supporting context, not as the message.
    final accent = isMineBubble
        ? Colors.white.withValues(alpha: 0.6)
        : AppColors.primaryBrown.withValues(alpha: 0.55);
    final labelColor = isMineBubble
        ? Colors.white.withValues(alpha: 0.85)
        : AppColors.primaryBrown;
    final snippetColor = isMineBubble
        ? Colors.white.withValues(alpha: 0.55)
        : AppColors.muted.withValues(alpha: 0.75);

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(width: 2, color: accent),
            const SizedBox(width: 6),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    label,
                    style: GoogleFonts.inter(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: labelColor,
                    ),
                  ),
                  Text(
                    reply.text,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.inter(
                      fontSize: 11,
                      fontWeight: FontWeight.w400,
                      height: 1.3,
                      color: snippetColor,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Helpers ─────────────────────────────────────────────

// Day separator above a message cluster — used by the bubble's
// `showTimestamp` branch. The shared util handles Today / Yesterday
// / weekday / "Apr 5" / "Apr 5, 2024" with proper calendar math.
String _formatTimestamp(DateTime? dt) => df.formatDayLabel(dt);

// Bubble footer time — always defers to the shared util so this
// surface, history pages, transcripts and bible cards never drift.
String _formatTime(DateTime? dt) => df.formatTime(dt);
