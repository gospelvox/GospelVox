// Read-only chat transcript for a finished session. Shared between
// user and priest sides — sender alignment is decided per-bubble by
// comparing senderId to the signed-in uid, so we never need a flag
// to know "which side am I viewing this from".
//
// What this page deliberately does NOT do:
//   • No input bar (the session is over — no new messages can be sent)
//   • No timer / heartbeat / billing (those drive a live session only)
//   • No typing indicators or reactions (no second party in the loop)
//   • No streaming — sessions/{id}/messages is fetched once on init.
//     A finished session can't gain new messages, and a snapshot
//     listener would just hold open a socket for nothing.

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:gospel_vox/core/theme/app_colors.dart';
import 'package:gospel_vox/features/shared/data/session_history_repository.dart';
import 'package:gospel_vox/features/shared/data/session_model.dart';

class ChatTranscriptPage extends StatefulWidget {
  final String sessionId;
  final String otherName;
  final String sessionDate;

  const ChatTranscriptPage({
    super.key,
    required this.sessionId,
    required this.otherName,
    required this.sessionDate,
  });

  @override
  State<ChatTranscriptPage> createState() => _ChatTranscriptPageState();
}

class _ChatTranscriptPageState extends State<ChatTranscriptPage> {
  final SessionHistoryRepository _repository = SessionHistoryRepository();

  bool _isLoading = true;
  String? _error;
  List<ChatMessage> _messages = [];

  @override
  void initState() {
    super.initState();
    _loadMessages();
  }

  Future<void> _loadMessages() async {
    try {
      final messages =
          await _repository.getSessionMessages(widget.sessionId);
      if (!mounted) return;
      setState(() {
        _messages = messages;
        _isLoading = false;
        _error = null;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = 'Failed to load messages';
        _isLoading = false;
      });
    }
  }

  void _retry() {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    _loadMessages();
  }

  @override
  Widget build(BuildContext context) {
    final currentUid = FirebaseAuth.instance.currentUser?.uid ?? '';

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: _buildAppBar(context),
      body: _buildBody(currentUid),
    );
  }

  PreferredSizeWidget _buildAppBar(BuildContext context) {
    return AppBar(
      backgroundColor: AppColors.surfaceWhite,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
      centerTitle: false,
      leadingWidth: 60,
      leading: Padding(
        padding: const EdgeInsets.only(left: 16),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => context.pop(),
          child: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: const Color(0xFFF7F5F2),
            ),
            child: Icon(
              Icons.arrow_back_ios_new,
              size: 16,
              color: AppColors.deepDarkBrown,
            ),
          ),
        ),
      ),
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            widget.otherName.isNotEmpty ? widget.otherName : 'Chat',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: GoogleFonts.inter(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: AppColors.deepDarkBrown,
            ),
          ),
          if (widget.sessionDate.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              widget.sessionDate,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.inter(
                fontSize: 11,
                fontWeight: FontWeight.w400,
                color: AppColors.muted,
              ),
            ),
          ],
        ],
      ),
      bottom: PreferredSize(
        preferredSize: const Size.fromHeight(1),
        child: Container(
          height: 1,
          color: AppColors.muted.withValues(alpha: 0.08),
        ),
      ),
    );
  }

  Widget _buildBody(String currentUid) {
    if (_isLoading) {
      return const Center(
        child: CircularProgressIndicator(
          color: AppColors.primaryBrown,
          strokeWidth: 2.5,
        ),
      );
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.error_outline,
                size: 48,
                color: AppColors.muted.withValues(alpha: 0.3),
              ),
              const SizedBox(height: 16),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: GoogleFonts.inter(
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                  color: AppColors.muted,
                ),
              ),
              const SizedBox(height: 16),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _retry,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.primaryBrown.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    'Retry',
                    style: GoogleFonts.inter(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: AppColors.primaryBrown,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (_messages.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
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
                'No messages in this session',
                textAlign: TextAlign.center,
                style: GoogleFonts.inter(
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                  color: AppColors.muted,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return ListView.builder(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      itemCount: _messages.length,
      itemBuilder: (_, index) {
        final msg = _messages[index];
        final isMe = msg.senderId == currentUid;
        return _TranscriptBubble(
          message: msg,
          isMe: isMe,
          showDate: _shouldShowDate(index),
        );
      },
    );
  }

  // Show a "Today / Yesterday / Mar 14, 2026" pill above the first
  // message of every new day. The first bubble always gets one.
  bool _shouldShowDate(int index) {
    if (index == 0) return true;
    final prev = _messages[index - 1].createdAt;
    final curr = _messages[index].createdAt;
    if (prev == null || curr == null) return false;
    return prev.day != curr.day ||
        prev.month != curr.month ||
        prev.year != curr.year;
  }
}

// ─── Read-only transcript bubble ───────────────────────────

class _TranscriptBubble extends StatelessWidget {
  final ChatMessage message;
  final bool isMe;
  final bool showDate;

  const _TranscriptBubble({
    required this.message,
    required this.isMe,
    required this.showDate,
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
          if (showDate)
            Padding(
              padding: const EdgeInsets.only(bottom: 12, top: 8),
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.muted.withValues(alpha: 0.06),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    _formatMessageDate(message.createdAt),
                    style: GoogleFonts.inter(
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      color: AppColors.muted,
                    ),
                  ),
                ),
              ),
            ),
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: 14,
              vertical: 10,
            ),
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
                  color: Colors.black.withValues(alpha: 0.03),
                  blurRadius: 4,
                  offset: const Offset(0, 1),
                ),
              ],
            ),
            child: Text(
              message.text,
              style: GoogleFonts.inter(
                fontSize: 14,
                fontWeight: FontWeight.w400,
                color: isMe ? Colors.white : AppColors.deepDarkBrown,
                height: 1.45,
              ),
            ),
          ),
          const SizedBox(height: 3),
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

// ─── Date formatters ───────────────────────────────────────

String _formatTime(DateTime? time) {
  if (time == null) return '';
  final hour =
      time.hour > 12 ? time.hour - 12 : (time.hour == 0 ? 12 : time.hour);
  final period = time.hour >= 12 ? 'PM' : 'AM';
  final minute = time.minute.toString().padLeft(2, '0');
  return '$hour:$minute $period';
}

String _formatMessageDate(DateTime? date) {
  if (date == null) return '';
  final now = DateTime.now();
  if (date.day == now.day &&
      date.month == now.month &&
      date.year == now.year) {
    return 'Today';
  }
  final yesterday = now.subtract(const Duration(days: 1));
  if (date.day == yesterday.day &&
      date.month == yesterday.month &&
      date.year == yesterday.year) {
    return 'Yesterday';
  }
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  return '${months[date.month - 1]} ${date.day}, ${date.year}';
}
