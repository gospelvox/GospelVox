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
import 'package:gospel_vox/core/utils/date_format.dart' as df;
import 'package:gospel_vox/core/widgets/app_back_button.dart';
import 'package:gospel_vox/core/widgets/app_snackbar.dart';
import 'package:gospel_vox/features/shared/data/session_model.dart';
import 'package:gospel_vox/features/shared/data/session_preflight.dart';
import 'package:gospel_vox/features/shared/data/session_repository.dart';
import 'package:gospel_vox/core/widgets/app_icons.dart';
import 'package:gospel_vox/core/widgets/app_loading_widget.dart';
import 'package:gospel_vox/features/shared/widgets/chat_session_view.dart'
    show CallEntryBubble;

// Online status — the canonical app-wide "available now" green
// (was a drifted local #059669 that disagreed with the rest of the app).
const Color _kOnlineGreen = AppColors.sageOnline;
// Plum accent for the "In Bible Session" status pill — mirrors the
// hue used on PriestCard and the priest profile page so the same
// state reads the same way everywhere a priest is shown.
const Color _kBibleAccent = AppColors.bibleBusy;
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

// Inline row for a past voice call between this user and the
// priest. Synthesized server-side in getPastChatMessages from
// completed voice sessions (no Firestore messages exist for them);
// the row carries the same ChatMessage carrier as a text bubble so
// the merge logic above doesn't need to learn a new shape.
class _CallEntry extends _Item {
  final ChatMessage message;
  final bool isMine;
  const _CallEntry({required this.message, required this.isMine});
}

class _ChatHistoryPageState extends State<ChatHistoryPage> {
  // Drives the message list. We jump to maxScrollExtent the first
  // time the list paints with content so the user lands on the
  // latest bubble (chat convention), and only auto-follow on later
  // free-message arrivals if they were already near the bottom —
  // otherwise we'd yank them out of older content they're reading.
  final ScrollController _scrollController = ScrollController();
  bool _hasJumpedToBottom = false;

  bool _isLoading = true;
  bool _isOnline = false;
  bool _isBusy = false;
  // Mirrors the SpeakerModel.isInBibleSession lock — flipped true
  // when the priest doc has a non-empty liveBibleSessionId whose
  // deadline (bibleSessionLockedUntil) is still in the future.
  // Without this guard the "Start session" footer button would
  // render as enabled while the priest is teaching a Bible session;
  // the server CF would still block the call (priest-in-bible-session
  // error), but the misleading UI would frustrate the user with a
  // click-fail loop.
  bool _isInBibleSession = false;
  // True when the priest behind this thread has deleted their account.
  // Reachable only via the notifications inbox now that the Sessions
  // tab makes deleted rows inert; when set, the header hides the
  // priest's identity ("Unavailable", no photo, not tappable) and the
  // sticky "Start session" CTA is removed — there's nobody to call.
  bool _isDeleted = false;
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
    _scrollController.dispose();
    super.dispose();
  }

  // True when the user is within 100px of the bottom — the same
  // threshold the live chat view uses. We treat "no clients yet"
  // as at-bottom so the first paint follows new content instead
  // of stranding the user mid-list.
  bool _isNearBottom() {
    if (!_scrollController.hasClients) return true;
    final pos = _scrollController.position;
    return pos.maxScrollExtent - pos.pixels <= 100;
  }

  // First successful paint with content: jump straight to the
  // bottom (no animation — animating from offset 0 would flash
  // the oldest bubble through the viewport). Subsequent rebuilds
  // (free-message arrivals, mute toggles) only follow if the user
  // was already at the bottom, otherwise they stay where they
  // were reading.
  void _scheduleScrollAfterRebuild() {
    if (_items.isEmpty) return;
    final wasNearBottom = _isNearBottom();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!_scrollController.hasClients) return;
      if (!_hasJumpedToBottom) {
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
        _hasJumpedToBottom = true;
        return;
      }
      if (wasNearBottom) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOutCubic,
        );
      }
    });
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

      final isDeleted = (priestData?['isDeleted'] as bool?) ?? false;
      // A deleted priest is forced offline so every availability-gated
      // affordance (status pill, CTA) reads as unavailable.
      final isOnline =
          isDeleted ? false : ((priestData?['isOnline'] as bool?) ?? false);
      final isBusy =
          isDeleted ? false : ((priestData?['isBusy'] as bool?) ?? false);
      // Two-signal in-bible-session check, mirrors SpeakerModel's
      // isInBibleSession getter. The lock is considered held only
      // when liveBibleSessionId is non-empty AND
      // bibleSessionLockedUntil is either missing OR still in the
      // future. The deadline guard is what makes the lock
      // self-healing: even if every server-side clear path fails,
      // once the timestamp passes the priest is treated as released.
      final liveBibleSessionId =
          (priestData?['liveBibleSessionId'] as String?) ?? '';
      final lockedUntilTs = priestData?['bibleSessionLockedUntil'];
      final lockedUntil = lockedUntilTs is Timestamp
          ? lockedUntilTs.toDate()
          : null;
      final isInBibleSession = liveBibleSessionId.isNotEmpty &&
          (lockedUntil == null || DateTime.now().isBefore(lockedUntil));
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
        _isDeleted = isDeleted;
        _isOnline = isOnline;
        _isBusy = isBusy;
        _isInBibleSession = isInBibleSession;
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
      // Past-session chat bubbles inject a session divider on every
      // sessionId boundary. Free messages and call-entry rows have
      // no chat-session divider — they flow inline at their
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
      // Call entries get their own row type so the builder can
      // render them with the inline phone-card look + redial tap.
      if (m.isCallEntry) {
        items.add(_CallEntry(message: m, isMine: m.senderId == uid));
      } else {
        items.add(_Bubble(message: m, isMine: m.senderId == uid));
      }
    }

    if (!mounted) return;
    setState(() {
      _items = items;
      _latestMessage = timeline.isNotEmpty ? timeline.last : null;
    });
    _scheduleScrollAfterRebuild();
  }

  // "Truly available" — online, not paused/in-chat, and not
  // teaching a Bible session. Mirrors SpeakerModel.isAvailable
  // so the gate matches every other surface in the app.
  bool get _isAvailable => _isOnline && !_isBusy && !_isInBibleSession;

  // Precedence order matches the priest card / profile pill:
  // in-bible-session wins over busy wins over offline. This ensures
  // a priest who's also technically isBusy=true (back-to-back chat
  // + bible) shows the more accurate "In Bible Session" label.
  String get _statusLabel {
    if (_isInBibleSession) return 'In Bible Session';
    if (_isAvailable) return 'Online';
    if (_isBusy) return 'Busy';
    return 'Offline';
  }

  Color get _statusColor {
    if (_isInBibleSession) return _kBibleAccent;
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

  // Tap-to-redial off a past voice-call entry in the timeline.
  // Mirrors _startChatSession's preflight-then-waiting-page flow,
  // just with type='voice'. The waiting page handles everything
  // server-side (insufficient-balance, priest-offline, busy,
  // accepted, expired) so this surface stays thin.
  Future<void> _redialVoice() async {
    final canStart = await SessionPreflight.check(
      context,
      type: 'voice',
      priestName: _displayPriestName,
    );
    if (!canStart || !mounted) return;
    context.push('/session/waiting', extra: <String, dynamic>{
      'priestId': widget.priestId,
      'priestName': _displayPriestName,
      'priestPhotoUrl': _displayPriestPhotoUrl,
      'priestDenomination': '',
      'type': 'voice',
    });
  }

  // Tapping the priest's avatar/name in the app bar still opens the
  // full profile — the profile becomes optional, accessed by intent
  // rather than forced into every flow.
  void _openProfile() {
    // No profile to open for a deleted priest — the user-side detail
    // route resolves them as not-found, so we keep the tap inert.
    if (_isDeleted) return;
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
                width: 38,
                height: 38,
                child: AppLoader(),
              ),
            )
          : Column(
              children: [
                Expanded(
                  child: _items.isEmpty ? _buildEmpty() : _buildList(),
                ),
                // No "Start session" CTA for a deleted priest — there's
                // no one on the other side to reach.
                if (!_isDeleted) _buildStickyCTA(),
              ],
            ),
    );
  }

  // ─── App bar ────────────────────────────────────────────

  // Effective name + photo, preferring the route extras and falling
  // back to whatever we resolved from priests/{id}. The AppBar reads
  // these so a push-notification deep link (which can't carry extras)
  // still renders a populated header within ~300ms of opening.
  // A deleted priest's identity is suppressed everywhere the header
  // reads it — the route extras (carried from a notification) would
  // otherwise still show their old name/photo.
  String get _displayPriestName => _isDeleted
      ? 'Unavailable'
      : (widget.priestName.isNotEmpty
          ? widget.priestName
          : (_fallbackPriestName ?? ''));
  String get _displayPriestPhotoUrl => _isDeleted
      ? ''
      : (widget.priestPhotoUrl.isNotEmpty
          ? widget.priestPhotoUrl
          : (_fallbackPriestPhotoUrl ?? ''));

  PreferredSizeWidget _buildAppBar() {
    final name = _displayPriestName;
    final photo = _displayPriestPhotoUrl;
    // Neutral glyph for a deleted priest — never the "U" of
    // "Unavailable".
    final initial =
        _isDeleted ? '?' : (name.isNotEmpty ? name[0].toUpperCase() : '?');

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
                color: AppColors.fieldFill,
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
          icon: AppIcon(
            AppIcons.more,
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
                  AppIcon(
                    _isMuted
                        ? AppIcons.bell
                        : AppIcons.bellOff,
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
                  AppIcon(
                    AppIcons.userOutline,
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
        controller: _scrollController,
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
          if (item is _CallEntry) {
            return CallEntryBubble(
              message: item.message,
              isMe: item.isMine,
              onTap: () => _redialVoice(),
            );
          }
          if (item is _Bubble) {
            return _MessageBubble(
              message: item.message,
              isMine: item.isMine,
            );
          }
          return const SizedBox.shrink();
        },
      ),
    );
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
              child: AppIcon(
                AppIcons.chatOutline,
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
        isInBibleSession: _isInBibleSession,
        ratePerMinute: _chatRatePerMinute,
        // Reply mode: when the most recent message is a free
        // priest message, the button copy reads "Reply · Start
        // Session" so the user understands their next tap will
        // (a) start a paid session, and (b) is in response to the
        // priest's message above.
        isReplyMode: _latestMessage?.isPriestMessage == true,
        // Available speakers go straight into the request flow —
        // no profile detour. Busy / offline / in-bible still
        // routes to the profile so the user can see the rate or
        // pick a different speaker.
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

  String _formatDate(DateTime date) => df.formatDayCompact(date);
}

// ─── Message bubble ─────────────────────────────────────────

class _MessageBubble extends StatelessWidget {
  final ChatMessage message;
  final bool isMine;

  const _MessageBubble({
    required this.message,
    required this.isMine,
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

// ─── Sticky bottom CTA button ───────────────────────────────

class _StartSessionButton extends StatefulWidget {
  final bool isAvailable;
  final bool isBusy;
  // Distinct flag (not just "another kind of busy") so the button
  // can show plum-accented "In Bible Session · View Profile" copy
  // instead of the misleading amber "Speaker is busy" or muted
  // "Speaker is offline" labels.
  final bool isInBibleSession;
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
    required this.isInBibleSession,
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
    // Four states drive the label + color:
    //   • Available        → solid brown CTA inviting the new session
    //   • In Bible Session → plum "View Profile" — strongest do-not-
    //                        disturb signal, checked first because
    //                        the priest could also be technically
    //                        isBusy=true in a chat at the same time
    //   • Busy             → amber "Speaker is busy"
    //   • Offline          → muted "Speaker is offline"
    String label;
    IconData icon;
    Color bgColor;
    Color fgColor;

    if (widget.isAvailable) {
      label = widget.isReplyMode
          ? 'Reply · Start Session · ${widget.ratePerMinute} coins/min'
          : 'Start New Session · ${widget.ratePerMinute} coins/min';
      icon = widget.isReplyMode
          ? AppIcons.reply
          : AppIcons.chatOutline;
      bgColor = AppColors.primaryBrown;
      fgColor = Colors.white;
    } else if (widget.isInBibleSession) {
      // Plum-tinted CTA: speaker is in a live Bible session and
      // must not be disturbed. Tap routes to the profile (same as
      // the other unavailable branches) so the user can read the
      // in-bible reason banner with the full context.
      label = 'In Bible Session · View Profile';
      icon = AppIcons.bible;
      bgColor = _kBibleAccent;
      fgColor = Colors.white;
    } else if (widget.isBusy) {
      // Tap routes to the priest's profile — keep the copy aligned
      // with what actually happens. We don't have a notify-me
      // backend yet, so don't promise one.
      label = 'Speaker is busy · View Profile';
      icon = AppIcons.clock;
      bgColor = AppColors.amberGold;
      fgColor = Colors.white;
    } else {
      // Same — opens the profile rather than scheduling a ping.
      // Bell icon dropped because it implied a notification we
      // never set up. Person icon matches "View Profile" honestly.
      label = 'Speaker is offline · View Profile';
      icon = AppIcons.userOutline;
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
                AppIcon(icon, size: 16, color: fgColor),
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
