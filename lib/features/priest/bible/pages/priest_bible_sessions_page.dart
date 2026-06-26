// Priest-side list of their own Bible sessions, grouped into LIVE /
// UPCOMING / PAST sections, plus the create-session flow that opens
// a form sheet and then a review sheet before actually publishing.
//
// Owns its own load lifecycle (no cubit) — the data shape is priest-
// scoped and different from the user-side BibleSessionCubit, so the
// small duplication earns simpler code.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shimmer/shimmer.dart';

import 'package:gospel_vox/core/config/iap_products.dart';
import 'package:gospel_vox/core/theme/app_colors.dart';
import 'package:gospel_vox/core/widgets/app_back_button.dart';
import 'package:gospel_vox/core/widgets/app_snackbar.dart';
import 'package:gospel_vox/core/widgets/pulsing_dot.dart';
import 'package:gospel_vox/features/priest/widgets/activation_prompt_sheet.dart';
import 'package:gospel_vox/features/shared/data/bible_session_model.dart';
import 'package:gospel_vox/features/shared/data/bible_session_repository.dart';
import 'package:gospel_vox/core/widgets/app_icons.dart';
import 'package:gospel_vox/core/widgets/app_loading_widget.dart';

// Forest green for "completed" status pills — AppColors has no
// proper "success-green" token, so we use the same value the rest
// of the priest UI does (matches AppSnackBar's success colour).
const Color _kCompletedGreen = AppColors.successGreen;
// Live red — distinct from errorRed so a pulsing live badge reads as
// urgency-of-attention rather than failure.
const Color _kLiveRed = AppColors.liveRed;

class PriestBibleSessionsPage extends StatefulWidget {
  const PriestBibleSessionsPage({super.key});

  @override
  State<PriestBibleSessionsPage> createState() =>
      _PriestBibleSessionsPageState();
}

class _PriestBibleSessionsPageState extends State<PriestBibleSessionsPage> {
  final BibleSessionRepository _repository = BibleSessionRepository();

  List<BibleSessionModel> _live = const [];
  List<BibleSessionModel> _upcoming = const [];
  List<BibleSessionModel> _past = const [];

  bool _isLoading = true;
  // Read once on load so the "+" tap can gate before the priest fills
  // out a long form. Stays as a bool (not a stream) because activation
  // flips at most once during a session and a stale negative re-prompts
  // harmlessly — the paywall is idempotent.
  bool _isActivated = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _error = "You're signed out.";
      });
      return;
    }

    try {
      // Two parallel reads: the session list AND the priest's own
      // doc for the activation flag. We swallow priest-doc errors —
      // if the read fails, default to !activated and let the paywall
      // sheet surface the right message instead of letting the form
      // open and fail at submit.
      final results = await Future.wait([
        _repository.getPriestSessions(uid),
        FirebaseFirestore.instance
            .doc('priests/$uid')
            .get()
            .timeout(const Duration(seconds: 8)),
      ]);
      if (!mounted) return;
      final list = results[0] as List<BibleSessionModel>;
      final priestDoc =
          results[1] as DocumentSnapshot<Map<String, dynamic>>;

      // Bucket the priest's sessions into three groups. Splitting in
      // the load step keeps the build path cheap — no per-frame
      // filtering or sorting.
      //
      // isEffectivelyLive / isEffectivelyCompleted instead of the raw
      // status flags — a session past its (startedAt + duration + 15min)
      // deadline is treated as completed for bucketing even if the
      // auto-complete cron hasn't flipped the doc yet. Without this
      // the priest's "Live" tab keeps shouting LIVE for a session
      // they finished an hour ago until the next 5-min cron tick
      // catches up.
      final live = <BibleSessionModel>[];
      final upcoming = <BibleSessionModel>[];
      final past = <BibleSessionModel>[];
      for (final s in list) {
        if (s.isEffectivelyLive) {
          live.add(s);
        } else if (s.isExpiredUpcoming) {
          // Scheduled slot came and went but the priest never tapped
          // "Start Meeting" — it's dead. Show it in PAST instead of
          // pinning a past-dated session at the top of Upcoming. The
          // priest can still open it to cancel/clean it up.
          past.add(s);
        } else if (s.isUpcoming) {
          upcoming.add(s);
        } else {
          // Captures completed, cancelled, AND stale-live (past-
          // deadline) sessions. The cron will flip the latter to
          // completed soon; until then the priest sees them in
          // Past where they belong.
          past.add(s);
        }
      }
      // Upcoming: soonest first (ascending scheduledAt) so the next
      // event is at the top.
      upcoming.sort((a, b) {
        final aT = a.scheduledAt ?? DateTime(2099);
        final bT = b.scheduledAt ?? DateTime(2099);
        return aT.compareTo(bT);
      });
      // Past: most recent first.
      past.sort((a, b) {
        final aT = a.completedAt ??
            a.cancelledAt ??
            a.scheduledAt ??
            DateTime(2000);
        final bT = b.completedAt ??
            b.cancelledAt ??
            b.scheduledAt ??
            DateTime(2000);
        return bT.compareTo(aT);
      });

      setState(() {
        _live = live;
        _upcoming = upcoming;
        _past = past;
        _isActivated =
            (priestDoc.data()?['isActivated'] as bool?) ?? false;
        _isLoading = false;
        _error = null;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _error = "Couldn't load sessions. Pull to retry.";
      });
    }
  }

  Future<void> _showCreateSheet() async {
    // Activation gate. An unactivated priest cannot publish a Bible
    // session (Firestore rules deny the write), so we surface the
    // paywall sheet at the "+" tap instead of letting them fill the
    // entire form and fail at submit.
    if (!_isActivated) {
      await ActivationPromptSheet.show(context);
      return;
    }

    final created = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const _CreateBibleSessionSheet(),
    );
    if (!mounted) return;
    if (created == true) await _load();
  }

  bool get _hasAny =>
      _live.isNotEmpty || _upcoming.isNotEmpty || _past.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        foregroundColor: AppColors.deepDarkBrown,
        leadingWidth: 64,
        leading: const Padding(
          padding: EdgeInsets.only(left: 16),
          child: AppBackButton(),
        ),
        title: Text(
          "Bible Sessions",
          style: GoogleFonts.inter(
            fontSize: 18,
            fontWeight: FontWeight.w700,
            color: AppColors.deepDarkBrown,
          ),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: _CreatePillButton(onTap: _showCreateSheet),
          ),
        ],
      ),
      body: RefreshIndicator(
        color: AppColors.primaryBrown,
        backgroundColor: AppColors.surfaceWhite,
        onRefresh: _load,
        child: _buildBody(),
      ),
    );
  }

  Widget _buildBody() {
    if (_isLoading) return _buildLoading();
    if (_error != null) return _buildError(_error!);
    if (!_hasAny) return _buildEmpty();
    return _buildList();
  }

  Widget _buildLoading() {
    final base = AppColors.muted.withValues(alpha: 0.14);
    final highlight = AppColors.warmBeige;
    return ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(
        parent: BouncingScrollPhysics(),
      ),
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 100),
      itemCount: 3,
      itemBuilder: (_, _) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Shimmer.fromColors(
          baseColor: base,
          highlightColor: highlight,
          child: Container(
            height: 130,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(14),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildError(String message) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(
        parent: BouncingScrollPhysics(),
      ),
      padding: const EdgeInsets.fromLTRB(32, 80, 32, 32),
      children: [
        AppIcon(
          AppIcons.error,
          size: 44,
          color: AppColors.errorRed,
        ),
        const SizedBox(height: 14),
        Text(
          message,
          textAlign: TextAlign.center,
          style: GoogleFonts.inter(
            fontSize: 14,
            fontWeight: FontWeight.w500,
            color: AppColors.muted,
          ),
        ),
      ],
    );
  }

  Widget _buildEmpty() {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(
        parent: BouncingScrollPhysics(),
      ),
      children: [
        SizedBox(height: MediaQuery.of(context).size.height * 0.18),
        Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 40),
            child: Column(
              children: [
                AppIcon(
                  AppIcons.bible,
                  size: 56,
                  color: AppColors.muted.withValues(alpha: 0.25),
                ),
                const SizedBox(height: 16),
                Text(
                  "No sessions yet",
                  style: GoogleFonts.inter(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color:
                        AppColors.deepDarkBrown.withValues(alpha: 0.8),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  "Tap + Create to schedule your first Bible session.\n"
                  "Users will see it on their Bible tab.",
                  textAlign: TextAlign.center,
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    fontWeight: FontWeight.w400,
                    color: AppColors.muted,
                    height: 1.5,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildList() {
    final children = <Widget>[];

    void appendSection(String label, List<BibleSessionModel> items,
        {bool live = false}) {
      if (items.isEmpty) return;
      children.add(_SectionHeader(label: label, live: live));
      for (final s in items) {
        children.add(_PriestSessionCard(
          session: s,
          onTap: () async {
            final changed =
                await context.push<bool>('/priest/bible/${s.id}');
            if (!mounted) return;
            if (changed == true) await _load();
          },
        ));
      }
      children.add(const SizedBox(height: 18));
    }

    appendSection("LIVE NOW", _live, live: true);
    appendSection("UPCOMING", _upcoming);
    appendSection("PAST", _past);

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(
        parent: BouncingScrollPhysics(),
      ),
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 100),
      children: children,
    );
  }
}

// ─── Section header ────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  final String label;
  final bool live;
  const _SectionHeader({required this.label, this.live = false});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 8, 2, 10),
      child: Row(
        children: [
          if (live) ...[
            const PulsingDot(size: 8, color: _kLiveRed),
            const SizedBox(width: 8),
          ],
          Text(
            label,
            style: GoogleFonts.inter(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: live
                  ? _kLiveRed
                  : AppColors.muted.withValues(alpha: 0.9),
              letterSpacing: 0.8,
            ),
          ),
        ],
      ),
    );
  }
}

// ─── "+ Create" pill button ────────────────────────────────────

class _CreatePillButton extends StatefulWidget {
  final VoidCallback onTap;
  const _CreatePillButton({required this.onTap});

  @override
  State<_CreatePillButton> createState() => _CreatePillButtonState();
}

class _CreatePillButtonState extends State<_CreatePillButton> {
  double _scale = 1.0;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _scale = 0.92),
      onTapUp: (_) => setState(() => _scale = 1.0),
      onTapCancel: () => setState(() => _scale = 1.0),
      onTap: widget.onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedScale(
        scale: _scale,
        duration: const Duration(milliseconds: 100),
        child: Container(
          padding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: AppColors.amberGold,
            borderRadius: BorderRadius.circular(22),
            boxShadow: [
              BoxShadow(
                color: AppColors.amberGold.withValues(alpha: 0.35),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const AppIcon(AppIcons.add, size: 16, color: Colors.white),
              const SizedBox(width: 4),
              Text(
                "Create",
                style: GoogleFonts.inter(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Priest session card ────────────────────────────────────────

class _PriestSessionCard extends StatefulWidget {
  final BibleSessionModel session;
  final VoidCallback onTap;

  const _PriestSessionCard({
    required this.session,
    required this.onTap,
  });

  @override
  State<_PriestSessionCard> createState() => _PriestSessionCardState();
}

class _PriestSessionCardState extends State<_PriestSessionCard> {
  double _scale = 1.0;

  @override
  Widget build(BuildContext context) {
    final session = widget.session;

    return GestureDetector(
      onTapDown: (_) => setState(() => _scale = 0.98),
      onTapUp: (_) => setState(() => _scale = 1.0),
      onTapCancel: () => setState(() => _scale = 1.0),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _scale,
        duration: const Duration(milliseconds: 100),
        child: Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppColors.surfaceWhite,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: session.isEffectivelyLive
                  ? _kLiveRed.withValues(alpha: 0.35)
                  : AppColors.muted.withValues(alpha: 0.06),
              width: session.isEffectivelyLive ? 1.4 : 1.0,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.03),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      session.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.inter(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: AppColors.deepDarkBrown,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _metaLine(session),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.inter(
                        fontSize: 12,
                        fontWeight: FontWeight.w400,
                        color: AppColors.muted,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      "${session.registrationCount} registered · ₹${session.price}",
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
              _StatusPill(session: session),
            ],
          ),
        ),
      ),
    );
  }

  String _metaLine(BibleSessionModel s) {
    final parts = <String>[];
    if (s.category.isNotEmpty) parts.add(s.category);
    if (s.scheduledAt != null) {
      parts.add(_formatShortDate(s.scheduledAt!));
      parts.add(s.formattedTime);
    }
    return parts.join(' · ');
  }
}

class _StatusPill extends StatelessWidget {
  final BibleSessionModel session;
  const _StatusPill({required this.session});

  @override
  Widget build(BuildContext context) {
    // isEffectivelyLive — a status='live' doc that's past its deadline
    // should not pulse a LIVE pill at the priest. We render it as
    // Completed (the cron will flip the doc on its next tick).
    if (session.isEffectivelyLive) {
      return _Pill(
        bg: _kLiveRed.withValues(alpha: 0.12),
        fg: _kLiveRed,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const PulsingDot(size: 6, color: _kLiveRed),
            const SizedBox(width: 5),
            Text(
              "LIVE",
              style: GoogleFonts.inter(
                fontSize: 10,
                fontWeight: FontWeight.w700,
                color: _kLiveRed,
                letterSpacing: 0.6,
              ),
            ),
          ],
        ),
      );
    }
    // Expired-upcoming (never started, slot passed) is checked BEFORE
    // the plain Upcoming branch because it's still status='upcoming'.
    // It lives in the PAST section, so it needs an honest terminal-ish
    // pill rather than the amber "Upcoming".
    if (session.isExpiredUpcoming) {
      return _Pill(
        bg: AppColors.muted.withValues(alpha: 0.12),
        fg: AppColors.muted,
        child: Text(
          "Not Started",
          style: GoogleFonts.inter(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: AppColors.muted,
          ),
        ),
      );
    }
    if (session.isUpcoming) {
      return _Pill(
        bg: AppColors.amberGold.withValues(alpha: 0.14),
        fg: AppColors.amberGold,
        child: Text(
          "Upcoming",
          style: GoogleFonts.inter(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: AppColors.amberGold,
          ),
        ),
      );
    }
    // isEffectivelyCompleted covers both real 'completed' docs AND
    // a stale 'live' doc that's past its deadline waiting on the
    // cron flip. Without this branch a past-deadline live session
    // would fall through to the Cancelled pill below, which is a
    // worse lie than waiting one cron tick for the real flip.
    if (session.isEffectivelyCompleted) {
      return _Pill(
        bg: _kCompletedGreen.withValues(alpha: 0.1),
        fg: _kCompletedGreen,
        child: Text(
          "Completed",
          style: GoogleFonts.inter(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: _kCompletedGreen,
          ),
        ),
      );
    }
    // Cancelled
    return _Pill(
      bg: AppColors.muted.withValues(alpha: 0.12),
      fg: AppColors.muted,
      child: Text(
        "Cancelled",
        style: GoogleFonts.inter(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: AppColors.muted,
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  final Color bg;
  // ignore: unused_element_parameter
  final Color fg;
  final Widget child;
  const _Pill({required this.bg, required this.fg, required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding:
          const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(7),
      ),
      child: child,
    );
  }
}

// ════════════════════════════════════════════════════════════════
// CREATE BIBLE SESSION BOTTOM SHEET
// ════════════════════════════════════════════════════════════════

class _CreateBibleSessionSheet extends StatefulWidget {
  const _CreateBibleSessionSheet();

  @override
  State<_CreateBibleSessionSheet> createState() =>
      _CreateBibleSessionSheetState();
}

class _CreateBibleSessionSheetState
    extends State<_CreateBibleSessionSheet> {
  final BibleSessionRepository _repository = BibleSessionRepository();
  final _titleCtrl = TextEditingController();
  final _descCtrl = TextEditingController();
  final _maxCtrl = TextEditingController();
  final _linkCtrl = TextEditingController();

  static const _categories = [
    "Deep Study",
    "Daily Living",
    "Youth",
    "Prayer",
    "Practical Guide",
    "Worship",
    "Testimony",
  ];
  // Curated set rather than a free-form input — keeps every session
  // in a predictable bucket (avoids 7-min curiosities) and lets the
  // user-side card show a tidy "1 hour" instead of arbitrary numbers.
  static const _durationOptions = [30, 45, 60, 90, 120];

  String? _category;
  DateTime? _date;
  TimeOfDay? _time;
  int _durationMinutes = 60;
  bool _creating = false;
  String? _formError;

  @override
  void dispose() {
    _titleCtrl.dispose();
    _descCtrl.dispose();
    _maxCtrl.dispose();
    _linkCtrl.dispose();
    super.dispose();
  }

  // The single source of truth for "can we publish?". Used by the
  // button's enabled state. The actual user-facing breakdown of what
  // is missing lives in `_missingFields` so the two never drift.
  bool get _isValid {
    if (_titleCtrl.text.trim().length < 5) return false;
    if (_descCtrl.text.trim().length < 20) return false;
    if (_category == null) return false;
    if (_date == null || _time == null) return false;
    // Price is no longer priest-controlled — every session is the
    // fixed IapProducts.bibleSessionPriceRupees value. The CF
    // re-validates server-side so a tampered client can't slip an
    // arbitrary price past us.
    return true;
  }

  List<String> get _missingFields {
    final issues = <String>[];

    final titleLen = _titleCtrl.text.trim().length;
    if (titleLen < 5) {
      final need = 5 - titleLen;
      issues.add(titleLen == 0
          ? 'Title'
          : 'Title — $need more character${need == 1 ? '' : 's'}');
    }

    final descLen = _descCtrl.text.trim().length;
    if (descLen < 20) {
      final need = 20 - descLen;
      issues.add(descLen == 0
          ? 'Description'
          : 'Description — $need more character${need == 1 ? '' : 's'}');
    }

    if (_category == null) issues.add('Category');
    if (_date == null) issues.add('Date');
    if (_time == null) issues.add('Time');

    // Price guard removed — fixed at IapProducts.bibleSessionPriceRupees.

    return issues;
  }

  _HelperMood _moodFor({required int len, required int min}) {
    if (len == 0) return _HelperMood.neutral;
    if (len < min) return _HelperMood.error;
    return _HelperMood.success;
  }

  String _titleHelperText() {
    final len = _titleCtrl.text.trim().length;
    if (len == 0) return 'Min 5 characters · max 100';
    if (len < 5) {
      final need = 5 - len;
      return 'Need $need more character${need == 1 ? '' : 's'} · $len/100';
    }
    return 'Looks good · $len/100';
  }

  String _descHelperText() {
    final len = _descCtrl.text.trim().length;
    if (len == 0) return 'Min 20 characters · max 300';
    if (len < 20) {
      final need = 20 - len;
      return 'Need $need more character${need == 1 ? '' : 's'} · $len/300';
    }
    return 'Looks good · $len/300';
  }

  // Link is optional, so empty is neutral (not an error). We auto-
  // prepend https:// on submit, which lets the priest paste either
  // "meet.google.com/abc-defg-hij" or the full URL — the helper text
  // here makes that behaviour discoverable rather than magic.
  ({String text, _HelperMood mood}) _linkHelper() {
    final raw = _linkCtrl.text.trim();
    if (raw.isEmpty) {
      return (
        text: 'Optional · you can add this later from Manage Session',
        mood: _HelperMood.neutral,
      );
    }
    if (!raw.startsWith('https://') && !raw.startsWith('http://')) {
      return (
        text: "We'll add https:// for you on publish",
        mood: _HelperMood.neutral,
      );
    }
    final uri = Uri.tryParse(raw);
    if (uri == null) {
      return (text: 'This link looks invalid', mood: _HelperMood.error);
    }
    if (uri.scheme != 'https') {
      return (text: 'Must start with https://', mood: _HelperMood.error);
    }
    return (text: 'Looks good', mood: _HelperMood.success);
  }

  String _normalizeLink(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return '';
    if (trimmed.startsWith('https://')) return trimmed;
    if (trimmed.startsWith('http://')) {
      return 'https://${trimmed.substring(7)}';
    }
    return 'https://$trimmed';
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _date ?? now.add(const Duration(days: 7)),
      firstDate: now,
      lastDate: now.add(const Duration(days: 90)),
      builder: (context, child) => Theme(
        data: Theme.of(context).copyWith(
          colorScheme: ColorScheme.light(
            primary: AppColors.primaryBrown,
            onPrimary: Colors.white,
            onSurface: AppColors.deepDarkBrown,
          ),
        ),
        child: child!,
      ),
    );
    if (picked != null && mounted) {
      setState(() => _date = picked);
    }
  }

  Future<void> _pickTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: _time ?? const TimeOfDay(hour: 19, minute: 0),
      builder: (context, child) => Theme(
        data: Theme.of(context).copyWith(
          colorScheme: ColorScheme.light(
            primary: AppColors.primaryBrown,
            onPrimary: Colors.white,
            onSurface: AppColors.deepDarkBrown,
          ),
        ),
        child: child!,
      ),
    );
    if (picked != null && mounted) {
      setState(() => _time = picked);
    }
  }

  Future<void> _showLinkGuide() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const _MeetLinkGuideSheet(),
    );
  }

  // The Review & Publish flow: validate locally, build a snapshot of
  // everything the priest entered, open a modal review sheet, and
  // only call createSession if the priest taps "Confirm & Publish".
  // The review sheet returns true → publish; false (or backdrop) →
  // keep this form open with state intact.
  Future<void> _openReview() async {
    if (!_isValid || _creating) return;

    // Two DateTimes for the same pick — one for showing the priest
    // exactly what they entered, one for storage / validation.
    //
    //   • displayScheduledAt — DateTime(...) honours the device's
    //     local timezone, so .hour/.minute round-trip back to the
    //     picked TimeOfDay regardless of where the priest is.
    //     Passed to _ReviewSheet so the review row shows "8:00 PM"
    //     when the priest picked 8 PM, even on a non-IST device.
    //
    //   • utcScheduledAt — the authoritative instant. The form
    //     labels the time field "TIME (IST)" but DateTime(...) without
    //     .utc would treat the wall-clock pick as device-local, so a
    //     priest in PDT would have their "8 PM IST" stored as 8 PM
    //     PDT (= 14h off). Constructing in UTC from the picked
    //     components and subtracting the IST offset (UTC+5:30) gives
    //     the true UTC instant that "8 PM IST" represents. For an
    //     IST device the two end up identical (toUtc(8 PM IST) ==
    //     UTC(8 PM) - 5:30); for any other device this is what fixes
    //     the timezone drift.
    final displayScheduledAt = DateTime(
      _date!.year,
      _date!.month,
      _date!.day,
      _time!.hour,
      _time!.minute,
    );
    final utcScheduledAt = DateTime.utc(
      _date!.year,
      _date!.month,
      _date!.day,
      _time!.hour,
      _time!.minute,
    ).subtract(const Duration(hours: 5, minutes: 30));

    // Validate against the UTC instant — for a non-IST priest, the
    // local displayScheduledAt could still be "in the future" while
    // the actual IST instant has already passed, and we want the
    // form to surface that mismatch up-front instead of after the
    // priest taps Confirm & Publish and the CF rejects with
    // invalid-argument.
    if (utcScheduledAt.isBefore(DateTime.now())) {
      setState(() => _formError = "Pick a future date and time.");
      return;
    }

    final link = _normalizeLink(_linkCtrl.text);
    if (link.isNotEmpty) {
      final uri = Uri.tryParse(link);
      if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
        setState(() => _formError =
            "That doesn't look like a valid meeting link.");
        return;
      }
    }

    setState(() => _formError = null);

    final maxRaw = _maxCtrl.text.trim();
    final maxAttendees = maxRaw.isEmpty ? 0 : (int.tryParse(maxRaw) ?? 0);
    // Fixed platform-wide Bible price. The createBibleSession CF
    // rejects anything other than this value, so a stale client
    // surfaces as an explicit error rather than silently mispricing.
    const price = IapProducts.bibleSessionPriceRupees;

    // The review sheet runs the create itself (via onConfirm) and only
    // returns true once the session is actually created — keeping its
    // own spinner up the whole time. So there's no "pop back to the
    // form, wait, then go forward" bounce: confirm → spinner → done.
    final published = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      isDismissible: true,
      builder: (_) => _ReviewSheet(
        title: _titleCtrl.text.trim(),
        description: _descCtrl.text.trim(),
        category: _category!,
        scheduledAt: displayScheduledAt,
        durationMinutes: _durationMinutes,
        price: price,
        maxAttendees: maxAttendees,
        meetingLink: link,
        onConfirm: () => _create(
          scheduledAt: utcScheduledAt,
          link: link,
          price: price,
          maxAttendees: maxAttendees,
        ),
      ),
    );
    if (!mounted) return;
    // published == true → session created; close the form and confirm.
    // Anything else (cancelled, or create failed) leaves the form open
    // so the priest can retry or read the error in _formError.
    if (published != true) return;

    Navigator.of(context).pop(true);
    AppSnackBar.success(
      context,
      "Session published — users can register now.",
    );
  }

  // Returns true when the session was created. The caller (the review
  // sheet) keeps its own spinner up while this runs and only closes on
  // true — so the priest never bounces back to the form mid-create. On
  // failure we set _formError and return false; the review sheet then
  // dismisses so the priest sees the error on the form.
  Future<bool> _create({
    required DateTime scheduledAt,
    required String link,
    required int price,
    required int maxAttendees,
  }) async {
    if (_creating) return false;
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      setState(() => _formError = "You're signed out.");
      return false;
    }

    setState(() {
      _creating = true;
      _formError = null;
    });

    try {
      final priestDoc = await FirebaseFirestore.instance
          .doc('priests/${user.uid}')
          .get()
          .timeout(const Duration(seconds: 8));
      if (!mounted) return false;
      final priestData = priestDoc.data() ?? const {};
      final name = (priestData['fullName'] as String?) ??
          user.displayName ??
          'Speaker';
      final photo = (priestData['photoUrl'] as String?) ??
          user.photoURL ??
          '';

      await _repository.createSession(
        priestId: user.uid,
        priestName: name,
        priestPhotoUrl: photo,
        title: _titleCtrl.text.trim(),
        description: _descCtrl.text.trim(),
        category: _category!,
        scheduledAt: scheduledAt,
        durationMinutes: _durationMinutes,
        maxParticipants: maxAttendees,
        price: price,
        meetingLink: link,
      );

      if (!mounted) return false;
      setState(() => _creating = false);
      return true;
    } on FirebaseFunctionsException catch (e) {
      // The CF now owns create — its HttpsError codes map cleanly
      // to user-facing copy. `already-exists` is the overlap case
      // (CF includes the conflicting session's title + time in the
      // message, so we surface that verbatim). `permission-denied`
      // covers not-approved / not-activated. `invalid-argument`
      // covers shape failures the form should have prevented but
      // a race / tampered client slipped through.
      if (!mounted) return false;
      setState(() {
        _creating = false;
        _formError = e.message?.isNotEmpty == true
            ? e.message
            : "Couldn't create session. Please try again.";
      });
      return false;
    } on FirebaseException catch (e) {
      if (!mounted) return false;
      setState(() {
        _creating = false;
        _formError = e.code == 'permission-denied'
            ? "You're not approved to create sessions yet."
            : "Couldn't create session. Please try again.";
      });
      return false;
    } catch (_) {
      if (!mounted) return false;
      setState(() {
        _creating = false;
        _formError = "Couldn't create session. Please try again.";
      });
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Container(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.92,
        ),
        decoration: const BoxDecoration(
          color: AppColors.surfaceWhite,
          borderRadius:
              BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
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
              const SizedBox(height: 16),
              Center(
                child: Text(
                  "New Bible Session",
                  style: GoogleFonts.inter(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    color: AppColors.deepDarkBrown,
                  ),
                ),
              ),
              const SizedBox(height: 20),

              // Title
              const _FormLabel("SESSION TITLE", required: true),
              const SizedBox(height: 8),
              _FormField(
                controller: _titleCtrl,
                hint: "e.g. Understanding the Book of John",
                maxLength: 100,
                onChanged: (_) => setState(() {}),
              ),
              _FieldHelper(
                text: _titleHelperText(),
                mood: _moodFor(len: _titleCtrl.text.trim().length, min: 5),
              ),
              const SizedBox(height: 16),

              // Description
              const _FormLabel("DESCRIPTION", required: true),
              const SizedBox(height: 8),
              _FormField(
                controller: _descCtrl,
                hint:
                    "What will this session cover? What should attendees expect?",
                maxLines: 3,
                maxLength: 300,
                onChanged: (_) => setState(() {}),
              ),
              _FieldHelper(
                text: _descHelperText(),
                mood: _moodFor(len: _descCtrl.text.trim().length, min: 20),
              ),
              const SizedBox(height: 16),

              // Category
              const _FormLabel("CATEGORY", required: true),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: _categories
                    .map((c) => _CategoryChip(
                          label: c,
                          selected: _category == c,
                          onTap: () => setState(() => _category = c),
                        ))
                    .toList(),
              ),
              const SizedBox(height: 16),

              // Date + Time
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const _FormLabel("DATE", required: true),
                        const SizedBox(height: 8),
                        _DateTimeField(
                          icon: AppIcons.calendar,
                          value:
                              _date != null ? _formatFullDate(_date!) : null,
                          hint: "Select date",
                          onTap: _pickDate,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const _FormLabel("TIME (IST)", required: true),
                        const SizedBox(height: 8),
                        _DateTimeField(
                          icon: AppIcons.clock,
                          value: _time != null
                              ? '${_formatTime(_time!)} IST'
                              : null,
                          hint: "Select time",
                          onTap: _pickTime,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              const _FormLabel("DURATION", required: true),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: _durationOptions
                    .map((m) => _CategoryChip(
                          label: _formatDurationLabel(m),
                          selected: _durationMinutes == m,
                          onTap: () =>
                              setState(() => _durationMinutes = m),
                        ))
                    .toList(),
              ),
              const SizedBox(height: 16),

              // Meet link (optional)
              Row(
                children: [
                  const _FormLabel("GOOGLE MEET LINK"),
                  const SizedBox(width: 6),
                  GestureDetector(
                    onTap: _showLinkGuide,
                    behavior: HitTestBehavior.opaque,
                    child: Container(
                      width: 20,
                      height: 20,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: const Color(0xFF3B82F6)
                            .withValues(alpha: 0.1),
                      ),
                      child: const AppIcon(
                        AppIcons.info,
                        size: 12,
                        color: Color(0xFF3B82F6),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              _FormField(
                controller: _linkCtrl,
                hint: "Paste from Google Meet (or type the URL)",
                keyboardType: TextInputType.url,
                onChanged: (_) => setState(() {}),
              ),
              Builder(
                builder: (_) {
                  final h = _linkHelper();
                  return _FieldHelper(text: h.text, mood: h.mood);
                },
              ),
              const SizedBox(height: 16),

              // Max attendees
              const _FormLabel("MAX ATTENDEES"),
              const SizedBox(height: 8),
              _FormField(
                controller: _maxCtrl,
                hint: "Unlimited if left empty",
                keyboardType: TextInputType.number,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                ],
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 16),

              const _InfoTip(
                "Title and description cannot be edited after publishing. "
                "You'll be able to add or change the meeting link any time "
                "before Start Meeting.",
              ),

              if (_formError != null) ...[
                const SizedBox(height: 16),
                Text(
                  _formError!,
                  style: GoogleFonts.inter(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: AppColors.errorRed,
                  ),
                ),
              ],

              if (_missingFields.isNotEmpty && !_creating) ...[
                const SizedBox(height: 20),
                _AlmostThereCard(missing: _missingFields),
              ],

              const SizedBox(height: 24),

              _PressableButton(
                onTap: (_isValid && !_creating) ? _openReview : null,
                child: Container(
                  width: double.infinity,
                  height: 52,
                  decoration: BoxDecoration(
                    color: _isValid
                        ? AppColors.amberGold
                        : AppColors.muted.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(14),
                    boxShadow: _isValid
                        ? [
                            BoxShadow(
                              color: AppColors.amberGold
                                  .withValues(alpha: 0.35),
                              blurRadius: 16,
                              offset: const Offset(0, 6),
                            ),
                          ]
                        : const [],
                  ),
                  child: Center(
                    child: _creating
                        ? const SizedBox(
                            width: 35,
                            height: 35,
                            child: AppLoader(),
                          )
                        : Text(
                            "Review & Publish",
                            style: GoogleFonts.inter(
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                              color: _isValid
                                  ? Colors.white
                                  : AppColors.muted,
                            ),
                          ),
                  ),
                ),
              ),
              SizedBox(
                height: MediaQuery.of(context).padding.bottom + 16,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════
// REVIEW & PUBLISH SHEET
// ════════════════════════════════════════════════════════════════
//
// Stateless review of everything the priest just entered. Two
// terminal actions: "Edit" (pops false → caller keeps the form open
// untouched) or "Confirm & Publish" (pops true → caller calls the
// CF). Deliberately keeps the same value-formatting as the cards so
// the priest sees the session exactly as users will see it.

class _ReviewSheet extends StatefulWidget {
  final String title;
  final String description;
  final String category;
  final DateTime scheduledAt;
  final int durationMinutes;
  final int price;
  final int maxAttendees;
  final String meetingLink;
  // Runs the actual create; returns true on success. The sheet keeps
  // its spinner up while this is awaited and only closes on true.
  final Future<bool> Function() onConfirm;

  const _ReviewSheet({
    required this.title,
    required this.description,
    required this.category,
    required this.scheduledAt,
    required this.durationMinutes,
    required this.price,
    required this.maxAttendees,
    required this.meetingLink,
    required this.onConfirm,
  });

  @override
  State<_ReviewSheet> createState() => _ReviewSheetState();
}

class _ReviewSheetState extends State<_ReviewSheet> {
  bool _submitting = false;

  Future<void> _handleConfirm() async {
    if (_submitting) return;
    setState(() => _submitting = true);
    final ok = await widget.onConfirm();
    if (!mounted) return;
    // On success close with true (caller pops the form + shows the
    // success snackbar). On failure close with false so the underlying
    // form is revealed with its _formError.
    Navigator.of(context).pop(ok);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // Block back-dismiss mid-create so the priest can't leave a
      // half-finished publish in an ambiguous state.
      canPop: !_submitting,
      child: Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.92,
      ),
      decoration: const BoxDecoration(
        color: AppColors.surfaceWhite,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
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
            const SizedBox(height: 16),
            Center(
              child: Text(
                "Review Your Session",
                style: GoogleFonts.inter(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  color: AppColors.deepDarkBrown,
                ),
              ),
            ),
            const SizedBox(height: 6),
            Center(
              child: Text(
                "Make sure everything is correct.",
                style: GoogleFonts.inter(
                  fontSize: 12,
                  fontWeight: FontWeight.w400,
                  color: AppColors.muted,
                ),
              ),
            ),
            const SizedBox(height: 24),

            _ReviewRow(label: "Title", value: widget.title),
            _ReviewRow(label: "Category", value: widget.category),
            _ReviewRow(label: "Description", value: widget.description),
            _ReviewRow(
              label: "Date & Time",
              value:
                  "${_formatFullDate(widget.scheduledAt)} · ${_formatTimeFromDate(widget.scheduledAt)} IST",
            ),
            _ReviewRow(
              label: "Duration",
              value: _formatDurationLabel(widget.durationMinutes),
            ),
            _ReviewRow(label: "Price", value: "₹${widget.price} per person"),
            _ReviewRow(
              label: "Max Participants",
              value:
                  widget.maxAttendees == 0 ? "Unlimited" : "${widget.maxAttendees}",
            ),
            _ReviewRow(
              label: "Meeting Link",
              value: widget.meetingLink.isEmpty
                  ? "Not added yet — add before Start Meeting"
                  : widget.meetingLink,
              mutedIfEmpty: widget.meetingLink.isEmpty,
            ),

            const SizedBox(height: 16),

            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.amberGold.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: AppColors.amberGold.withValues(alpha: 0.25),
                ),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AppIcon(
                    AppIcons.warning,
                    size: 14,
                    color: AppColors.amberGold,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      "Price, title, and description cannot be changed "
                      "after publishing.",
                      style: GoogleFonts.inter(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: AppColors.amberGold.withValues(alpha: 0.95),
                        height: 1.4,
                      ),
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 24),

            Row(
              children: [
                Expanded(
                  child: _PressableButton(
                    // Disabled mid-create so the priest can't edit while
                    // the session is being published.
                    onTap: _submitting
                        ? null
                        : () => Navigator.of(context).pop(false),
                    child: Opacity(
                      opacity: _submitting ? 0.5 : 1,
                      child: Container(
                        height: 50,
                        decoration: BoxDecoration(
                          color: Colors.transparent,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: AppColors.muted.withValues(alpha: 0.4),
                            width: 1.5,
                          ),
                        ),
                        child: Center(
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              AppIcon(
                                AppIcons.back,
                                size: 16,
                                color: AppColors.deepDarkBrown,
                              ),
                              const SizedBox(width: 6),
                              Text(
                                "Edit",
                                style: GoogleFonts.inter(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                  color: AppColors.deepDarkBrown,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: _PressableButton(
                    onTap: _submitting ? null : _handleConfirm,
                    child: Container(
                      height: 50,
                      decoration: BoxDecoration(
                        color: AppColors.primaryBrown,
                        borderRadius: BorderRadius.circular(12),
                        boxShadow: [
                          BoxShadow(
                            color: AppColors.primaryBrown
                                .withValues(alpha: 0.25),
                            blurRadius: 12,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: Center(
                        child: _submitting
                            ? const SizedBox(
                                width: 32,
                                height: 32,
                                child: AppLoader(),
                              )
                            : Text(
                                "Confirm & Publish",
                                style: GoogleFonts.inter(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w700,
                                  color: Colors.white,
                                ),
                              ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            SizedBox(
              height: MediaQuery.of(context).padding.bottom + 12,
            ),
          ],
        ),
        ),
      ),
    );
  }
}

class _ReviewRow extends StatelessWidget {
  final String label;
  final String value;
  // ignore: unused_element_parameter
  final bool mutedIfEmpty;
  const _ReviewRow({
    required this.label,
    required this.value,
    this.mutedIfEmpty = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label.toUpperCase(),
            style: GoogleFonts.inter(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: AppColors.muted,
              letterSpacing: 0.8,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: GoogleFonts.inter(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: mutedIfEmpty
                  ? AppColors.muted
                  : AppColors.deepDarkBrown,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Form primitives ────────────────────────────────────────────

enum _HelperMood { neutral, error, success }

class _AlmostThereCard extends StatelessWidget {
  final List<String> missing;
  const _AlmostThereCard({required this.missing});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      decoration: BoxDecoration(
        color: AppColors.amberGold.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: AppColors.amberGold.withValues(alpha: 0.22),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              AppIcon(
                AppIcons.info,
                size: 14,
                color: AppColors.amberGold,
              ),
              const SizedBox(width: 8),
              Text(
                "Almost there — still needed",
                style: GoogleFonts.inter(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: AppColors.amberGold,
                  letterSpacing: 0.3,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: missing
                .map(
                  (issue) => Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.amberGold.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(7),
                    ),
                    child: Text(
                      issue,
                      style: GoogleFonts.inter(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: AppColors.amberGold.withValues(alpha: 0.95),
                      ),
                    ),
                  ),
                )
                .toList(),
          ),
        ],
      ),
    );
  }
}

class _FieldHelper extends StatelessWidget {
  final String text;
  final _HelperMood mood;
  const _FieldHelper({required this.text, required this.mood});

  static const _successGreen = AppColors.successGreen;

  @override
  Widget build(BuildContext context) {
    final color = switch (mood) {
      _HelperMood.neutral => AppColors.muted.withValues(alpha: 0.7),
      _HelperMood.error => AppColors.errorRed,
      _HelperMood.success => _successGreen,
    };
    final icon = switch (mood) {
      _HelperMood.neutral => null,
      _HelperMood.error => AppIcons.error,
      _HelperMood.success => AppIcons.checkCircle,
    };
    return Padding(
      padding: const EdgeInsets.only(top: 6, left: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (icon != null) ...[
            AppIcon(icon, size: 12, color: color),
            const SizedBox(width: 5),
          ],
          Flexible(
            child: Text(
              text,
              style: GoogleFonts.inter(
                fontSize: 11,
                fontWeight: FontWeight.w500,
                color: color,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _FormLabel extends StatelessWidget {
  final String text;
  final bool required;
  const _FormLabel(this.text, {this.required = false});

  @override
  Widget build(BuildContext context) {
    return RichText(
      text: TextSpan(
        children: [
          TextSpan(
            text: text,
            style: GoogleFonts.inter(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: AppColors.muted,
              letterSpacing: 0.8,
            ),
          ),
          if (required)
            TextSpan(
              text: " *",
              style: GoogleFonts.inter(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: AppColors.errorRed,
              ),
            ),
        ],
      ),
    );
  }
}

class _FormField extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final int maxLines;
  final int? maxLength;
  final TextInputType? keyboardType;
  final List<TextInputFormatter>? inputFormatters;
  final ValueChanged<String>? onChanged;

  const _FormField({
    required this.controller,
    required this.hint,
    this.maxLines = 1,
    this.maxLength,
    this.keyboardType,
    this.inputFormatters,
    this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      maxLines: maxLines,
      maxLength: maxLength,
      keyboardType: keyboardType,
      inputFormatters: inputFormatters,
      onChanged: onChanged,
      style: GoogleFonts.inter(
        fontSize: 14,
        fontWeight: FontWeight.w500,
        color: AppColors.deepDarkBrown,
      ),
      cursorColor: AppColors.primaryBrown,
      decoration: InputDecoration(
        hintText: hint,
        prefixStyle: GoogleFonts.inter(
          fontSize: 14,
          fontWeight: FontWeight.w600,
          color: AppColors.deepDarkBrown,
        ),
        hintStyle: GoogleFonts.inter(
          fontSize: 14,
          fontWeight: FontWeight.w400,
          color: AppColors.muted.withValues(alpha: 0.6),
        ),
        filled: true,
        fillColor: AppColors.warmBeige.withValues(alpha: 0.5),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        counterText: '',
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(
            color: AppColors.muted.withValues(alpha: 0.15),
          ),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(
            color: AppColors.primaryBrown,
            width: 1.5,
          ),
        ),
      ),
    );
  }
}

class _DateTimeField extends StatelessWidget {
  final IconData icon;
  final String? value;
  final String hint;
  final VoidCallback onTap;

  const _DateTimeField({
    required this.icon,
    required this.value,
    required this.hint,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final hasValue = value != null;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        decoration: BoxDecoration(
          color: AppColors.warmBeige.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: AppColors.muted.withValues(alpha: 0.15),
          ),
        ),
        child: Row(
          children: [
            AppIcon(icon, size: 16, color: AppColors.muted),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                hasValue ? value! : hint,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.inter(
                  fontSize: 13,
                  fontWeight:
                      hasValue ? FontWeight.w600 : FontWeight.w400,
                  color: hasValue
                      ? AppColors.deepDarkBrown
                      : AppColors.muted.withValues(alpha: 0.6),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CategoryChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _CategoryChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: selected
              ? AppColors.primaryBrown.withValues(alpha: 0.08)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: selected
                ? AppColors.primaryBrown
                : AppColors.muted.withValues(alpha: 0.2),
          ),
        ),
        child: Text(
          label,
          style: GoogleFonts.inter(
            fontSize: 13,
            fontWeight:
                selected ? FontWeight.w600 : FontWeight.w400,
            color:
                selected ? AppColors.primaryBrown : AppColors.muted,
          ),
        ),
      ),
    );
  }
}

class _InfoTip extends StatelessWidget {
  final String message;
  const _InfoTip(this.message);

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.amberGold.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: AppColors.amberGold.withValues(alpha: 0.15),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppIcon(
            AppIcons.info,
            size: 14,
            color: AppColors.amberGold,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: GoogleFonts.inter(
                fontSize: 12,
                fontWeight: FontWeight.w400,
                color: AppColors.amberGold.withValues(alpha: 0.9),
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PressableButton extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;

  const _PressableButton({required this.child, required this.onTap});

  @override
  State<_PressableButton> createState() => _PressableButtonState();
}

class _PressableButtonState extends State<_PressableButton> {
  double _scale = 1.0;

  @override
  Widget build(BuildContext context) {
    final disabled = widget.onTap == null;
    return GestureDetector(
      onTapDown: disabled ? null : (_) => setState(() => _scale = 0.97),
      onTapUp: disabled ? null : (_) => setState(() => _scale = 1.0),
      onTapCancel: disabled ? null : () => setState(() => _scale = 1.0),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _scale,
        duration: const Duration(milliseconds: 100),
        child: widget.child,
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════
// MEET LINK GUIDE BOTTOM SHEET
// ════════════════════════════════════════════════════════════════

class _MeetLinkGuideSheet extends StatelessWidget {
  const _MeetLinkGuideSheet();

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.85,
      ),
      decoration: const BoxDecoration(
        color: AppColors.surfaceWhite,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
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
            const SizedBox(height: 16),
            Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    color:
                        const Color(0xFF3B82F6).withValues(alpha: 0.08),
                  ),
                  child: const AppIcon(
                    AppIcons.video,
                    size: 22,
                    color: Color(0xFF3B82F6),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        "How to Create a Meeting Link",
                        style: GoogleFonts.inter(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                          color: AppColors.deepDarkBrown,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        "It takes less than a minute!",
                        style: GoogleFonts.inter(
                          fontSize: 12,
                          fontWeight: FontWeight.w400,
                          color: AppColors.muted,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            const _GuideStep(
              number: 1,
              title: "Open Google Meet",
              description:
                  "Open the Google Meet app on your phone, or visit "
                  "meet.google.com in your browser.",
            ),
            const SizedBox(height: 16),
            const _GuideStep(
              number: 2,
              title: "Create a New Meeting",
              description:
                  "Tap the 'New meeting' button or '+' icon.",
            ),
            const SizedBox(height: 16),
            const _GuideStep(
              number: 3,
              title: "Choose 'Create a meeting for later'",
              description:
                  "This gives you a link without starting the meeting "
                  "right now.",
            ),
            const SizedBox(height: 16),
            const _GuideStep(
              number: 4,
              title: "Copy the Link",
              description:
                  "You'll see a link like meet.google.com/abc-defg-hij. "
                  "Tap 'Copy' or long-press to copy it.",
            ),
            const SizedBox(height: 16),
            const _GuideStep(
              number: 5,
              title: "Paste Here",
              description:
                  "Come back to Gospel Vox and paste the link in the "
                  "'Google Meet Link' field.",
            ),
            const SizedBox(height: 20),
            const _InfoTip(
              "You don't need to add the link right now! You can "
              "create the session first and add the link later from "
              "the session details page.",
            ),
            const SizedBox(height: 20),
            _PressableButton(
              onTap: () => Navigator.of(context).pop(),
              child: Container(
                width: double.infinity,
                height: 48,
                decoration: BoxDecoration(
                  color: AppColors.primaryBrown,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Center(
                  child: Text(
                    "Got it!",
                    style: GoogleFonts.inter(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ),
            SizedBox(
              height: MediaQuery.of(context).padding.bottom + 12,
            ),
          ],
        ),
      ),
    );
  }
}

class _GuideStep extends StatelessWidget {
  final int number;
  final String title;
  final String description;

  const _GuideStep({
    required this.number,
    required this.title,
    required this.description,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: AppColors.primaryBrown.withValues(alpha: 0.08),
          ),
          child: Center(
            child: Text(
              "$number",
              style: GoogleFonts.inter(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: AppColors.primaryBrown,
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: AppColors.deepDarkBrown,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                description,
                style: GoogleFonts.inter(
                  fontSize: 12,
                  fontWeight: FontWeight.w400,
                  color: AppColors.muted,
                  height: 1.5,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ─── Date / time / duration formatters ──────────────────────────

const _kMonthNames = [
  '',
  'January', 'February', 'March', 'April', 'May', 'June',
  'July', 'August', 'September', 'October', 'November', 'December',
];

String _formatFullDate(DateTime d) {
  return '${_kMonthNames[d.month]} ${d.day}, ${d.year}';
}

String _formatShortDate(DateTime d) {
  const short = [
    '', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  return '${short[d.month]} ${d.day}';
}

String _formatTime(TimeOfDay t) {
  final h = t.hour > 12 ? t.hour - 12 : (t.hour == 0 ? 12 : t.hour);
  final period = t.hour >= 12 ? 'PM' : 'AM';
  return '$h:${t.minute.toString().padLeft(2, '0')} $period';
}

String _formatTimeFromDate(DateTime d) {
  return _formatTime(TimeOfDay(hour: d.hour, minute: d.minute));
}

String _formatDurationLabel(int mins) {
  if (mins < 60) return '$mins min';
  final hours = mins ~/ 60;
  final remaining = mins % 60;
  if (remaining == 0) return hours == 1 ? '1 hour' : '$hours hours';
  return '${hours}h ${remaining}m';
}
