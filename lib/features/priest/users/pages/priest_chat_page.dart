// Priest-side per-user chat view. Replaces the session-detail
// "Send Follow-up" template picker as the primary way for a priest
// to message a past user.
//
// Layout:
//   [App bar — user name + photo only, no overflow menu]
//   [Scrollable chat thread:
//     • All past session messages, oldest-first, with session
//       dividers between groups
//     • Free messages (sent by priest, received nothing — this is
//       a one-way channel) interleaved by timestamp]
//   [Footer: rate-limit hint "12 of 15 left today"]
//   [Text input + Send button — 280-char hard cap, server enforces]
//
// Why one widget not three:
//   Past prefetch + live free-messages stream + rate-limit counter
//   all need to react together (a successful send updates the live
//   stream AND decrements the counter). Splitting them into
//   separate widgets would force prop-drilling or a shared cubit;
//   the surface is small enough that keeping the state in this
//   StatefulWidget is the cleaner choice.

import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:gospel_vox/core/services/injection_container.dart';
import 'package:gospel_vox/core/theme/app_colors.dart';
import 'package:gospel_vox/core/utils/date_format.dart' as df;
import 'package:gospel_vox/core/widgets/app_back_button.dart';
import 'package:gospel_vox/core/widgets/app_snackbar.dart';
import 'package:gospel_vox/features/shared/data/session_model.dart';
import 'package:gospel_vox/features/shared/data/session_repository.dart';
import 'package:gospel_vox/core/widgets/app_icons.dart';
import 'package:gospel_vox/features/shared/widgets/chat_session_view.dart'
    show CallEntryBubble;

const int _kMessageLengthLimit = 280;
const int _kPerUserDailyLimit = 3;

class PriestChatPage extends StatefulWidget {
  final String userId;
  final String userName;
  final String userPhotoUrl;

  const PriestChatPage({
    super.key,
    required this.userId,
    required this.userName,
    required this.userPhotoUrl,
  });

  @override
  State<PriestChatPage> createState() => _PriestChatPageState();
}

// Internal row types for the flat list. Mirrors the pattern used in
// chat_history_page so the visual rhythm of dividers + bubbles +
// (optional) free-message badge stays consistent across surfaces.
sealed class _Row {
  const _Row();
}

class _DividerRow extends _Row {
  final DateTime sessionDate;
  final int durationMinutes;
  const _DividerRow({required this.sessionDate, required this.durationMinutes});
}

class _BubbleRow extends _Row {
  final ChatMessage message;
  final bool isMine;
  const _BubbleRow({required this.message, required this.isMine});
}

// Inline row for a past voice call between this user and priest.
// Synthesized in getPastChatMessages from completed voice sessions
// — no Firestore message backs the row. Priest-side renders it
// inert (priests don't initiate calls).
class _CallEntryRow extends _Row {
  final ChatMessage message;
  final bool isMine;
  const _CallEntryRow({required this.message, required this.isMine});
}

class _PriestChatPageState extends State<PriestChatPage> {
  final TextEditingController _textController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  bool _isLoading = true;
  bool _isSending = false;
  // Drives the small "X of 3 left today" hint under the input. Only
  // refreshed on a successful send (the CF returns the remaining
  // counts) — we don't pre-read it on mount because the read would
  // duplicate state Firestore already maintains.
  int? _remainingToday;
  List<ChatMessage> _pastMessages = const [];
  Map<String, PastSessionMeta> _pastMeta = const {};
  List<ChatMessage> _freeMessages = const [];
  StreamSubscription<List<ChatMessage>>? _freeMessagesSub;

  @override
  void initState() {
    super.initState();
    _load();
    _attachStream();
  }

  @override
  void dispose() {
    _freeMessagesSub?.cancel();
    _textController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final priestUid = FirebaseAuth.instance.currentUser?.uid;
    if (priestUid == null) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      return;
    }

    if (mounted) setState(() => _isLoading = true);

    try {
      final past = await sl<SessionRepository>().getPastChatMessages(
        userId: widget.userId,
        priestId: priestUid,
        excludeSessionId: '',
      );
      if (!mounted) return;
      _pastMessages = past.messages;
      _pastMeta = past.meta;
      setState(() => _isLoading = false);
      _scheduleScrollToBottom();
    } on TimeoutException {
      if (!mounted) return;
      setState(() => _isLoading = false);
      AppSnackBar.error(context, 'Loading timed out. Pull down to retry.');
    } catch (_) {
      if (!mounted) return;
      setState(() => _isLoading = false);
    }
  }

  void _attachStream() {
    final priestUid = FirebaseAuth.instance.currentUser?.uid;
    if (priestUid == null) return;
    _freeMessagesSub = sl<SessionRepository>()
        .watchPriestFreeMessages(
          userId: widget.userId,
          priestId: priestUid,
        )
        .listen((messages) {
      if (!mounted) return;
      setState(() => _freeMessages = messages);
      _scheduleScrollToBottom();
    });
  }

  // Tracks whether the page has performed its initial land-on-bottom
  // jump. First call uses jumpTo (no animation — animating from
  // offset 0 through every old bubble feels janky and showed the
  // top message before settling at the bottom). Subsequent calls
  // (live free-message arrivals, successful sends) animate so the
  // motion reads as "new message appearing".
  bool _hasJumpedToBottom = false;

  // Posts a frame callback so the scroll happens after the new row
  // has been laid out — otherwise we're targeting maxScrollExtent
  // before the new content has been measured.
  void _scheduleScrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      final target = _scrollController.position.maxScrollExtent;
      if (!_hasJumpedToBottom) {
        _scrollController.jumpTo(target);
        _hasJumpedToBottom = true;
        return;
      }
      _scrollController.animateTo(
        target,
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOutCubic,
      );
    });
  }

  Future<void> _sendMessage() async {
    final text = _textController.text.trim();
    if (text.isEmpty || _isSending) return;

    HapticFeedback.lightImpact();
    setState(() => _isSending = true);

    try {
      final result = await sl<SessionRepository>().sendPriestMessage(
        userId: widget.userId,
        text: text,
      );
      if (!mounted) return;
      _textController.clear();
      setState(() {
        _isSending = false;
        _remainingToday = result.remainingPerUserToday;
      });
      // Surface a quiet success — but also flag silently-muted
      // delivery so the priest understands why their note may not
      // have reached the user. The CF still consumed the rate-
      // limit slot, so we tell them honestly.
      if (!result.delivered) {
        AppSnackBar.error(
          context,
          "Message saved but couldn't be delivered. The user may have "
              'turned off messages from you.',
        );
      } else {
        HapticFeedback.selectionClick();
      }
      _scheduleScrollToBottom();
    } on FirebaseFunctionsException catch (e) {
      if (!mounted) return;
      setState(() => _isSending = false);
      final message = _humaniseSendError(e);
      AppSnackBar.error(context, message);
    } on TimeoutException {
      if (!mounted) return;
      setState(() => _isSending = false);
      AppSnackBar.error(context, 'Send timed out. Try again.');
    } catch (_) {
      if (!mounted) return;
      setState(() => _isSending = false);
      AppSnackBar.error(context, "Couldn't send. Try again.");
    }
  }

  // Maps CF error codes to copy the priest can act on. Codes mirror
  // sendPriestMessage.ts exactly so a server-side rule change reads
  // through to UI without remapping in two places.
  String _humaniseSendError(FirebaseFunctionsException e) {
    final reason = '${e.code} ${e.message ?? ''}';
    if (reason.contains('Activate your account')) {
      return 'Activate your account before sending messages.';
    }
    if (reason.contains('Only approved speakers')) {
      return 'Only approved speakers can send messages.';
    }
    if (reason.contains('only message users')) {
      return 'You can only message users you\'ve had a session with.';
    }
    if (reason.contains('Daily message limit')) {
      return 'You\'ve hit your daily limit (15 messages per day).';
    }
    if (reason.contains('Daily limit per user')) {
      return 'You\'ve hit the daily limit for this user (3 per day).';
    }
    if (reason.contains('exceeds')) {
      return 'Message is too long. Keep it under $_kMessageLengthLimit characters.';
    }
    return 'Couldn\'t send. Try again.';
  }

  // Builds the timeline once per state change. Past + free
  // interleaved by timestamp; session dividers injected at every
  // sessionId boundary on session-kind bubbles.
  List<_Row> _buildRows(String priestUid) {
    final timeline = <ChatMessage>[..._pastMessages, ..._freeMessages]
      ..sort((a, b) {
        final aTime = a.createdAt ?? DateTime(2000);
        final bTime = b.createdAt ?? DateTime(2000);
        return aTime.compareTo(bTime);
      });

    final rows = <_Row>[];
    String? prevSessionId;
    for (final m in timeline) {
      if (m.kind == ChatMessageKind.session) {
        final sid = m.sessionId;
        if (sid != prevSessionId) {
          final meta = _pastMeta[sid];
          if (meta != null) {
            rows.add(_DividerRow(
              sessionDate: meta.date,
              durationMinutes: meta.durationMinutes,
            ));
          }
          prevSessionId = sid;
        }
      }
      // Priest's own bubble = senderId == this priest's uid. For a
      // call entry the senderId is the caller (always the user in
      // the current product), so the call row reads as "incoming"
      // from the priest's perspective.
      final isMine = m.senderId == priestUid;
      if (m.isCallEntry) {
        rows.add(_CallEntryRow(message: m, isMine: isMine));
      } else {
        rows.add(_BubbleRow(message: m, isMine: isMine));
      }
    }
    return rows;
  }

  @override
  Widget build(BuildContext context) {
    final priestUid = FirebaseAuth.instance.currentUser?.uid ?? '';

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: _buildAppBar(),
      body: SafeArea(
        bottom: false,
        top: false,
        child: Column(
          children: [
            Expanded(
              child: _isLoading
                  ? const Center(
                      child: SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.4,
                          color: AppColors.primaryBrown,
                        ),
                      ),
                    )
                  : _buildList(priestUid),
            ),
            _buildInputBar(),
          ],
        ),
      ),
    );
  }

  PreferredSizeWidget _buildAppBar() {
    final initial = widget.userName.isNotEmpty
        ? widget.userName[0].toUpperCase()
        : '?';

    return AppBar(
      backgroundColor: AppColors.background,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
      centerTitle: false,
      leadingWidth: 60,
      leading: const Padding(
        padding: EdgeInsets.only(left: 16),
        child: AppBackButton(),
      ),
      title: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: const Color(0xFFF7F5F2),
              border: Border.all(
                color: AppColors.muted.withValues(alpha: 0.12),
                width: 1.5,
              ),
            ),
            clipBehavior: Clip.antiAlias,
            child: widget.userPhotoUrl.isNotEmpty
                ? CachedNetworkImage(
                    imageUrl: widget.userPhotoUrl,
                    fit: BoxFit.cover,
                    placeholder: (_, _) => const SizedBox.shrink(),
                    errorWidget: (_, _, _) => _initialFallback(initial),
                  )
                : _initialFallback(initial),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              widget.userName.isNotEmpty ? widget.userName : 'User',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.inter(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: AppColors.deepDarkBrown,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _initialFallback(String initial) {
    return Center(
      child: Text(
        initial,
        style: GoogleFonts.inter(
          fontSize: 14,
          fontWeight: FontWeight.w700,
          color: AppColors.muted,
        ),
      ),
    );
  }

  Widget _buildList(String priestUid) {
    final rows = _buildRows(priestUid);
    if (rows.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 40),
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
                'No messages yet',
                style: GoogleFonts.inter(
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                  color: AppColors.muted,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Send a quick note to stay in touch',
                style: GoogleFonts.inter(
                  fontSize: 13,
                  fontWeight: FontWeight.w400,
                  color: AppColors.muted.withValues(alpha: 0.6),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return ListView.builder(
      controller: _scrollController,
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      itemCount: rows.length,
      itemBuilder: (_, i) {
        final row = rows[i];
        if (row is _DividerRow) {
          return _SessionDivider(
            date: row.sessionDate,
            durationMinutes: row.durationMinutes,
          );
        }
        if (row is _CallEntryRow) {
          // Inert on priest side — priests don't initiate calls in
          // the current product. IgnorePointer lets touches fall
          // through to the parent ListView so a tap on the row
          // doesn't swallow scroll attempts that started on it.
          return IgnorePointer(
            child: CallEntryBubble(
              message: row.message,
              isMe: row.isMine,
              onTap: null,
            ),
          );
        }
        final bubble = row as _BubbleRow;
        return _MessageBubble(
          message: bubble.message,
          isMine: bubble.isMine,
        );
      },
    );
  }

  Widget _buildInputBar() {
    final bottomInset = MediaQuery.of(context).padding.bottom;
    final remaining = _remainingToday;

    return Container(
      padding: EdgeInsets.fromLTRB(16, 10, 8, bottomInset + 10),
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
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
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
                    controller: _textController,
                    maxLines: null,
                    minLines: 1,
                    textCapitalization: TextCapitalization.sentences,
                    inputFormatters: [
                      LengthLimitingTextInputFormatter(_kMessageLengthLimit),
                    ],
                    style: GoogleFonts.inter(
                      fontSize: 14,
                      fontWeight: FontWeight.w400,
                      color: AppColors.deepDarkBrown,
                    ),
                    decoration: InputDecoration(
                      hintText: 'Send a free message…',
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
                    onChanged: (_) => setState(() {}),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              ValueListenableBuilder<TextEditingValue>(
                valueListenable: _textController,
                builder: (_, value, _) {
                  final hasText = value.text.trim().isNotEmpty;
                  final disabled = _isSending || !hasText;
                  return GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: disabled ? null : _sendMessage,
                    child: Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: AppColors.primaryBrown.withValues(
                          alpha: disabled ? 0.35 : 1.0,
                        ),
                      ),
                      child: _isSending
                          ? const Center(
                              child: SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              ),
                            )
                          : const AppIcon(
                              AppIcons.send,
                              size: 20,
                              color: Colors.white,
                            ),
                    ),
                  );
                },
              ),
            ],
          ),
          // Footer row — character counter on the left, daily-limit
          // hint on the right when we know it. The hint is hidden
          // before the first send because pre-reading the counter
          // is wasteful for a value the priest sees on send.
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 6, 12, 0),
            child: Row(
              children: [
                Text(
                  '${_textController.text.length}/$_kMessageLengthLimit',
                  style: GoogleFonts.inter(
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    color: AppColors.muted.withValues(alpha: 0.5),
                  ),
                ),
                const Spacer(),
                if (remaining != null)
                  Text(
                    '$remaining of $_kPerUserDailyLimit left today',
                    style: GoogleFonts.inter(
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      color: remaining == 0
                          ? AppColors.errorRed
                          : AppColors.muted.withValues(alpha: 0.5),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Session divider ─────────────────────────────────────────

class _SessionDivider extends StatelessWidget {
  final DateTime date;
  final int durationMinutes;

  const _SessionDivider({
    required this.date,
    required this.durationMinutes,
  });

  @override
  Widget build(BuildContext context) {
    final label = durationMinutes > 0
        ? 'Session · ${_formatDate(date)} · $durationMinutes min'
        : 'Session · ${_formatDate(date)}';

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

  String _formatDate(DateTime date) => df.formatDayCompact(date);
}

// ─── Bubble ──────────────────────────────────────────────────

class _MessageBubble extends StatelessWidget {
  final ChatMessage message;
  final bool isMine;

  const _MessageBubble({required this.message, required this.isMine});

  @override
  Widget build(BuildContext context) {
    if (message.text.isEmpty) return const SizedBox.shrink();

    final maxBubbleWidth = MediaQuery.of(context).size.width * 0.72;
    final isFree = message.isPriestMessage;

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment:
            isMine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          if (isFree)
            Padding(
              padding: EdgeInsets.only(
                bottom: 4,
                left: isMine ? 0 : 4,
                right: isMine ? 4 : 0,
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
          Row(
            mainAxisAlignment:
                isMine ? MainAxisAlignment.end : MainAxisAlignment.start,
            children: [
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: maxBubbleWidth),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: isMine
                        ? AppColors.primaryBrown
                        : AppColors.surfaceWhite,
                    borderRadius: BorderRadius.only(
                      topLeft: const Radius.circular(16),
                      topRight: const Radius.circular(16),
                      bottomLeft: Radius.circular(isMine ? 16 : 4),
                      bottomRight: Radius.circular(isMine ? 4 : 16),
                    ),
                    border: isMine
                        ? null
                        : Border.all(
                            color: AppColors.muted.withValues(alpha: 0.08),
                          ),
                    boxShadow: isMine
                        ? null
                        : [
                            BoxShadow(
                              blurRadius: 3,
                              offset: const Offset(0, 1),
                              color: Colors.black.withValues(alpha: 0.02),
                            ),
                          ],
                  ),
                  child: Text(
                    message.text,
                    style: GoogleFonts.inter(
                      fontSize: 14,
                      fontWeight: FontWeight.w400,
                      height: 1.4,
                      color: isMine
                          ? Colors.white
                          : AppColors.deepDarkBrown,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
