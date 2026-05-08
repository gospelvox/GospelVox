// User-side chat history page — opens when the user taps a row in
// the Chats sub-tab of the Sessions tab.
//
// Renders every message from completed chat sessions with this
// priest, oldest at top, newest at bottom (natural chat reading
// order). Sessions are visually grouped by a "Session · <date>"
// divider so the user can tell where one conversation ended and
// the next began.
//
// IMPORTANT: this is NOT a chat surface. There is no input bar, no
// typing indicator, no reply path. To say anything to the priest the
// user starts a new PAID session via the sticky bottom button,
// which fires createSessionRequest directly (no profile detour).
//
// History is capped at the most-recent 200 messages across all past
// sessions — same cap the live chat surface uses, so the two views
// agree on what "your conversation with this priest" means. Older
// sessions still exist in Firestore and remain accessible via
// Me → Session History → tap a session → View Chat Transcript.
//
// Rate displayed on the bottom button is the global chat rate from
// app_config/settings.chatRatePerMinute, NOT a per-priest rate —
// matches what createSessionRequest CF locks into the new session.

import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:gospel_vox/core/services/injection_container.dart';
import 'package:gospel_vox/core/theme/app_colors.dart';
import 'package:gospel_vox/core/widgets/app_snackbar.dart';
import 'package:gospel_vox/features/shared/data/session_model.dart';
import 'package:gospel_vox/features/shared/data/session_preflight.dart';
import 'package:gospel_vox/features/shared/data/session_repository.dart';

const Color _kOnlineGreen = Color(0xFF059669);
const int _kFallbackChatRate = 10;
// Same cap the live chat uses for prefetched history. Keeps both
// surfaces aligned on what "your conversation" means and prevents
// the read-only history page from blowing up on a power user who
// has hundreds of sessions with the same priest.
const int _kHistoryMessageCap = 200;

class ChatHistoryPage extends StatefulWidget {
  final String priestId;
  final String priestName;
  final String priestPhotoUrl;

  const ChatHistoryPage({
    super.key,
    required this.priestId,
    required this.priestName,
    required this.priestPhotoUrl,
  });

  @override
  State<ChatHistoryPage> createState() => _ChatHistoryPageState();
}

// Each entry the ListView renders is one of these. Mixing dividers
// and bubbles in a single list (instead of grouping in a Column per
// session) keeps the auto-scroll-to-bottom and pull-to-refresh
// behavior clean — there's only one ListView, not one per session.
sealed class _Item {
  const _Item();
}

class _Divider extends _Item {
  final DateTime sessionDate;
  const _Divider(this.sessionDate);
}

class _Bubble extends _Item {
  final ChatMessage message;
  final bool isMine;
  const _Bubble({required this.message, required this.isMine});
}

class _ChatHistoryPageState extends State<ChatHistoryPage> {
  bool _isLoading = true;
  bool _isOnline = false;
  bool _isBusy = false;
  int _chatRatePerMinute = _kFallbackChatRate;
  List<_Item> _items = const [];
  // Fallback name + photo, populated from priests/{id} when the
  // page opens with empty extras (e.g. a tap from a push notification
  // or other deep link). Real-time priest name changes are rare
  // enough that we read once and cache; the AppBar reflects whatever
  // we can resolve, falling back to "Speaker" if nothing comes back.
  String? _fallbackPriestName;
  String? _fallbackPriestPhotoUrl;
  // Whether the user has muted this priest. Streamed from
  // users/{uid}.mutedPriestIds so a settings-page unmute reflects
  // here within ~1s without a manual refresh. Drives the kebab
  // menu copy ("Mute" vs "Unmute") and the live filter on
  // priest_message bubbles.
  bool _isMuted = false;
  StreamSubscription<Set<String>>? _muteSub;
  StreamSubscription<List<ChatMessage>>? _freeMessagesSub;
  // Latest snapshot of free messages for this (user, priest) pair.
  // We re-merge into _items whenever it changes OR the past load
  // completes, so a free message landing while the user is on
  // this page slides in without a refresh.
  List<ChatMessage> _freeMessages = const [];
  // Keep the latest result of the past prefetch so we can re-merge
  // it cheaply when a free-message snapshot arrives. The prefetch
  // is one-shot; we just hold the result.
  List<ChatMessage> _pastMessages = const [];
  Map<String, PastSessionMeta> _pastMeta = const {};
  // Latest message overall (session OR free) — drives the sticky
  // CTA copy. When the latest is a free priest message the button
  // reads "Reply · Start Session" instead of "Start New Session".
  ChatMessage? _latestMessage;

  @override
  void initState() {
    super.initState();
    _loadData();
    _attachStreams();
  }

  @override
  void dispose() {
    _muteSub?.cancel();
    _freeMessagesSub?.cancel();
    super.dispose();
  }

  void _attachStreams() {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    final repo = sl<SessionRepository>();
    _muteSub = repo.watchMutedPriestIds(uid).listen((ids) {
      if (!mounted) return;
      final muted = ids.contains(widget.priestId);
      if (muted == _isMuted) return;
      setState(() => _isMuted = muted);
      _rebuildItems();
    });
    _freeMessagesSub = repo
        .watchPriestFreeMessages(
          userId: uid,
          priestId: widget.priestId,
        )
        .listen((messages) {
      if (!mounted) return;
      // User-side surface: drop messages the CF wrote as
      // delivered=false (muted at send time). Belt-and-braces with
      // the mute-list filter in _rebuildItems — even if the local
      // mute state is stale, delivered=false is authoritative.
      _freeMessages = messages.where((m) => m.delivered).toList();
      _rebuildItems();
    });
  }

  Future<void> _loadData() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      return;
    }

    if (mounted) setState(() => _isLoading = true);

    try {
      final db = FirebaseFirestore.instance;

      // Past-message prefetch goes through the same SessionRepository
      // method the live chat uses, so both surfaces see identical
      // data: completed chat sessions only, oldest dropped first at
      // the 200-message cap, with sessionId stamped on each bubble
      // for the divider boundaries.
      final pastFuture = sl<SessionRepository>().getPastChatMessages(
        userId: uid,
        priestId: widget.priestId,
        // No live session to exclude here — pass an impossible id
        // so every completed chat is eligible.
        excludeSessionId: '',
        cap: _kHistoryMessageCap,
      );

      // Priest live status + global chat rate fetched in parallel.
      final priestFuture = db
          .doc('priests/${widget.priestId}')
          .get()
          .timeout(const Duration(seconds: 5))
          .then<Map<String, dynamic>?>((s) => s.exists ? s.data() : null)
          .catchError((_) => null);

      final settingsFuture = db
          .doc('app_config/settings')
          .get()
          .timeout(const Duration(seconds: 5))
          .then<Map<String, dynamic>?>((s) => s.exists ? s.data() : null)
          .catchError((_) => null);

      final results = await Future.wait<Object?>([
        pastFuture,
        priestFuture,
        settingsFuture,
      ]);

      final past = results[0] as ({
        List<ChatMessage> messages,
        Map<String, PastSessionMeta> meta,
      });
      final priestData = results[1] as Map<String, dynamic>?;
      final settings = results[2] as Map<String, dynamic>?;

      final isOnline = (priestData?['isOnline'] as bool?) ?? false;
      final isBusy = (priestData?['isBusy'] as bool?) ?? false;
      final rate = (settings?['chatRatePerMinute'] as num?)?.toInt() ??
          _kFallbackChatRate;
      // Resolve name + photo from the priest doc only when the
      // route extras didn't supply them (e.g. push-notification deep
      // link, where FCM data is string-only). When extras already
      // carry the values we leave the fallbacks null and prefer the
      // extras since they're the most contextually-fresh.
      final String? fallbackName = widget.priestName.isEmpty
          ? (priestData?['fullName'] as String?)
          : null;
      final String? fallbackPhoto = widget.priestPhotoUrl.isEmpty
          ? (priestData?['photoUrl'] as String?)
          : null;

      _pastMessages = past.messages;
      _pastMeta = past.meta;

      if (!mounted) return;
      setState(() {
        _isOnline = isOnline;
        _isBusy = isBusy;
        _chatRatePerMinute = rate;
        _fallbackPriestName = fallbackName;
        _fallbackPriestPhotoUrl = fallbackPhoto;
        _isLoading = false;
      });
      _rebuildItems();
    } on TimeoutException {
      if (!mounted) return;
      setState(() => _isLoading = false);
    } catch (_) {
      if (!mounted) return;
      setState(() => _isLoading = false);
    }
  }

  // Rebuilds the flat _items list from the cached past prefetch +
  // free-message snapshot + mute state. Called whenever any of the
  // three change so the list stays consistent without a re-fetch.
  void _rebuildItems() {
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';

    // Free messages from a muted priest are dropped here as well as
    // server-side. Mute is per-priest on this page (we already know
    // which priest the page is for), so a single boolean is enough.
    final visibleFree = _isMuted ? const <ChatMessage>[] : _freeMessages;

    // Past + free interleaved by createdAt — same merge contract the
    // chat cubit uses for the live surface, so both screens look
    // identical when reading the same data.
    final timeline = <ChatMessage>[..._pastMessages, ...visibleFree]
      ..sort((a, b) {
        final aTime = a.createdAt ?? DateTime(2000);
        final bTime = b.createdAt ?? DateTime(2000);
        return aTime.compareTo(bTime);
      });

    final items = <_Item>[];
    String? prevSessionId;
    for (final m in timeline) {
      // Past-session bubbles inject a session divider on every
      // sessionId boundary. Free messages have no sessionId and
      // never produce a divider — they flow inline at their
      // timestamp position.
      if (m.kind == ChatMessageKind.session) {
        final sid = m.sessionId;
        if (sid != prevSessionId) {
          final meta = _pastMeta[sid];
          if (meta != null) {
            items.add(_Divider(meta.date));
          }
          prevSessionId = sid;
        }
      }
      items.add(_Bubble(message: m, isMine: m.senderId == uid));
    }

    if (!mounted) return;
    setState(() {
      _items = items;
      _latestMessage = timeline.isNotEmpty ? timeline.last : null;
    });
  }

  bool get _isAvailable => _isOnline && !_isBusy;

  String get _statusLabel {
    if (_isAvailable) return 'Online';
    if (_isBusy) return 'Busy';
    return 'Offline';
  }

  Color get _statusColor {
    if (_isAvailable) return _kOnlineGreen;
    if (_isBusy) return AppColors.amberGold;
    return AppColors.muted;
  }

  // Direct session launch — runs the client-side balance preflight
  // first (5-min minimum gate; opens RechargeSheet if short), then
  // pushes /session/waiting which mounts SessionRequestCubit and
  // fires createSessionRequest. The waiting page handles every
  // server-side outcome (insufficient-balance, priest-offline,
  // priest-busy, accepted, expired). No profile detour.
  //
  // Denomination isn't loaded on this page — passing empty is fine,
  // the waiting screen renders the speaker block without it. The
  // chat rate is already loaded so we hand it to the preflight
  // helper to skip a redundant settings read.
  Future<void> _startChatSession() async {
    final canStart = await SessionPreflight.check(
      context,
      type: 'chat',
      priestName: _displayPriestName,
      prefetchedRatePerMinute: _chatRatePerMinute,
    );
    if (!canStart || !mounted) return;
    context.push('/session/waiting', extra: <String, dynamic>{
      'priestId': widget.priestId,
      'priestName': _displayPriestName,
      'priestPhotoUrl': _displayPriestPhotoUrl,
      'priestDenomination': '',
      'type': 'chat',
    });
  }

  // Tapping the priest's avatar/name in the app bar still opens the
  // full profile — the profile becomes optional, accessed by intent
  // rather than forced into every flow.
  void _openProfile() {
    context.push('/user/priest/${widget.priestId}');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: _buildAppBar(),
      body: _isLoading
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
          : Column(
              children: [
                Expanded(
                  child: _items.isEmpty ? _buildEmpty() : _buildList(),
                ),
                _buildStickyCTA(),
              ],
            ),
    );
  }

  // ─── App bar ────────────────────────────────────────────

  // Effective name + photo, preferring the route extras and falling
  // back to whatever we resolved from priests/{id}. The AppBar reads
  // these so a push-notification deep link (which can't carry extras)
  // still renders a populated header within ~300ms of opening.
  String get _displayPriestName => widget.priestName.isNotEmpty
      ? widget.priestName
      : (_fallbackPriestName ?? '');
  String get _displayPriestPhotoUrl => widget.priestPhotoUrl.isNotEmpty
      ? widget.priestPhotoUrl
      : (_fallbackPriestPhotoUrl ?? '');

  PreferredSizeWidget _buildAppBar() {
    final name = _displayPriestName;
    final photo = _displayPriestPhotoUrl;
    final initial = name.isNotEmpty ? name[0].toUpperCase() : '?';

    return AppBar(
      backgroundColor: AppColors.background,
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
              color: AppColors.surfaceWhite,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.04),
                  blurRadius: 6,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Icon(
              Icons.arrow_back_ios_new,
              size: 16,
              color: AppColors.deepDarkBrown,
            ),
          ),
        ),
      ),
      title: GestureDetector(
        // Tapping the title row opens the priest profile — keeps
        // the profile reachable from the chat without forcing it
        // into the navigation path.
        behavior: HitTestBehavior.opaque,
        onTap: _openProfile,
        child: Row(
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
              child: photo.isNotEmpty
                  ? CachedNetworkImage(
                      imageUrl: photo,
                      fit: BoxFit.cover,
                      placeholder: (_, _) => const SizedBox.shrink(),
                      errorWidget: (_, _, _) => _appBarInitial(initial),
                    )
                  : _appBarInitial(initial),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    name.isNotEmpty ? name : 'Speaker',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.inter(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: AppColors.deepDarkBrown,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _isMuted ? 'Muted · $_statusLabel' : _statusLabel,
                    style: GoogleFonts.inter(
                      fontSize: 11,
                      fontWeight: FontWeight.w400,
                      color: _isMuted ? AppColors.muted : _statusColor,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        // Kebab menu — single point of entry for mute/unmute and
        // viewing the speaker profile. Keeps the AppBar clean for
        // the common chat-reading case.
        PopupMenuButton<String>(
          icon: Icon(
            Icons.more_vert_rounded,
            color: AppColors.deepDarkBrown,
          ),
          onSelected: (value) {
            switch (value) {
              case 'mute':
                _toggleMute();
                break;
              case 'profile':
                _openProfile();
                break;
            }
          },
          itemBuilder: (_) => [
            PopupMenuItem(
              value: 'mute',
              child: Row(
                children: [
                  Icon(
                    _isMuted
                        ? Icons.notifications_active_outlined
                        : Icons.notifications_off_outlined,
                    size: 18,
                    color: AppColors.deepDarkBrown,
                  ),
                  const SizedBox(width: 12),
                  Text(_isMuted ? 'Unmute speaker' : 'Mute speaker'),
                ],
              ),
            ),
            PopupMenuItem(
              value: 'profile',
              child: Row(
                children: [
                  Icon(
                    Icons.person_outline_rounded,
                    size: 18,
                    color: AppColors.deepDarkBrown,
                  ),
                  const SizedBox(width: 12),
                  const Text('View profile'),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(width: 4),
      ],
    );
  }

  Widget _appBarInitial(String initial) {
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

  // ─── Message list ───────────────────────────────────────

  Widget _buildList() {
    return RefreshIndicator(
      color: AppColors.primaryBrown,
      backgroundColor: AppColors.surfaceWhite,
      onRefresh: _loadData,
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(
          parent: BouncingScrollPhysics(),
        ),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        itemCount: _items.length,
        itemBuilder: (_, i) {
          final item = _items[i];
          if (item is _Divider) {
            return _SessionDivider(date: item.sessionDate);
          }
          if (item is _Bubble) {
            return _MessageBubble(
              message: item.message,
              isMine: item.isMine,
              onReport: item.message.isPriestMessage
                  ? () => _reportMessage(item.message)
                  : null,
            );
          }
          return const SizedBox.shrink();
        },
      ),
    );
  }

  // Long-press on a priest free message → report. Files into the
  // existing reports collection so the admin queue picks it up
  // without any new admin-side wiring. Snack confirms the file.
  Future<void> _reportMessage(ChatMessage message) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    HapticFeedback.mediumImpact();

    final confirm = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: AppColors.surfaceWhite,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) => _ReportConfirmSheet(
        priestName: _displayPriestName.isNotEmpty
            ? _displayPriestName
            : 'this speaker',
        messageText: message.text,
        onConfirm: () => Navigator.of(sheetContext).pop(true),
        onCancel: () => Navigator.of(sheetContext).pop(false),
      ),
    );

    if (confirm != true || !mounted) return;

    try {
      final user = FirebaseAuth.instance.currentUser;
      await sl<SessionRepository>().reportPriestMessage(
        reportedPriestId: widget.priestId,
        reportedPriestName: _displayPriestName,
        reporterUserId: uid,
        reporterName: user?.displayName ?? '',
        messageText: message.text,
        messageId: message.id,
      );
      if (!mounted) return;
      AppSnackBar.success(context, 'Report sent. Our team will review.');
    } catch (_) {
      if (!mounted) return;
      AppSnackBar.error(context, 'Could not file report. Try again.');
    }
  }

  Future<void> _toggleMute() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    HapticFeedback.selectionClick();
    final next = !_isMuted;
    try {
      await sl<SessionRepository>().setPriestMuted(
        userId: uid,
        priestId: widget.priestId,
        muted: next,
      );
      if (!mounted) return;
      final displayName = _displayPriestName.isNotEmpty
          ? _displayPriestName
          : 'this speaker';
      AppSnackBar.success(
        context,
        next
            ? 'Muted. Future messages from $displayName are hidden.'
            : 'Unmuted. You\'ll see new messages from $displayName.',
      );
    } catch (_) {
      if (!mounted) return;
      AppSnackBar.error(context, 'Could not update mute state.');
    }
  }

  // ─── Empty state ────────────────────────────────────────

  Widget _buildEmpty() {
    return RefreshIndicator(
      color: AppColors.primaryBrown,
      backgroundColor: AppColors.surfaceWhite,
      onRefresh: _loadData,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(
          parent: BouncingScrollPhysics(),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 40),
        children: [
          SizedBox(height: MediaQuery.of(context).size.height * 0.12),
          Center(
            child: Container(
              width: 96,
              height: 96,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.muted.withValues(alpha: 0.06),
              ),
              child: Icon(
                Icons.chat_bubble_outline_rounded,
                size: 40,
                color: AppColors.muted.withValues(alpha: 0.3),
              ),
            ),
          ),
          const SizedBox(height: 20),
          Text(
            'No recent chats',
            textAlign: TextAlign.center,
            style: GoogleFonts.inter(
              fontSize: 17,
              fontWeight: FontWeight.w600,
              color: AppColors.muted.withValues(alpha: 0.5),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'No chat messages with this speaker yet.\nStart a new conversation below.',
            textAlign: TextAlign.center,
            style: GoogleFonts.inter(
              fontSize: 13,
              fontWeight: FontWeight.w400,
              height: 1.5,
              color: AppColors.muted.withValues(alpha: 0.4),
            ),
          ),
        ],
      ),
    );
  }

  // ─── Sticky bottom CTA ──────────────────────────────────

  Widget _buildStickyCTA() {
    final bottomInset = MediaQuery.of(context).padding.bottom;

    return Container(
      padding: EdgeInsets.fromLTRB(16, 12, 16, 12 + bottomInset),
      decoration: BoxDecoration(
        color: AppColors.surfaceWhite,
        boxShadow: [
          BoxShadow(
            blurRadius: 12,
            offset: const Offset(0, -2),
            color: Colors.black.withValues(alpha: 0.06),
          ),
        ],
      ),
      child: _StartSessionButton(
        isAvailable: _isAvailable,
        isBusy: _isBusy,
        ratePerMinute: _chatRatePerMinute,
        // Reply mode: when the most recent message is a free
        // priest message, the button copy reads "Reply · Start
        // Session" so the user understands their next tap will
        // (a) start a paid session, and (b) is in response to the
        // priest's message above.
        isReplyMode: _latestMessage?.isPriestMessage == true,
        // Available speakers go straight into the request flow —
        // no profile detour. Busy / offline still routes to the
        // profile so the user can see the rate or pick a different
        // speaker; we'll add waitlist + notify-me there in v1.1.
        onTap: _isAvailable ? _startChatSession : _openProfile,
      ),
    );
  }
}

// ─── Session divider ────────────────────────────────────────

class _SessionDivider extends StatelessWidget {
  final DateTime date;
  const _SessionDivider({required this.date});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Row(
        children: [
          Expanded(
            child: Container(
              height: 0.5,
              color: AppColors.muted.withValues(alpha: 0.15),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(
              'Session · ${_formatDate(date)}',
              style: GoogleFonts.inter(
                fontSize: 11,
                fontWeight: FontWeight.w500,
                letterSpacing: 0.3,
                color: AppColors.muted.withValues(alpha: 0.7),
              ),
            ),
          ),
          Expanded(
            child: Container(
              height: 0.5,
              color: AppColors.muted.withValues(alpha: 0.15),
            ),
          ),
        ],
      ),
    );
  }

  String _formatDate(DateTime date) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final that = DateTime(date.year, date.month, date.day);
    final diff = today.difference(that).inDays;
    if (diff == 0) return 'Today';
    if (diff == 1) return 'Yesterday';
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    return '${months[date.month - 1]} ${date.day}';
  }
}

// ─── Message bubble ─────────────────────────────────────────

class _MessageBubble extends StatelessWidget {
  final ChatMessage message;
  final bool isMine;
  // Non-null only for priest free messages — long-press fires it,
  // session bubbles are inert here (the chat-history page is read-
  // only). Driving the long-press from a callback instead of a
  // hard-coded "if priestMessage" branch keeps the bubble dumb.
  final VoidCallback? onReport;

  const _MessageBubble({
    required this.message,
    required this.isMine,
    this.onReport,
  });

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
          // Subtle "Free message" tag above the bubble. Same visual
          // treatment used in the live chat surface so the surface
          // changes don't require relearning.
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
                  Icon(
                    Icons.auto_awesome_rounded,
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
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onLongPress: onReport,
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
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// Bottom-sheet shown before filing a report. We deliberately make
// the user confirm — accidental long-press → silent report is the
// kind of UX papercut that floods the admin queue with noise.
class _ReportConfirmSheet extends StatelessWidget {
  final String priestName;
  final String messageText;
  final VoidCallback onConfirm;
  final VoidCallback onCancel;

  const _ReportConfirmSheet({
    required this.priestName,
    required this.messageText,
    required this.onConfirm,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
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
            Center(
              child: Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.errorRed.withValues(alpha: 0.08),
                ),
                child: Icon(
                  Icons.flag_outlined,
                  size: 26,
                  color: AppColors.errorRed,
                ),
              ),
            ),
            const SizedBox(height: 18),
            Text(
              'Report this message?',
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: AppColors.deepDarkBrown,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Our team will review the message from $priestName. '
              "If it violates our guidelines we'll take action.",
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(
                fontSize: 13,
                fontWeight: FontWeight.w400,
                height: 1.5,
                color: AppColors.muted,
              ),
            ),
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.background,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: AppColors.muted.withValues(alpha: 0.1),
                ),
              ),
              child: Text(
                messageText,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.inter(
                  fontSize: 13,
                  fontWeight: FontWeight.w400,
                  height: 1.45,
                  color: AppColors.deepDarkBrown,
                ),
              ),
            ),
            const SizedBox(height: 22),
            Row(
              children: [
                Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: onCancel,
                    child: Container(
                      height: 48,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: AppColors.muted.withValues(alpha: 0.25),
                        ),
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        'Cancel',
                        style: GoogleFonts.inter(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: AppColors.muted,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: onConfirm,
                    child: Container(
                      height: 48,
                      decoration: BoxDecoration(
                        color: AppColors.errorRed,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        'Report',
                        style: GoogleFonts.inter(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                        ),
                      ),
                    ),
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

// ─── Sticky bottom CTA button ───────────────────────────────

class _StartSessionButton extends StatefulWidget {
  final bool isAvailable;
  final bool isBusy;
  final int ratePerMinute;
  // True when the most recent message is a free priest message —
  // flips the available-state copy from "Start New Session" to
  // "Reply · Start Session" so the user reads the tap as a reply
  // to the message they just saw, not a fresh action.
  final bool isReplyMode;
  final VoidCallback onTap;

  const _StartSessionButton({
    required this.isAvailable,
    required this.isBusy,
    required this.ratePerMinute,
    required this.isReplyMode,
    required this.onTap,
  });

  @override
  State<_StartSessionButton> createState() => _StartSessionButtonState();
}

class _StartSessionButtonState extends State<_StartSessionButton> {
  double _scale = 1.0;

  @override
  Widget build(BuildContext context) {
    // Three states drive the label + color:
    //   • Available  → solid brown CTA inviting the new session
    //   • Busy       → softened brown explaining why action is muted
    //   • Offline    → muted "Notify me" copy that still routes to
    //                  the profile so the user can decide
    String label;
    IconData icon;
    Color bgColor;
    Color fgColor;

    if (widget.isAvailable) {
      label = widget.isReplyMode
          ? 'Reply · Start Session · ${widget.ratePerMinute} coins/min'
          : 'Start New Session · ${widget.ratePerMinute} coins/min';
      icon = widget.isReplyMode
          ? Icons.reply_rounded
          : Icons.chat_bubble_outline_rounded;
      bgColor = AppColors.primaryBrown;
      fgColor = Colors.white;
    } else if (widget.isBusy) {
      // Tap routes to the priest's profile — keep the copy aligned
      // with what actually happens. We don't have a notify-me
      // backend yet, so don't promise one.
      label = 'Speaker is busy · View Profile';
      icon = Icons.access_time_rounded;
      bgColor = AppColors.amberGold;
      fgColor = Colors.white;
    } else {
      // Same — opens the profile rather than scheduling a ping.
      // Bell icon dropped because it implied a notification we
      // never set up. Person icon matches "View Profile" honestly.
      label = 'Speaker is offline · View Profile';
      icon = Icons.person_outline_rounded;
      bgColor = AppColors.muted.withValues(alpha: 0.18);
      fgColor = AppColors.deepDarkBrown.withValues(alpha: 0.7);
    }

    return Listener(
      onPointerDown: (_) => setState(() => _scale = 0.98),
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
            width: double.infinity,
            height: 52,
            decoration: BoxDecoration(
              color: bgColor,
              borderRadius: BorderRadius.circular(14),
              boxShadow: widget.isAvailable
                  ? [
                      BoxShadow(
                        blurRadius: 12,
                        offset: const Offset(0, 4),
                        color: AppColors.primaryBrown.withValues(alpha: 0.2),
                      ),
                    ]
                  : null,
            ),
            alignment: Alignment.center,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 16, color: fgColor),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.inter(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: fgColor,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
