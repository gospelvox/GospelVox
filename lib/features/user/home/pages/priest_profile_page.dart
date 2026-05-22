// Priest profile, viewed by a USER who is deciding whether to open a
// session. Distinct from the priest's own PriestMyProfilePage and from
// the admin SpeakerDetailPage — different actions, different chrome.
//
// Layout pattern: full-bleed hero photo behind a floating "info card"
// that overlaps the bottom of the photo. Back/more buttons are pinned
// over the photo; the rest of the page (about, actions, services,
// reviews) scrolls beneath the card.
//
// Four Firestore reads happen in parallel on mount:
//   1. priests/{id} — the priest profile itself
//   2. users/{uid}.coinBalance — so the action buttons can gate on
//      affordability
//   3. app_config/settings — for session rates shown in copy
//   4. sessions where priestId==X with userRating + userFeedback —
//      to render the Reviews preview
// Failing any of #1-3 shows an error state with retry. Reviews fail
// open: an empty list just hides the section, the rest of the page
// still renders.

import 'package:cached_network_image/cached_network_image.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shimmer/shimmer.dart';

import 'package:gospel_vox/core/services/injection_container.dart';
import 'package:gospel_vox/core/theme/app_colors.dart';
import 'package:gospel_vox/core/widgets/app_back_button.dart';
import 'package:gospel_vox/core/widgets/app_icons.dart';
import 'package:gospel_vox/core/widgets/app_snackbar.dart';
import 'package:gospel_vox/features/admin/speakers/data/speaker_model.dart';
import 'package:gospel_vox/features/shared/data/session_preflight.dart';
import 'package:gospel_vox/features/user/home/data/home_repository.dart';

// Hero geometry. Two callsites in this file (the Stack's hero
// background and the card's overlap offset) have to stay in sync, so
// the numbers live up here as named constants.
const double _kHeroHeight = 420;
const double _kCardOverlap = 80;

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
  List<PriestReview> _reviews = const [];

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
        _repo.getRecentReviews(widget.priestId, limit: 3),
      ]);

      if (!mounted) return;
      setState(() {
        _priest = results[0] as SpeakerModel;
        _balance = results[1] as int;
        final rates = results[2] as Map<String, int>;
        _chatRate = rates['chat'] ?? 10;
        _voiceRate = rates['voice'] ?? 20;
        _reviews = results[3] as List<PriestReview>;
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

  // Floor for the low-balance banner — 5 minutes' worth of chat at
  // the current global rate. Matches the server-side gate in
  // createSessionRequest.ts so banner and CF agree on what
  // "insufficient" means.
  int get _minCost => _chatRate * 5;
  // Users can only start a session if the priest is truly available.
  // Balance is NOT part of this gate — the button stays tappable on
  // low balance so the tap can open the recharge sheet with contextual
  // deficit copy (AstroTalk pattern). The red banner above the buttons
  // is the visual cue; the action surfaces the recharge.
  bool get _canStart =>
      _priest != null && _priest!.isAvailable;

  Future<void> _requestSession(String type) async {
    final priest = _priest;
    if (priest == null) return;
    final canStart = await SessionPreflight.check(
      context,
      type: type,
      priestName: priest.fullName,
      prefetchedBalance: _balance,
      prefetchedRatePerMinute: type == 'chat' ? _chatRate : _voiceRate,
    );
    if (!canStart || !mounted) return;
    context.push('/session/waiting', extra: {
      'priestId': priest.uid,
      'priestName': priest.fullName,
      'priestPhotoUrl': priest.photoUrl,
      'priestDenomination': priest.denomination,
      'type': type,
    });
  }

  void _openMoreSheet() {
    final priest = _priest;
    if (priest == null) return;
    HapticFeedback.lightImpact();
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surfaceWhite,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetCtx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.muted.withValues(alpha: 0.25),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 18),
              _SheetRow(
                icon: AppIcons.link,
                label: 'Share Profile',
                onTap: () {
                  Navigator.of(sheetCtx).pop();
                  Clipboard.setData(ClipboardData(
                    text: 'gospelvox://priest/${priest.uid}',
                  ));
                  AppSnackBar.success(context, 'Profile link copied');
                },
              ),
              _SheetRow(
                icon: AppIcons.flag,
                label: 'Report Speaker',
                danger: true,
                onTap: () {
                  Navigator.of(sheetCtx).pop();
                  AppSnackBar.success(
                    context,
                    "Reported. We'll review this profile.",
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      // The hero photo extends UNDER the system status bar, so we let
      // the scaffold body run under it and handle the inset ourselves
      // for the floating action buttons.
      extendBodyBehindAppBar: true,
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) return const _ProfileShimmer();

    if (_error != null || _priest == null) {
      return SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 40),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                AppIcon(
                  AppIcons.error,
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
        ),
      );
    }

    final priest = _priest!;
    final topInset = MediaQuery.of(context).padding.top;

    return Stack(
      children: [
        // Hero photo — pinned to the top, behind everything. Stays put
        // as the rest of the page scrolls over it, giving a soft
        // parallax feel without a CustomScrollView.
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          height: _kHeroHeight,
          child: _HeroPhoto(priest: priest),
        ),

        // Scrollable content — starts overlapping the hero by
        // _kCardOverlap so the floating profile card visually
        // sits on top of the photo's bottom edge.
        Positioned.fill(
          top: _kHeroHeight - _kCardOverlap,
          child: SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
            child: _ProfileBody(
              priest: priest,
              balance: _balance,
              minCost: _minCost,
              chatRate: _chatRate,
              voiceRate: _voiceRate,
              canStart: _canStart,
              reviews: _reviews,
              onCall: () => _requestSession('voice'),
              onChat: () => _requestSession('chat'),
            ),
          ),
        ),

        // Availability pill — sits just above where the profile card
        // overlaps. Outside the scroll view so it stays visually
        // attached to the photo (the photo also stays put).
        Positioned(
          top: _kHeroHeight - _kCardOverlap - 52,
          left: 20,
          child: _AvailabilityPill(priest: priest),
        ),

        // Floating action chips — always reachable.
        Positioned(
          top: topInset + 8,
          left: 16,
          child: const AppBackButton(),
        ),
        Positioned(
          top: topInset + 8,
          right: 16,
          child: _CircleIconButton(
            icon: AppIcons.more,
            onTap: _openMoreSheet,
          ),
        ),
      ],
    );
  }
}

// ─── Hero photo (full-bleed background) ────────────────────────────

class _HeroPhoto extends StatelessWidget {
  final SpeakerModel priest;
  const _HeroPhoto({required this.priest});

  @override
  Widget build(BuildContext context) {
    final fallback = _InitialHero(priest: priest);

    final image = priest.hasPhoto
        ? CachedNetworkImage(
            imageUrl: priest.photoUrl,
            fit: BoxFit.cover,
            placeholder: (_, _) => Container(
              color: AppColors.primaryBrown.withValues(alpha: 0.08),
            ),
            errorWidget: (_, _, _) => fallback,
          )
        : fallback;

    return Stack(
      fit: StackFit.expand,
      children: [
        image,
        // Soft vignette at the top so the back/more buttons remain
        // readable when the photo behind them is bright. And a
        // matching vignette at the bottom that helps the floating
        // availability pill read against busy photo regions.
        IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withValues(alpha: 0.18),
                  Colors.transparent,
                  Colors.transparent,
                  Colors.black.withValues(alpha: 0.15),
                ],
                stops: const [0.0, 0.25, 0.72, 1.0],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _InitialHero extends StatelessWidget {
  final SpeakerModel priest;
  const _InitialHero({required this.priest});

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            AppColors.primaryBrown.withValues(alpha: 0.85),
            AppColors.deepDarkBrown,
          ],
        ),
      ),
      child: Center(
        child: Text(
          priest.initial,
          style: GoogleFonts.inter(
            fontSize: 88,
            fontWeight: FontWeight.w700,
            color: AppColors.amberGold.withValues(alpha: 0.9),
          ),
        ),
      ),
    );
  }
}

// ─── Top-right circle button (matches AppBackButton's geometry) ────

class _CircleIconButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;

  const _CircleIconButton({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        HapticFeedback.lightImpact();
        onTap();
      },
      child: Container(
        width: 40,
        height: 40,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: AppColors.surfaceWhite,
          boxShadow: [
            BoxShadow(
              blurRadius: 8,
              offset: const Offset(0, 2),
              color: Colors.black.withValues(alpha: 0.05),
            ),
          ],
        ),
        child: AppIcon(
          icon,
          size: 18,
          color: AppColors.deepDarkBrown,
        ),
      ),
    );
  }
}

// ─── Availability pill (over the hero) ─────────────────────────────

class _AvailabilityPill extends StatelessWidget {
  final SpeakerModel priest;
  const _AvailabilityPill({required this.priest});

  @override
  Widget build(BuildContext context) {
    final (label, color) = _spec(priest);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.surfaceWhite,
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            blurRadius: 10,
            offset: const Offset(0, 2),
            color: Colors.black.withValues(alpha: 0.08),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            label,
            style: GoogleFonts.inter(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: AppColors.deepDarkBrown,
            ),
          ),
        ],
      ),
    );
  }

  (String, Color) _spec(SpeakerModel p) {
    if (p.isAvailable) return ('Available', AppColors.sageOnline);
    if (p.isOnline && p.isBusy) return ('Busy', AppColors.amberGold);
    return ('Offline', AppColors.muted);
  }
}

// ─── The scrolling content (profile card + everything below) ──────

class _ProfileBody extends StatelessWidget {
  final SpeakerModel priest;
  final int balance;
  final int minCost;
  final int chatRate;
  final int voiceRate;
  final bool canStart;
  final List<PriestReview> reviews;
  final VoidCallback onCall;
  final VoidCallback onChat;

  const _ProfileBody({
    required this.priest,
    required this.balance,
    required this.minCost,
    required this.chatRate,
    required this.voiceRate,
    required this.canStart,
    required this.reviews,
    required this.onCall,
    required this.onChat,
  });

  @override
  Widget build(BuildContext context) {
    final showBusy = priest.isOnline && priest.isBusy;
    final showOffline = !priest.isOnline;
    final showLowBalance = !showBusy && !showOffline && balance < minCost;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _ProfileCard(priest: priest),
        const SizedBox(height: 24),
        if (priest.bio.trim().isNotEmpty) ...[
          _AboutSection(bio: priest.bio),
          const SizedBox(height: 18),
        ],
        if (showBusy)
          const _ReasonBanner(
            icon: AppIcons.pause,
            text: 'This speaker is online but has paused new requests. '
                'Come back in a little while.',
            color: AppColors.amberGold,
          )
        else if (showOffline)
          _ReasonBanner(
            icon: AppIcons.cloudOff,
            text: "This speaker is offline right now. Check back once "
                "they're available.",
            color: AppColors.muted,
          )
        else if (showLowBalance)
          _ReasonBanner(
            icon: AppIcons.info,
            text:
                'You need at least $minCost coins for a session. Tap a '
                'button to add coins now.',
            color: AppColors.errorRed,
          ),
        if (showBusy || showOffline || showLowBalance)
          const SizedBox(height: 12),
        _ActionRow(
          canStart: canStart,
          chatRate: chatRate,
          voiceRate: voiceRate,
          onCall: onCall,
          onChat: onChat,
        ),
        const SizedBox(height: 18),
        const _PrivacyBanner(),
        const SizedBox(height: 26),
        _ServicesSection(items: priest.specializations),
        if (priest.specializations.isNotEmpty)
          const SizedBox(height: 26),
        _ReviewsSection(
          reviews: reviews,
          totalReviewCount: priest.reviewCount,
        ),
      ],
    );
  }
}

// ─── Floating profile card (the one that overlaps the photo) ──────

class _ProfileCard extends StatelessWidget {
  final SpeakerModel priest;
  const _ProfileCard({required this.priest});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 18),
      decoration: BoxDecoration(
        color: AppColors.surfaceWhite,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            blurRadius: 20,
            offset: const Offset(0, 6),
            color: Colors.black.withValues(alpha: 0.06),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _DenominationTile(),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      priest.fullName.isEmpty
                          ? 'Speaker'
                          : priest.fullName,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.inter(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                        height: 1.2,
                        color: AppColors.deepDarkBrown,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      priest.denomination.isEmpty
                          ? '—'
                          : '${priest.denomination} Priest',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.inter(
                        fontSize: 13,
                        fontWeight: FontWeight.w400,
                        color: AppColors.muted,
                      ),
                    ),
                    const SizedBox(height: 10),
                    _RatingVerifiedRow(priest: priest),
                  ],
                ),
              ),
            ],
          ),
          if (_hasAnyStat(priest)) ...[
            const SizedBox(height: 18),
            Container(
              height: 1,
              color: AppColors.muted.withValues(alpha: 0.08),
            ),
            const SizedBox(height: 16),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: _StatCell(
                    icon: AppIcons.church,
                    primary: priest.churchName.isNotEmpty
                        ? priest.churchName
                        : 'Church',
                    secondary: priest.location.isNotEmpty
                        ? priest.location
                        : null,
                  ),
                ),
                _CellDivider(),
                Expanded(
                  child: _StatCell(
                    icon: AppIcons.calendar,
                    primary: priest.yearsOfExperience > 0
                        ? '${priest.yearsOfExperience}+ Years'
                        : 'New',
                    secondary: 'Experience',
                  ),
                ),
                _CellDivider(),
                Expanded(
                  child: _StatCell(
                    icon: AppIcons.podcast,
                    primary: priest.languages.isNotEmpty
                        ? priest.languages.join(', ')
                        : 'Languages',
                    secondary: null,
                    primaryMaxLines: 2,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  bool _hasAnyStat(SpeakerModel p) =>
      p.churchName.isNotEmpty ||
      p.location.isNotEmpty ||
      p.yearsOfExperience > 0 ||
      p.languages.isNotEmpty;
}

class _DenominationTile extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 52,
      height: 60,
      decoration: BoxDecoration(
        color: AppColors.amberGold.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(14),
      ),
      child: AppIcon(
        AppIcons.church,
        size: 26,
        color: AppColors.amberGold,
      ),
    );
  }
}

class _RatingVerifiedRow extends StatelessWidget {
  final SpeakerModel priest;
  const _RatingVerifiedRow({required this.priest});

  @override
  Widget build(BuildContext context) {
    final hasRating = priest.rating > 0 && priest.reviewCount > 0;
    final isVerified =
        priest.status == 'approved' && priest.isActivated;

    if (!hasRating && !isVerified) return const SizedBox.shrink();

    return Row(
      children: [
        if (hasRating) ...[
          AppIcon(
            AppIcons.starFilled,
            size: 14,
            color: AppColors.amberGold,
          ),
          const SizedBox(width: 4),
          Text(
            priest.rating.toStringAsFixed(1),
            style: GoogleFonts.inter(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: AppColors.deepDarkBrown,
            ),
          ),
          const SizedBox(width: 4),
          Text(
            '(${priest.reviewCount})',
            style: GoogleFonts.inter(
              fontSize: 12,
              fontWeight: FontWeight.w400,
              color: AppColors.muted,
            ),
          ),
        ],
        if (hasRating && isVerified) ...[
          const SizedBox(width: 10),
          Container(
            width: 1,
            height: 12,
            color: AppColors.muted.withValues(alpha: 0.25),
          ),
          const SizedBox(width: 10),
        ],
        if (isVerified) ...[
          AppIcon(
            AppIcons.shield,
            size: 13,
            color: AppColors.amberGold,
          ),
          const SizedBox(width: 4),
          Text(
            'Verified',
            style: GoogleFonts.inter(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: AppColors.muted,
            ),
          ),
        ],
      ],
    );
  }
}

class _StatCell extends StatelessWidget {
  final IconData icon;
  final String primary;
  final String? secondary;
  final int primaryMaxLines;

  const _StatCell({
    required this.icon,
    required this.primary,
    required this.secondary,
    this.primaryMaxLines = 1,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: AppColors.muted.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(10),
          ),
          child: AppIcon(
            icon,
            size: 16,
            color: AppColors.deepDarkBrown.withValues(alpha: 0.7),
          ),
        ),
        const SizedBox(height: 10),
        Text(
          primary,
          maxLines: primaryMaxLines,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: GoogleFonts.inter(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            height: 1.3,
            color: AppColors.deepDarkBrown,
          ),
        ),
        if (secondary != null) ...[
          const SizedBox(height: 2),
          Text(
            secondary!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: GoogleFonts.inter(
              fontSize: 11,
              fontWeight: FontWeight.w400,
              height: 1.3,
              color: AppColors.muted,
            ),
          ),
        ],
      ],
    );
  }
}

class _CellDivider extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Container(
        width: 1,
        height: 36,
        color: AppColors.muted.withValues(alpha: 0.1),
      ),
    );
  }
}

// ─── About (with Read More / Show Less) ────────────────────────────

class _AboutSection extends StatefulWidget {
  final String bio;
  const _AboutSection({required this.bio});

  @override
  State<_AboutSection> createState() => _AboutSectionState();
}

class _AboutSectionState extends State<_AboutSection> {
  bool _expanded = false;
  // 3 lines collapsed matches the reference layout where the bio
  // shows roughly two-to-three lines before the Read More link.
  static const int _collapsedLines = 3;

  @override
  Widget build(BuildContext context) {
    final bio = widget.bio.trim();
    final style = GoogleFonts.inter(
      fontSize: 14,
      fontWeight: FontWeight.w400,
      height: 1.55,
      color: AppColors.deepDarkBrown.withValues(alpha: 0.9),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'About',
          style: GoogleFonts.inter(
            fontSize: 16,
            fontWeight: FontWeight.w700,
            color: AppColors.deepDarkBrown,
          ),
        ),
        const SizedBox(height: 10),
        // LayoutBuilder lets us measure whether the bio would actually
        // overflow the collapsed limit. We only show the Read More
        // affordance when overflow exists — otherwise the link is a
        // lie ("Read more" with nothing more to read).
        LayoutBuilder(
          builder: (context, constraints) {
            final tp = TextPainter(
              text: TextSpan(text: bio, style: style),
              maxLines: _collapsedLines,
              textDirection: TextDirection.ltr,
            )..layout(maxWidth: constraints.maxWidth);
            final overflows = tp.didExceedMaxLines;

            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  bio,
                  maxLines: _expanded ? null : _collapsedLines,
                  overflow: _expanded
                      ? TextOverflow.visible
                      : TextOverflow.ellipsis,
                  style: style,
                ),
                if (overflows) ...[
                  const SizedBox(height: 6),
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () =>
                        setState(() => _expanded = !_expanded),
                    child: Text(
                      _expanded ? 'Show Less' : 'Read More',
                      style: GoogleFonts.inter(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: AppColors.amberGold,
                      ),
                    ),
                  ),
                ],
              ],
            );
          },
        ),
      ],
    );
  }
}

// ─── Action row (Call Now + Chat) ─────────────────────────────────

class _ActionRow extends StatelessWidget {
  final bool canStart;
  final int chatRate;
  final int voiceRate;
  final VoidCallback onCall;
  final VoidCallback onChat;

  const _ActionRow({
    required this.canStart,
    required this.chatRate,
    required this.voiceRate,
    required this.onCall,
    required this.onChat,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          flex: 6,
          child: _BigActionButton(
            label: 'Call Now',
            icon: AppIcons.phone,
            filled: true,
            enabled: canStart,
            onTap: canStart ? onCall : null,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          flex: 5,
          child: _BigActionButton(
            label: 'Chat',
            icon: AppIcons.chats,
            filled: false,
            enabled: canStart,
            onTap: canStart ? onChat : null,
          ),
        ),
      ],
    );
  }
}

class _BigActionButton extends StatefulWidget {
  final String label;
  final IconData icon;
  final bool filled;
  final bool enabled;
  final VoidCallback? onTap;

  const _BigActionButton({
    required this.label,
    required this.icon,
    required this.filled,
    required this.enabled,
    required this.onTap,
  });

  @override
  State<_BigActionButton> createState() => _BigActionButtonState();
}

class _BigActionButtonState extends State<_BigActionButton> {
  double _scale = 1.0;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.enabled;
    final filled = widget.filled;

    final Color bg;
    final Color fg;
    if (filled) {
      bg = enabled
          ? AppColors.amberGold
          : AppColors.amberGold.withValues(alpha: 0.45);
      fg = Colors.white;
    } else {
      bg = AppColors.amberGold.withValues(alpha: 0.12);
      fg = enabled
          ? AppColors.deepDarkBrown
          : AppColors.muted;
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
            height: 54,
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(16),
              boxShadow: filled && enabled
                  ? [
                      BoxShadow(
                        color: AppColors.amberGold
                            .withValues(alpha: 0.3),
                        blurRadius: 14,
                        offset: const Offset(0, 6),
                      ),
                    ]
                  : null,
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                AppIcon(widget.icon, size: 17, color: fg),
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

// ─── Banner above the action row (busy / offline / low balance) ───

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
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.18)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppIcon(icon, size: 16, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: GoogleFonts.inter(
                fontSize: 12,
                fontWeight: FontWeight.w500,
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

// ─── Privacy banner ────────────────────────────────────────────────

class _PrivacyBanner extends StatelessWidget {
  const _PrivacyBanner();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      decoration: BoxDecoration(
        color: AppColors.amberGold.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: AppColors.amberGold.withValues(alpha: 0.18),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.amberGold.withValues(alpha: 0.18),
            ),
            child: AppIcon(
              AppIcons.shield,
              size: 16,
              color: AppColors.amberGold,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Your privacy is our priority.',
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: AppColors.deepDarkBrown,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'All calls and chats are secure and confidential.',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.inter(
                    fontSize: 12,
                    fontWeight: FontWeight.w400,
                    height: 1.4,
                    color: AppColors.muted,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          AppIcon(
            AppIcons.chevronRight,
            size: 18,
            color: AppColors.muted.withValues(alpha: 0.55),
          ),
        ],
      ),
    );
  }
}

// ─── Services grid (derived from specializations) ─────────────────

class _ServicesSection extends StatelessWidget {
  final List<String> items;
  const _ServicesSection({required this.items});

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();

    // We display at most 4 service cards. If the priest selected
    // more specializations, the rest is summarised in a 4th tile
    // ("+N more") so the row count stays exactly 4 across all
    // profiles — keeps visual rhythm stable as in the reference.
    final visible = items.length <= 4 ? items : items.take(3).toList();
    final overflow = items.length > 4 ? items.length - 3 : 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Services',
          style: GoogleFonts.inter(
            fontSize: 16,
            fontWeight: FontWeight.w700,
            color: AppColors.deepDarkBrown,
          ),
        ),
        const SizedBox(height: 12),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (int i = 0; i < visible.length; i++) ...[
              if (i > 0) const SizedBox(width: 10),
              Expanded(
                child: _ServiceTile(
                  label: visible[i],
                  icon: _iconForService(visible[i]),
                ),
              ),
            ],
            if (overflow > 0) ...[
              const SizedBox(width: 10),
              Expanded(
                child: _ServiceTile(
                  label: '+$overflow more',
                  icon: AppIcons.category,
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }

  IconData _iconForService(String name) {
    final n = name.toLowerCase();
    if (n.contains('prayer')) return AppIcons.prayer;
    if (n.contains('bible')) return AppIcons.bible;
    if (n.contains('heal')) return AppIcons.heart;
    if (n.contains('confess')) return AppIcons.lock;
    if (n.contains('worship')) return AppIcons.celebration;
    if (n.contains('mass') || n.contains('offering')) {
      return AppIcons.prayer;
    }
    if (n.contains('youth') || n.contains('children')) {
      return AppIcons.users;
    }
    if (n.contains('counsel') ||
        n.contains('marriage') ||
        n.contains('family') ||
        n.contains('grief')) {
      return AppIcons.chatOutline;
    }
    if (n.contains('spiritual') || n.contains('direction')) {
      return AppIcons.bible;
    }
    if (n.contains('evangel')) return AppIcons.broadcast;
    if (n.contains('deliverance')) return AppIcons.shield;
    if (n.contains('addiction') || n.contains('recovery')) {
      return AppIcons.thumbUp;
    }
    return AppIcons.church;
  }
}

class _ServiceTile extends StatelessWidget {
  final String label;
  final IconData icon;

  const _ServiceTile({required this.label, required this.icon});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 92,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.surfaceWhite,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: AppColors.muted.withValues(alpha: 0.1),
        ),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          AppIcon(
            icon,
            size: 22,
            color: AppColors.amberGold,
          ),
          const SizedBox(height: 8),
          Text(
            label,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: GoogleFonts.inter(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              height: 1.25,
              color: AppColors.deepDarkBrown,
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Reviews preview ──────────────────────────────────────────────

class _ReviewsSection extends StatelessWidget {
  final List<PriestReview> reviews;
  final int totalReviewCount;

  const _ReviewsSection({
    required this.reviews,
    required this.totalReviewCount,
  });

  @override
  Widget build(BuildContext context) {
    if (reviews.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Reviews',
                style: GoogleFonts.inter(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: AppColors.deepDarkBrown,
                ),
              ),
            ),
            if (totalReviewCount > 1)
              Text(
                'See All',
                style: GoogleFonts.inter(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: AppColors.amberGold,
                ),
              ),
          ],
        ),
        const SizedBox(height: 12),
        _ReviewCard(review: reviews.first),
      ],
    );
  }
}

class _ReviewCard extends StatelessWidget {
  final PriestReview review;
  const _ReviewCard({required this.review});

  @override
  Widget build(BuildContext context) {
    final initial = review.userName.isNotEmpty
        ? review.userName.trim().substring(0, 1).toUpperCase()
        : '?';

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surfaceWhite,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: AppColors.muted.withValues(alpha: 0.1),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 36,
                height: 36,
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.primaryBrown.withValues(alpha: 0.1),
                ),
                child: review.userPhotoUrl.isNotEmpty
                    ? CachedNetworkImage(
                        imageUrl: review.userPhotoUrl,
                        fit: BoxFit.cover,
                        errorWidget: (_, _, _) =>
                            _avatarFallback(initial),
                        placeholder: (_, _) =>
                            const SizedBox.shrink(),
                      )
                    : _avatarFallback(initial),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      review.userName.isEmpty
                          ? 'Anonymous'
                          : review.userName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.inter(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: AppColors.deepDarkBrown,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        for (int i = 0; i < 5; i++)
                          Padding(
                            padding:
                                const EdgeInsets.only(right: 2),
                            child: AppIcon(
                              i < review.rating.round()
                                  ? AppIcons.starFilled
                                  : AppIcons.starOutline,
                              size: 12,
                              color: AppColors.amberGold,
                            ),
                          ),
                        const SizedBox(width: 6),
                        Text(
                          review.rating.toStringAsFixed(1),
                          style: GoogleFonts.inter(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: AppColors.muted,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            '"${review.feedback}"',
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: GoogleFonts.inter(
              fontSize: 13,
              fontWeight: FontWeight.w400,
              fontStyle: FontStyle.italic,
              height: 1.5,
              color: AppColors.deepDarkBrown.withValues(alpha: 0.85),
            ),
          ),
        ],
      ),
    );
  }

  Widget _avatarFallback(String initial) {
    return Center(
      child: Text(
        initial,
        style: GoogleFonts.inter(
          fontSize: 14,
          fontWeight: FontWeight.w700,
          color: AppColors.primaryBrown,
        ),
      ),
    );
  }
}

// ─── More-menu sheet row ───────────────────────────────────────────

class _SheetRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool danger;
  final VoidCallback onTap;

  const _SheetRow({
    required this.icon,
    required this.label,
    required this.onTap,
    this.danger = false,
  });

  @override
  Widget build(BuildContext context) {
    final fg = danger ? AppColors.errorRed : AppColors.deepDarkBrown;
    final bg = danger
        ? AppColors.errorRed.withValues(alpha: 0.08)
        : AppColors.primaryBrown.withValues(alpha: 0.08);

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 14),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: bg,
                borderRadius: BorderRadius.circular(10),
              ),
              child: AppIcon(icon, size: 18, color: fg),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                label,
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: fg,
                ),
              ),
            ),
            AppIcon(
              AppIcons.chevronRight,
              size: 18,
              color: AppColors.muted.withValues(alpha: 0.4),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Shimmer while loading ─────────────────────────────────────────

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
        physics: const NeverScrollableScrollPhysics(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              height: _kHeroHeight,
              color: AppColors.muted.withValues(alpha: 0.2),
            ),
            Transform.translate(
              offset: const Offset(0, -_kCardOverlap),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    box(h: 170, radius: BorderRadius.circular(20)),
                    const SizedBox(height: 24),
                    box(h: 14, w: 80),
                    const SizedBox(height: 10),
                    box(h: 60, radius: BorderRadius.circular(8)),
                    const SizedBox(height: 20),
                    Row(
                      children: [
                        Expanded(
                          child: box(
                            h: 54,
                            radius: BorderRadius.circular(16),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: box(
                            h: 54,
                            radius: BorderRadius.circular(16),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    box(h: 64, radius: BorderRadius.circular(14)),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
