// Priest profile, viewed by a USER who is deciding whether to open a
// session. Distinct from the admin's SpeakerDetailPage — different
// actions, different affordances, different trust affordances.
//
// Three Firestore reads happen in parallel on mount:
//   1. priests/{id} — the priest profile itself
//   2. users/{uid}.coinBalance — so the action buttons can gate on
//      affordability
//   3. app_config/settings — for session rates shown in copy
// Failing any single one shows an error state with retry; partial
// success (e.g. balance fetch flakes) would otherwise render a
// button that looks active and then fails on tap.

import 'package:cached_network_image/cached_network_image.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shimmer/shimmer.dart';

import 'package:gospel_vox/core/services/injection_container.dart';
import 'package:gospel_vox/core/theme/app_colors.dart';
import 'package:gospel_vox/core/widgets/app_snackbar.dart';
import 'package:gospel_vox/features/admin/speakers/data/speaker_model.dart';
import 'package:gospel_vox/features/user/home/data/home_repository.dart';
import 'package:gospel_vox/features/user/home/widgets/no_priests_widget.dart';

class PriestProfilePage extends StatefulWidget {
  final String priestId;
  const PriestProfilePage({super.key, required this.priestId});

  @override
  State<PriestProfilePage> createState() => _PriestProfilePageState();
}

class _PriestProfilePageState extends State<PriestProfilePage> {
  late final HomeRepository _repo = sl<HomeRepository>();

  bool _loading = true;
  String? _error;

  SpeakerModel? _priest;
  int _balance = 0;
  int _chatRate = 10;
  int _voiceRate = 20;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      setState(() {
        _loading = false;
        _error = 'You must be signed in to view this profile.';
      });
      return;
    }

    try {
      final results = await Future.wait([
        _repo.getPriestDetail(widget.priestId),
        _repo.getUserBalance(uid),
        _repo.getSessionRates(),
      ]);

      if (!mounted) return;
      setState(() {
        _priest = results[0] as SpeakerModel;
        _balance = results[1] as int;
        final rates = results[2] as Map<String, int>;
        _chatRate = rates['chat'] ?? 10;
        _voiceRate = rates['voice'] ?? 20;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Could not load speaker profile.';
      });
    }
  }

  int get _minCost => _chatRate;
  // Users can only start a session if the priest is truly available
  // (online AND not paused) AND the user has enough coins. Mirrors
  // the home feed's "Available Now" bucket exactly so there's no
  // inconsistency between the list and the profile.
  bool get _canStart =>
      _priest != null &&
      _priest!.isAvailable &&
      _balance >= _minCost;

  void _requestSession(String type) {
    // Session request flow lands here next week. For now we just
    // acknowledge the tap — keeps the button responsive rather than
    // silently doing nothing, which always reads as "broken".
    AppSnackBar.info(context, 'Session requests coming soon');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: _buildAppBar(),
      body: _buildBody(),
    );
  }

  PreferredSizeWidget _buildAppBar() {
    return AppBar(
      backgroundColor: AppColors.background,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      leading: Padding(
        padding: const EdgeInsets.only(left: 12),
        child: Align(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              if (context.canPop()) context.pop();
            },
            child: Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.surfaceWhite,
                boxShadow: [
                  BoxShadow(
                    blurRadius: 6,
                    offset: const Offset(0, 2),
                    color: Colors.black.withValues(alpha: 0.05),
                  ),
                ],
              ),
              child: Icon(
                Icons.arrow_back_rounded,
                size: 20,
                color: AppColors.deepDarkBrown,
              ),
            ),
          ),
        ),
      ),
      title: Text(
        'Speaker Profile',
        style: GoogleFonts.inter(
          fontSize: 18,
          fontWeight: FontWeight.w600,
          color: AppColors.deepDarkBrown,
        ),
      ),
      centerTitle: true,
      bottom: PreferredSize(
        preferredSize: const Size.fromHeight(1),
        child: Container(
          height: 1,
          color: AppColors.muted.withValues(alpha: 0.1),
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) return const _ProfileShimmer();

    if (_error != null || _priest == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 40),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.error_outline_rounded,
                size: 40,
                color: AppColors.muted.withValues(alpha: 0.5),
              ),
              const SizedBox(height: 16),
              Text(
                _error ?? 'Something went wrong.',
                textAlign: TextAlign.center,
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: AppColors.deepDarkBrown,
                ),
              ),
              const SizedBox(height: 16),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  setState(() {
                    _loading = true;
                    _error = null;
                  });
                  _load();
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.primaryBrown,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    'Try Again',
                    style: GoogleFonts.inter(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Stack(
      children: [
        SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
          physics: const BouncingScrollPhysics(),
          child: _ProfileContent(
            priest: _priest!,
            balance: _balance,
            chatRate: _chatRate,
            voiceRate: _voiceRate,
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: _StickyActions(
            priest: _priest!,
            balance: _balance,
            minCost: _minCost,
            chatRate: _chatRate,
            voiceRate: _voiceRate,
            canStart: _canStart,
            onChat: () => _requestSession('chat'),
            onVoice: () => _requestSession('voice'),
          ),
        ),
      ],
    );
  }
}

// ─── Scrollable profile content ────────────────────────────

class _ProfileContent extends StatelessWidget {
  final SpeakerModel priest;
  final int balance;
  final int chatRate;
  final int voiceRate;

  const _ProfileContent({
    required this.priest,
    required this.balance,
    required this.chatRate,
    required this.voiceRate,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 16),
        Center(child: _ProfileHeader(priest: priest)),
        const SizedBox(height: 24),
        _StatsRow(priest: priest),
        const SizedBox(height: 24),
        if (priest.bio.isNotEmpty) ...[
          const _SectionTitle('About'),
          const SizedBox(height: 10),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.surfaceWhite,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: AppColors.muted.withValues(alpha: 0.08),
              ),
            ),
            child: Text(
              priest.bio,
              style: GoogleFonts.inter(
                fontSize: 14,
                fontWeight: FontWeight.w400,
                height: 1.6,
                color: AppColors.deepDarkBrown,
              ),
            ),
          ),
          const SizedBox(height: 20),
        ],
        if (priest.specializations.isNotEmpty) ...[
          const _SectionTitle('Specializations'),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: priest.specializations
                .map((s) => _PillChip(
                      label: s,
                      filled: true,
                    ))
                .toList(),
          ),
          const SizedBox(height: 20),
        ],
        if (priest.languages.isNotEmpty) ...[
          const _SectionTitle('Languages'),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: priest.languages
                .map((l) => _PillChip(
                      label: l,
                      filled: false,
                    ))
                .toList(),
          ),
          const SizedBox(height: 20),
        ],
        InfoTipBlock(
          'Sessions are billed per minute. Chat: $chatRate coins/min, '
          'Voice: $voiceRate coins/min. Your current balance: '
          '$balance coins.',
        ),
        // Reserve room below the sticky action bar. 120px comfortably
        // clears the buttons + safe area on the shortest phones we
        // care about.
        const SizedBox(height: 180),
      ],
    );
  }
}

class _ProfileHeader extends StatelessWidget {
  final SpeakerModel priest;

  const _ProfileHeader({required this.priest});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          width: 96,
          height: 96,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: const Color(0xFFF7F5F2),
            border: Border.all(
              color: AppColors.muted.withValues(alpha: 0.15),
              width: 2,
            ),
            boxShadow: [
              BoxShadow(
                blurRadius: 16,
                offset: const Offset(0, 4),
                color: Colors.black.withValues(alpha: 0.06),
              ),
            ],
          ),
          clipBehavior: Clip.antiAlias,
          child: priest.hasPhoto
              ? CachedNetworkImage(
                  imageUrl: priest.photoUrl,
                  fit: BoxFit.cover,
                  errorWidget: (_, _, _) => _HeaderInitial(priest: priest),
                  placeholder: (_, _) => const SizedBox.shrink(),
                )
              : _HeaderInitial(priest: priest),
        ),
        const SizedBox(height: 16),
        Text(
          priest.fullName,
          style: GoogleFonts.inter(
            fontSize: 22,
            fontWeight: FontWeight.w700,
            color: AppColors.deepDarkBrown,
          ),
        ),
        const SizedBox(height: 6),
        if (priest.denomination.isNotEmpty)
          Text(
            priest.denomination,
            style: GoogleFonts.inter(
              fontSize: 14,
              fontWeight: FontWeight.w400,
              color: AppColors.muted,
            ),
          ),
        const SizedBox(height: 4),
        if (priest.location.isNotEmpty)
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.location_on_outlined,
                size: 14,
                color: AppColors.muted,
              ),
              const SizedBox(width: 4),
              Text(
                priest.location,
                style: GoogleFonts.inter(
                  fontSize: 13,
                  fontWeight: FontWeight.w400,
                  color: AppColors.muted,
                ),
              ),
            ],
          ),
        const SizedBox(height: 12),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _OnlineBadge(priest: priest),
            if (priest.rating > 0) ...[
              const SizedBox(width: 12),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.star_rounded,
                    size: 16,
                    color: AppColors.amberGold,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    '${priest.rating.toStringAsFixed(1)} '
                    '(${priest.reviewCount})',
                    style: GoogleFonts.inter(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: AppColors.deepDarkBrown,
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ],
    );
  }
}

class _HeaderInitial extends StatelessWidget {
  final SpeakerModel priest;
  const _HeaderInitial({required this.priest});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        priest.initial,
        style: GoogleFonts.inter(
          fontSize: 36,
          fontWeight: FontWeight.w700,
          color: AppColors.muted,
        ),
      ),
    );
  }
}

// Availability badge that distinguishes Available / Busy / Offline
// so users understand exactly why Chat and Voice might be disabled.
class _OnlineBadge extends StatelessWidget {
  final SpeakerModel priest;
  const _OnlineBadge({required this.priest});

  @override
  Widget build(BuildContext context) {
    final (label, color) = _spec(priest);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: GoogleFonts.inter(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  (String, Color) _spec(SpeakerModel p) {
    if (p.isAvailable) return ('Online', const Color(0xFF2E7D4F));
    if (p.isOnline && p.isBusy) return ('Busy', AppColors.amberGold);
    return ('Offline', AppColors.muted);
  }
}

class _StatsRow extends StatelessWidget {
  final SpeakerModel priest;

  const _StatsRow({required this.priest});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surfaceWhite,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: AppColors.muted.withValues(alpha: 0.08),
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _ProfileStat(
            label: 'Sessions',
            value: priest.totalSessions.toString(),
          ),
          _ProfileDivider(),
          _ProfileStat(
            label: 'Experience',
            value: '${priest.yearsOfExperience}y',
          ),
          _ProfileDivider(),
          _ProfileStat(
            label: 'Reviews',
            value: priest.reviewCount.toString(),
          ),
        ],
      ),
    );
  }
}

class _ProfileStat extends StatelessWidget {
  final String label;
  final String value;

  const _ProfileStat({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          value,
          style: GoogleFonts.inter(
            fontSize: 18,
            fontWeight: FontWeight.w700,
            color: AppColors.deepDarkBrown,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: GoogleFonts.inter(
            fontSize: 11,
            fontWeight: FontWeight.w400,
            color: AppColors.muted,
          ),
        ),
      ],
    );
  }
}

class _ProfileDivider extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 1,
      height: 32,
      color: AppColors.muted.withValues(alpha: 0.12),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: GoogleFonts.inter(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.3,
        color: AppColors.muted,
      ),
    );
  }
}

class _PillChip extends StatelessWidget {
  final String label;
  final bool filled;

  const _PillChip({required this.label, required this.filled});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: filled
            ? AppColors.primaryBrown.withValues(alpha: 0.05)
            : AppColors.surfaceWhite,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: filled
              ? AppColors.primaryBrown.withValues(alpha: 0.1)
              : AppColors.muted.withValues(alpha: 0.15),
        ),
      ),
      child: Text(
        label,
        style: GoogleFonts.inter(
          fontSize: 12,
          fontWeight: FontWeight.w500,
          color: filled
              ? AppColors.primaryBrown
              : AppColors.deepDarkBrown,
        ),
      ),
    );
  }
}

// ─── Sticky action bar ─────────────────────────────────────

class _StickyActions extends StatelessWidget {
  final SpeakerModel priest;
  final int balance;
  final int minCost;
  final int chatRate;
  final int voiceRate;
  final bool canStart;
  final VoidCallback onChat;
  final VoidCallback onVoice;

  const _StickyActions({
    required this.priest,
    required this.balance,
    required this.minCost,
    required this.chatRate,
    required this.voiceRate,
    required this.canStart,
    required this.onChat,
    required this.onVoice,
  });

  @override
  Widget build(BuildContext context) {
    final showLowBalance = balance < minCost;
    // Ordered by priority: the busy banner wins over the low-balance
    // banner, because even topping up the wallet wouldn't help if the
    // priest isn't accepting requests right now.
    final showBusy = priest.isOnline && priest.isBusy;
    final showOffline = !priest.isOnline;
    final bottomInset = MediaQuery.of(context).padding.bottom;

    return Container(
      padding: EdgeInsets.fromLTRB(20, 12, 20, bottomInset + 12),
      decoration: BoxDecoration(
        color: AppColors.background,
        boxShadow: [
          BoxShadow(
            color: AppColors.deepDarkBrown.withValues(alpha: 0.06),
            blurRadius: 12,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (showBusy)
            _ReasonBanner(
              icon: Icons.pause_circle_outline_rounded,
              text: 'This speaker is online but has paused new requests. '
                  'Come back in a little while.',
              color: AppColors.amberGold,
            )
          else if (showOffline)
            _ReasonBanner(
              icon: Icons.cloud_off_rounded,
              text: 'This speaker is offline right now. Check back once '
                  "they're available.",
              color: AppColors.muted,
            )
          else if (showLowBalance)
            _ReasonBanner(
              icon: Icons.info_outline_rounded,
              text: 'You need at least $minCost coins for a session. '
                  'Add coins to your wallet first.',
              color: AppColors.errorRed,
            ),
          Row(
            children: [
              Expanded(
                child: _ActionButton(
                  label: 'Chat',
                  icon: Icons.chat_bubble_outline_rounded,
                  filled: true,
                  enabled: canStart,
                  onTap: canStart ? onChat : null,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _ActionButton(
                  label: 'Voice Call',
                  icon: Icons.mic_none_rounded,
                  filled: false,
                  enabled: canStart,
                  onTap: canStart ? onVoice : null,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Center(
            child: Text(
              'Chat: $chatRate coins/min · Voice: $voiceRate coins/min',
              style: GoogleFonts.inter(
                fontSize: 11,
                fontWeight: FontWeight.w400,
                color: AppColors.muted.withValues(alpha: 0.6),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// Compact banner sitting directly above the Chat/Voice buttons to
// explain why they're disabled. Single widget with a color knob so
// busy / offline / low-balance all render from the same layout and
// look consistent.
class _ReasonBanner extends StatelessWidget {
  final IconData icon;
  final String text;
  final Color color;

  const _ReasonBanner({
    required this.icon,
    required this.text,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.18)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: GoogleFonts.inter(
                fontSize: 12,
                fontWeight: FontWeight.w400,
                height: 1.4,
                color: color,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ActionButton extends StatefulWidget {
  final String label;
  final IconData icon;
  // `filled` controls primary-vs-secondary visual weight; both variants
  // gray out together when `enabled` is false.
  final bool filled;
  final bool enabled;
  final VoidCallback? onTap;

  const _ActionButton({
    required this.label,
    required this.icon,
    required this.filled,
    required this.enabled,
    required this.onTap,
  });

  @override
  State<_ActionButton> createState() => _ActionButtonState();
}

class _ActionButtonState extends State<_ActionButton> {
  double _scale = 1.0;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.enabled;
    final filled = widget.filled;

    final Color bg;
    final Color fg;
    final BoxBorder? border;
    if (filled) {
      bg = enabled
          ? AppColors.primaryBrown
          : AppColors.muted.withValues(alpha: 0.2);
      fg = Colors.white;
      border = null;
    } else {
      bg = AppColors.surfaceWhite;
      fg = enabled
          ? AppColors.primaryBrown
          : AppColors.muted;
      border = Border.all(
        color: enabled
            ? AppColors.primaryBrown
            : AppColors.muted.withValues(alpha: 0.2),
        width: 1.5,
      );
    }

    return Listener(
      onPointerDown: (_) {
        if (enabled) setState(() => _scale = 0.97);
      },
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
            height: 52,
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(14),
              border: border,
              boxShadow: filled && enabled
                  ? [
                      BoxShadow(
                        color: AppColors.primaryBrown.withValues(alpha: 0.2),
                        blurRadius: 12,
                        offset: const Offset(0, 4),
                      ),
                    ]
                  : null,
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(widget.icon, size: 18, color: fg),
                const SizedBox(width: 8),
                Text(
                  widget.label,
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: fg,
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

// ─── Shimmer while loading ─────────────────────────────────

class _ProfileShimmer extends StatelessWidget {
  const _ProfileShimmer();

  @override
  Widget build(BuildContext context) {
    Widget box({
      required double h,
      double? w,
      BorderRadius? radius,
    }) {
      return Container(
        height: h,
        width: w,
        decoration: BoxDecoration(
          color: AppColors.muted.withValues(alpha: 0.18),
          borderRadius: radius ?? BorderRadius.circular(6),
        ),
      );
    }

    return Shimmer.fromColors(
      baseColor: AppColors.muted.withValues(alpha: 0.08),
      highlightColor: AppColors.surfaceWhite,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        physics: const NeverScrollableScrollPhysics(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 96,
                height: 96,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.muted.withValues(alpha: 0.2),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Center(child: box(h: 18, w: 180)),
            const SizedBox(height: 8),
            Center(child: box(h: 12, w: 120)),
            const SizedBox(height: 24),
            box(h: 80, radius: BorderRadius.circular(14)),
            const SizedBox(height: 24),
            box(h: 12, w: 80),
            const SizedBox(height: 10),
            box(h: 100, radius: BorderRadius.circular(14)),
            const SizedBox(height: 20),
            box(h: 12, w: 120),
            const SizedBox(height: 10),
            Row(
              children: [
                box(h: 30, w: 80, radius: BorderRadius.circular(20)),
                const SizedBox(width: 8),
                box(h: 30, w: 110, radius: BorderRadius.circular(20)),
                const SizedBox(width: 8),
                box(h: 30, w: 70, radius: BorderRadius.circular(20)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
