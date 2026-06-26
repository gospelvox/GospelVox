// Priest profile, viewed by a USER who is deciding whether to open a
// session. Distinct from the priest's own PriestMyProfilePage and from
// the admin SpeakerDetailPage — different actions, different chrome.
//
// Scroll architecture: CustomScrollView with the hero photo as a
// regular sliver so it scrolls *out of view* when the user pulls up.
// The earlier draft pinned the hero outside the scroll view, which
// permanently consumed half the screen — fixed here.
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
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shimmer/shimmer.dart';

import 'package:gospel_vox/core/services/injection_container.dart';
import 'package:gospel_vox/core/theme/app_colors.dart';
import 'package:gospel_vox/core/widgets/app_back_button.dart';
import 'package:gospel_vox/core/widgets/app_icons.dart';
import 'package:gospel_vox/core/widgets/app_snackbar.dart';
import 'package:gospel_vox/features/admin/speakers/data/speaker_model.dart';
import 'package:gospel_vox/features/shared/data/session_preflight.dart';
import 'package:gospel_vox/features/shared/widgets/session_participant_menu.dart';
import 'package:gospel_vox/features/user/home/data/home_repository.dart';

// Three URLs go into every share message:
//
//   • Custom scheme — active deep link, handled by DeepLinkService
//     when the recipient has the app installed. WhatsApp / Telegram
//     / iMessage all auto-link non-http schemes when they look like
//     URLs.
//   • https://gospelvox.app/priest/<uid> — placeholder universal
//     link. Won't open the app until the domain is set up with
//     assetlinks.json / apple-app-site-association, but ships now
//     as a forward-compatible URL the share preview can render.
//   • Play Store — install fallback for recipients without the app.
const String _kPlayStoreUrl =
    'https://play.google.com/store/apps/details?id=com.gospelvox.gospel_vox';
const String _kProfileWebPathRoot = 'https://gospelvox.app/priest/';
const String _kProfileDeepLinkRoot = 'gospelvox://priest/';

// Hero geometry. Hero takes ~30% of the screen (clamped so it stays
// readable on small phones and not absurd on tablets). The card
// overlaps the bottom of the hero by [_kCardOverlap] to recreate the
// "floating card on top of the photo" look from the reference.
const double _kHeroFactor = 0.30;
const double _kHeroMin = 230;
const double _kHeroMax = 300;
const double _kCardOverlap = 40;

// Plum accent for the "In Bible Session" pill and reason banner.
// Same hue as PriestCard's bibleAccent so the two surfaces stay
// visually consistent when a user navigates from the home feed to
// the priest profile. File-level (not class-private) so both the
// availability pill and the reason banner can share it.
const Color _kBibleAccent = AppColors.bibleBusy;

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
        _repo.getRecentReviews(widget.priestId),
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
  // deficit copy (AstroTalk pattern).
  bool get _canStart =>
      _priest != null && _priest!.isAvailable;

  double _heroHeight(BuildContext context) {
    final h = MediaQuery.of(context).size.height * _kHeroFactor;
    return h.clamp(_kHeroMin, _kHeroMax);
  }

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

  // Native share-sheet flow for the priest profile. Builds a rich
  // text card with the priest's headline + bio + a deep link and a
  // Play Store fallback, then attempts to attach the priest's photo
  // so the receiving app (WhatsApp, Mail, Telegram, etc.) renders a
  // real image preview rather than a bare URL.
  //
  // Two layers of defence:
  //   • Photo attach is best-effort; if the cache fetch fails we
  //     fall through to text-only share.
  //   • If share_plus itself throws (e.g. the running build doesn't
  //     yet include the native plugin), we copy the share text to
  //     the clipboard and surface a toast so the user can paste it
  //     into any chat manually — the share button is never a
  //     dead-tap.
  Future<void> _sharePriest() async {
    final priest = _priest;
    if (priest == null) return;
    HapticFeedback.lightImpact();

    final shareText = _buildShareText(priest);
    // Sheet's `subject` only matters for share targets that read it
    // (Gmail, Outlook, Bluetooth). Most chat apps ignore it.
    final subject = 'Connect with ${priest.fullName} on Gospel Vox';

    try {
      final share = SharePlus.instance;

      if (priest.hasPhoto) {
        try {
          final file = await DefaultCacheManager()
              .getSingleFile(priest.photoUrl)
              .timeout(const Duration(seconds: 6));
          await share.share(
            ShareParams(
              text: shareText,
              subject: subject,
              files: [XFile(file.path, mimeType: 'image/jpeg')],
            ),
          );
          return;
        } catch (e) {
          debugPrint('[share] photo path failed, retrying text-only: $e');
        }
      }

      await share.share(
        ShareParams(text: shareText, subject: subject),
      );
    } catch (e) {
      // share_plus failed entirely (typically MissingPluginException
      // when the running binary was built before the package was
      // added — a full rebuild fixes that). Fall back to clipboard
      // so the user can still spread the link manually.
      debugPrint('[share] failed, falling back to clipboard: $e');
      await Clipboard.setData(ClipboardData(text: shareText));
      if (!mounted) return;
      AppSnackBar.success(
        context,
        'Profile link copied — paste anywhere to share.',
      );
    }
  }

  // Hand-crafted share copy. Designed to read like a personal
  // recommendation (not a marketing blurb) so the recipient knows
  // *why* they're being sent this priest — what's noteworthy about
  // them, what they specialise in, where to download the app.
  String _buildShareText(SpeakerModel priest) {
    final out = StringBuffer();

    out.writeln('🙏 Meet ${_displayName(priest)} on Gospel Vox');
    out.writeln();

    // Headline line: denomination + years of experience.
    final headlineParts = <String>[];
    if (priest.denomination.isNotEmpty) {
      headlineParts.add('${priest.denomination} Priest');
    }
    if (priest.yearsOfExperience > 0) {
      headlineParts.add('${priest.yearsOfExperience}+ years');
    }
    if (headlineParts.isNotEmpty) {
      out.writeln(headlineParts.join(' · '));
    }

    if (priest.rating > 0 && priest.reviewCount > 0) {
      out.writeln(
        '⭐ ${priest.rating.toStringAsFixed(1)} '
        '(${priest.reviewCount} ${priest.reviewCount == 1 ? "review" : "reviews"})',
      );
    }

    final loc = [priest.churchName, priest.location]
        .where((s) => s.isNotEmpty)
        .join(', ');
    if (loc.isNotEmpty) {
      out.writeln('📍 $loc');
    }

    // Pull-quote from the bio. Caps to ~180 chars so the share
    // preview on WhatsApp/iMessage doesn't get truncated mid-word.
    final bio = priest.bio.trim();
    if (bio.isNotEmpty) {
      final short = bio.length > 180
          ? '${bio.substring(0, 177).trimRight()}…'
          : bio;
      out.writeln();
      out.writeln('"$short"');
    }

    if (priest.specializations.isNotEmpty) {
      final top = priest.specializations.take(4).join(' · ');
      out.writeln();
      out.writeln('🕯 $top');
    }

    out.writeln();
    out.writeln(
      'Have a private, confidential chat or voice call — '
      'wherever you are.',
    );

    out.writeln();
    out.writeln('👉 Open in Gospel Vox (if installed):');
    out.writeln('$_kProfileDeepLinkRoot${priest.uid}');
    out.writeln();
    out.writeln("📲 Don't have the app? Get it here:");
    out.writeln(_kPlayStoreUrl);
    out.writeln();
    // Forward-compatible web URL — once gospelvox.app is set up with
    // App Links / Universal Links, this becomes the canonical share
    // URL and the recipient won't even need the gospelvox:// hint.
    out.writeln('Web: $_kProfileWebPathRoot${priest.uid}');

    return out.toString();
  }

  // "Fr. Thomas Mathew" reads more naturally than "Father Mathew"
  // or just "Thomas". We keep the whole name as stored — priests
  // self-register with the title they want displayed.
  String _displayName(SpeakerModel priest) {
    return priest.fullName.trim().isEmpty
        ? 'this speaker'
        : priest.fullName.trim();
  }

  @override
  Widget build(BuildContext context) {
    // Light status-bar icons over the hero — the photo can be dark or
    // bright, and white-on-photo reads everywhere; the warm cream
    // page background underneath also tolerates light icons fine.
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        statusBarBrightness: Brightness.dark,
      ),
      child: Scaffold(
        backgroundColor: AppColors.background,
        extendBodyBehindAppBar: true,
        body: _buildBody(),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) return _ProfileShimmer(heroHeight: _heroHeight(context));

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
    final mq = MediaQuery.of(context);
    final topInset = mq.padding.top;
    final bottomInset = mq.padding.bottom;
    final heroHeight = _heroHeight(context);

    return Stack(
      children: [
        // Plain SingleChildScrollView (was CustomScrollView previously
        // — switched after a LayoutBuilder-inside-sliver render crash:
        // the simpler box-only widget tree avoids that path entirely
        // and the scroll behavior is identical for this single-axis
        // page).
        //
        // Wrapped in RefreshIndicator so the empty-state's "pull down
        // to refresh" instruction is real, not a UX lie. Re-runs the
        // same load() that initState kicks off.
        RefreshIndicator(
          onRefresh: _load,
          color: AppColors.amberGold,
          backgroundColor: AppColors.surfaceWhite,
          child: SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(
              parent: BouncingScrollPhysics(),
            ),
            child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Hero photo + availability pill — sized to ~30% of
              // viewport so it doesn't dominate the page.
              SizedBox(
                height: heroHeight,
                child: Stack(
                  children: [
                    Positioned.fill(child: _HeroPhoto(priest: priest)),
                    Positioned(
                      bottom: _kCardOverlap + 14,
                      left: 20,
                      child: _AvailabilityPill(priest: priest),
                    ),
                  ],
                ),
              ),
              // Card + rest of page; Transform pulls the content up
              // so the card's top edge overlaps the photo's bottom
              // edge — recreates the floating-card effect.
              Transform.translate(
                offset: const Offset(0, -_kCardOverlap),
                child: Padding(
                  padding: EdgeInsets.fromLTRB(
                    16,
                    0,
                    16,
                    bottomInset + 24,
                  ),
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
            ],
          ),
          ),
        ),

        // Floating action chips — pinned over the scroll so they stay
        // reachable even after the hero has scrolled away.
        Positioned(
          top: topInset + 8,
          left: 16,
          child: const AppBackButton(),
        ),
        Positioned(
          top: topInset + 8,
          right: 16,
          child: Row(
            children: [
              _CircleIconButton(
                icon: AppIcons.share,
                onTap: _sharePriest,
              ),
              const SizedBox(width: 8),
              _CircleIconButton(
                icon: AppIcons.more,
                onTap: _showMoreActions,
              ),
            ],
          ),
        ),
      ],
    );
  }

  // Overflow menu — houses Report + Block. Lives in a sheet (not a
  // popup menu) for thumb-reachability on tall phones and to give the
  // destructive action enough breathing room. Report reuses the shared
  // in-session report flow (showReportSpeakerSheet) so the picker and
  // the reports/{id} write are identical to the in-call surface.
  Future<void> _showMoreActions() async {
    final priest = _priest;
    if (priest == null) return;
    HapticFeedback.lightImpact();

    final action = await showModalBottomSheet<_ProfileAction>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => const _ProfileActionsSheet(),
    );

    if (!mounted || action == null) return;
    if (action == _ProfileAction.report) {
      await _reportSpeaker(priest);
    } else if (action == _ProfileAction.block) {
      await _confirmAndBlock(priest);
    }
  }

  // Opens the shared report-reason sheet (same picker + reports/{id}
  // write the in-session ⋮ menu uses, just with no sessionId). This is
  // the generic "Report speaker" entry the profile previously deferred.
  Future<void> _reportSpeaker(SpeakerModel priest) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      AppSnackBar.error(context, 'Please sign in again to report.');
      return;
    }
    await showReportSpeakerSheet(
      context,
      priestId: priest.uid,
      priestName: _displayName(priest),
      reporterUserId: uid,
      reporterName: FirebaseAuth.instance.currentUser?.displayName ?? '',
    );
  }

  // Confirm sheet + write. We're deliberately strict — Block is
  // irreversible without finding the priest again in Settings, so the
  // user has to actively confirm. The write itself is idempotent
  // (arrayUnion no-ops if already blocked) so a tap that gets retried
  // by network can't corrupt state.
  Future<void> _confirmAndBlock(SpeakerModel priest) async {
    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => _ConfirmBlockSheet(priestName: _displayName(priest)),
    );
    if (!mounted || confirmed != true) return;

    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      AppSnackBar.error(context, 'Please sign in again to block.');
      return;
    }

    try {
      await _repo.setPriestBlocked(
        userId: uid,
        priestId: priest.uid,
        blocked: true,
      );
      if (!mounted) return;
      AppSnackBar.success(
        context,
        '${_displayName(priest)} has been blocked.',
      );
      // Pop back to the feed — the blocked priest will have already
      // vanished from the list by the time this frame lands, because
      // HomeCubit's blocked-id stream fired in parallel.
      context.pop();
    } catch (_) {
      if (!mounted) return;
      AppSnackBar.error(context, 'Could not block. Please try again.');
    }
  }
}

enum _ProfileAction { report, block }

class _ProfileActionsSheet extends StatelessWidget {
  const _ProfileActionsSheet();

  @override
  Widget build(BuildContext context) {
    final bottomPad = MediaQuery.of(context).padding.bottom;
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.surfaceWhite,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: EdgeInsets.fromLTRB(20, 12, 20, bottomPad + 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: AppColors.muted.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 16),
          _SheetActionRow(
            icon: AppIcons.report,
            label: 'Report speaker',
            destructive: false,
            onTap: () => Navigator.of(context).pop(_ProfileAction.report),
          ),
          _SheetActionRow(
            icon: AppIcons.block,
            label: 'Block speaker',
            destructive: true,
            onTap: () => Navigator.of(context).pop(_ProfileAction.block),
          ),
        ],
      ),
    );
  }
}

class _SheetActionRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool destructive;
  final VoidCallback onTap;

  const _SheetActionRow({
    required this.icon,
    required this.label,
    required this.onTap,
    this.destructive = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = destructive ? AppColors.errorRed : AppColors.deepDarkBrown;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 14),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(10),
              ),
              alignment: Alignment.center,
              child: AppIcon(icon, size: 18, color: color),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                label,
                style: GoogleFonts.inter(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: color,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ConfirmBlockSheet extends StatelessWidget {
  final String priestName;
  const _ConfirmBlockSheet({required this.priestName});

  @override
  Widget build(BuildContext context) {
    final bottomPad = MediaQuery.of(context).padding.bottom;
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.surfaceWhite,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: EdgeInsets.fromLTRB(24, 12, 24, bottomPad + 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.muted.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 18),
          Center(
            child: Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.errorRed.withValues(alpha: 0.08),
              ),
              alignment: Alignment.center,
              child: AppIcon(
                AppIcons.block,
                size: 28,
                color: AppColors.errorRed,
              ),
            ),
          ),
          const SizedBox(height: 16),
          Center(
            child: Text(
              'Block $priestName?',
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: AppColors.deepDarkBrown,
              ),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            "They'll no longer appear in your feed, and you won't "
            "be able to start sessions with them. You can unblock "
            "anytime from Settings.",
            style: GoogleFonts.inter(
              fontSize: 13,
              fontWeight: FontWeight.w400,
              color: AppColors.muted,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 24),
          Row(
            children: [
              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => Navigator.of(context).pop(false),
                  child: Container(
                    height: 48,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: AppColors.surfaceWhite,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: AppColors.muted.withValues(alpha: 0.2),
                      ),
                    ),
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
                  onTap: () => Navigator.of(context).pop(true),
                  child: Container(
                    height: 48,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: AppColors.errorRed,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      'Block',
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
        // Vignettes: top one keeps the back/more buttons + status bar
        // icons readable on bright photos; bottom one helps the
        // availability pill read against busy regions.
        IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  AppColors.deepDarkBrown.withValues(alpha: 0.22),
                  Colors.transparent,
                  Colors.transparent,
                  AppColors.deepDarkBrown.withValues(alpha: 0.18),
                ],
                stops: const [0.0, 0.28, 0.7, 1.0],
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
            fontSize: 72,
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
          boxShadow: kWarmCardShadow,
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

// ─── Availability pill (sits over the hero, scrolls with it) ──────

class _AvailabilityPill extends StatelessWidget {
  final SpeakerModel priest;
  const _AvailabilityPill({required this.priest});

  @override
  Widget build(BuildContext context) {
    final (label, color) = _spec(priest);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: AppColors.surfaceWhite,
        borderRadius: BorderRadius.circular(16),
        boxShadow: kWarmCardShadow,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: GoogleFonts.inter(
              fontSize: 10.5,
              fontWeight: FontWeight.w600,
              color: AppColors.deepDarkBrown,
            ),
          ),
        ],
      ),
    );
  }

  (String, Color) _spec(SpeakerModel p) {
    // In-bible-session takes precedence over every other state —
    // a priest mid-Meet should never show "Available" or "Busy"
    // even if they were technically in a chat moments ago.
    if (p.isInBibleSession) return ('In Bible Session', _kBibleAccent);
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
    // Precedence: in-bible-session > busy > offline > low-balance.
    // A priest physically teaching a Bible session should NEVER
    // be misrepresented as just "Busy" — the copy and the icon
    // tell the user when to come back. The low-balance banner is
    // suppressed in all three unavailable states because the user
    // can't start a session anyway, so adding "you also don't have
    // enough coins" would be noise.
    final showInBible = priest.isInBibleSession;
    final showBusy = !showInBible && priest.isOnline && priest.isBusy;
    final showOffline = !showInBible && !priest.isOnline;
    final showLowBalance =
        !showInBible && !showBusy && !showOffline && balance < minCost;
    final hasSpec = priest.specializations.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _ProfileCard(priest: priest),
        const SizedBox(height: 20),
        if (priest.bio.trim().isNotEmpty) ...[
          _AboutSection(bio: priest.bio),
          const SizedBox(height: 16),
        ],
        if (showInBible)
          _ReasonBanner(
            icon: AppIcons.bible,
            text: '${priest.fullName.isEmpty ? "This speaker" : priest.fullName}'
                ' is teaching a Bible session right now. '
                'Please try again once the session ends.',
            color: _kBibleAccent,
          )
        else if (showBusy)
          const _ReasonBanner(
            icon: AppIcons.pause,
            text: 'This speaker is online but has paused new requests. '
                'Come back in a little while.',
            color: AppColors.amberGold,
          )
        else if (showOffline)
          const _ReasonBanner(
            icon: AppIcons.cloudOff,
            text: "This speaker is offline right now. Check back once "
                "they're available.",
            color: AppColors.muted,
          )
        else if (showLowBalance)
          _ReasonBanner(
            icon: AppIcons.info,
            text:
                'You need at least $minCost coins for a session. Tap '
                'a button to add coins now.',
            color: AppColors.terraCotta,
          ),
        if (showInBible || showBusy || showOffline || showLowBalance)
          const SizedBox(height: 12),
        _ActionRow(
          canStart: canStart,
          onCall: onCall,
          onChat: onChat,
        ),
        if (hasSpec) ...[
          const SizedBox(height: 24),
          _SpecializationSection(items: priest.specializations),
        ],
        const SizedBox(height: 24),
        _ReviewsSection(
          reviews: reviews,
          reviewCount: priest.reviewCount,
          priestName: priest.fullName,
          priestPhotoUrl: priest.photoUrl,
        ),
        // Privacy line sits at the very bottom of the page as a quiet
        // trust footer — small, single line, no chevron. Previously it
        // was a chunky banner near the top which competed with the
        // primary call-to-action.
        const SizedBox(height: 22),
        const _PrivacyFooter(),
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
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 16),
      decoration: BoxDecoration(
        color: AppColors.surfaceWhite,
        borderRadius: BorderRadius.circular(AppRadius.large),
        boxShadow: kWarmCardShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _DenominationTile(),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Name fills the left; community role sits at the
                    // far-right END of the row. Both are wrapped in a
                    // FittedBox(scaleDown) so when either string is long
                    // it SHRINKS its own font to fit instead of clipping
                    // with an ellipsis — and if both are long they each
                    // shrink within their share, so neither overflows the
                    // card. The name (Expanded) takes the leftover width
                    // and so pushes the role to the right edge; the role
                    // is capped so it can never crowd the name out.
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Expanded(
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: Alignment.centerLeft,
                            child: Text(
                              priest.fullName.isEmpty
                                  ? 'Speaker'
                                  : priest.fullName,
                              maxLines: 1,
                              style: GoogleFonts.inter(
                                fontSize: 18,
                                fontWeight: FontWeight.w700,
                                height: 1.2,
                                color: AppColors.deepDarkBrown,
                              ),
                            ),
                          ),
                        ),
                        if (priest.communityRole.isNotEmpty) ...[
                          const SizedBox(width: 8),
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 150),
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              alignment: Alignment.centerRight,
                              child: Text(
                                priest.communityRole,
                                maxLines: 1,
                                style: GoogleFonts.inter(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: AppColors.primaryBrown,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      priest.denomination.isEmpty
                          ? '—'
                          : '${priest.denomination} Priest',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.inter(
                        fontSize: 12,
                        fontWeight: FontWeight.w400,
                        color: AppColors.muted,
                      ),
                    ),
                    const SizedBox(height: 8),
                    _RatingVerifiedRow(priest: priest),
                  ],
                ),
              ),
            ],
          ),
          if (_hasAnyStat(priest)) ...[
            const SizedBox(height: 14),
            Container(
              height: 1,
              color: AppColors.borderLight,
            ),
            const SizedBox(height: 12),
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
                const _CellDivider(),
                Expanded(
                  child: _StatCell(
                    icon: AppIcons.calendar,
                    primary: priest.yearsOfExperience > 0
                        ? '${priest.yearsOfExperience}+ Years'
                        : 'New',
                    secondary: 'Experience',
                  ),
                ),
                const _CellDivider(),
                Expanded(
                  child: _LanguagesStatCell(
                    languages: priest.languages,
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
  const _DenominationTile();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 46,
      height: 54,
      decoration: BoxDecoration(
        color: AppColors.primaryBrown.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
      ),
      child: AppIcon(
        AppIcons.church,
        size: 22,
        color: AppColors.primaryBrown,
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
            size: 13,
            color: AppColors.amberGold,
          ),
          const SizedBox(width: 4),
          Text(
            priest.rating.toStringAsFixed(1),
            style: GoogleFonts.inter(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: AppColors.deepDarkBrown,
            ),
          ),
          const SizedBox(width: 3),
          Text(
            '(${priest.reviewCount})',
            style: GoogleFonts.inter(
              fontSize: 11,
              fontWeight: FontWeight.w400,
              color: AppColors.muted,
            ),
          ),
        ],
        if (hasRating && isVerified) ...[
          const SizedBox(width: 8),
          Container(
            width: 1,
            height: 11,
            color: AppColors.muted.withValues(alpha: 0.25),
          ),
          const SizedBox(width: 8),
        ],
        if (isVerified) ...[
          AppIcon(
            AppIcons.shield,
            size: 12,
            color: AppColors.amberGold,
          ),
          const SizedBox(width: 3),
          Text(
            'Verified',
            style: GoogleFonts.inter(
              fontSize: 11,
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

  const _StatCell({
    required this.icon,
    required this.primary,
    required this.secondary,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 30,
          height: 30,
          decoration: BoxDecoration(
            color: AppColors.warmBeige,
            borderRadius: BorderRadius.circular(8),
          ),
          child: AppIcon(
            icon,
            size: 14,
            color: AppColors.primaryBrown,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          primary,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          softWrap: true,
          textAlign: TextAlign.center,
          style: GoogleFonts.inter(
            fontSize: 11.5,
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
              fontSize: 10.5,
              fontWeight: FontWeight.w400,
              height: 1.25,
              color: AppColors.muted,
            ),
          ),
        ],
      ],
    );
  }
}

class _CellDivider extends StatelessWidget {
  const _CellDivider();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Container(
        width: 1,
        height: 30,
        color: AppColors.borderLight,
      ),
    );
  }
}

// ─── About (with Read More / Show Less, 2-line collapse) ──────────

class _AboutSection extends StatefulWidget {
  final String bio;
  const _AboutSection({required this.bio});

  @override
  State<_AboutSection> createState() => _AboutSectionState();
}

class _AboutSectionState extends State<_AboutSection> {
  bool _expanded = false;
  // 2 lines collapsed — the reference image shows the bio compact;
  // longer bios reveal via Read More.
  static const int _collapsedLines = 2;
  // Rough character cap that maps to "more than 2 lines at the
  // current font size on a typical phone width". Length heuristic
  // replaces the LayoutBuilder + TextPainter measurement we used to
  // do — that path was crashing under some constraint combinations.
  // The heuristic over-shows Read More on edge cases (e.g. a single
  // word that's 100 chars long) but never under-shows.
  static const int _overflowCharThreshold = 110;

  @override
  Widget build(BuildContext context) {
    final bio = widget.bio.trim();
    final style = GoogleFonts.inter(
      fontSize: 13.5,
      fontWeight: FontWeight.w400,
      height: 1.55,
      color: AppColors.deepDarkBrown.withValues(alpha: 0.88),
    );
    final overflows = bio.length > _overflowCharThreshold;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'About',
          style: GoogleFonts.inter(
            fontSize: 15,
            fontWeight: FontWeight.w700,
            color: AppColors.deepDarkBrown,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          bio,
          maxLines: _expanded ? null : _collapsedLines,
          overflow:
              _expanded ? TextOverflow.visible : TextOverflow.ellipsis,
          style: style,
        ),
        if (overflows) ...[
          const SizedBox(height: 6),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(() => _expanded = !_expanded),
            child: Text(
              _expanded ? 'Show Less' : 'Read More',
              style: GoogleFonts.inter(
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
                color: AppColors.amberGold,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

// ─── Action row (Call Now + Chat) ─────────────────────────────────

class _ActionRow extends StatelessWidget {
  final bool canStart;
  final VoidCallback onCall;
  final VoidCallback onChat;

  const _ActionRow({
    required this.canStart,
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
        const SizedBox(width: 10),
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

    // Call Now (filled) is the deep brown brand primary — gives a
    // strong, premium contrast against the gold accents elsewhere on
    // the page. Chat (outlined) is a single brown hairline border
    // with no fill, so it reads as the clearly-secondary action.
    final Color bg;
    final Color fg;
    final BoxBorder? border;
    if (filled) {
      bg = enabled
          ? AppColors.primaryBrown
          : AppColors.primaryBrown.withValues(alpha: 0.4);
      fg = Colors.white;
      border = null;
    } else {
      bg = AppColors.surfaceWhite;
      fg = enabled
          ? AppColors.primaryBrown
          : AppColors.muted;
      border = Border.all(
        color: enabled
            ? AppColors.primaryBrown.withValues(alpha: 0.5)
            : AppColors.muted.withValues(alpha: 0.25),
        width: 1.2,
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
            height: 50,
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(AppRadius.medium),
              border: border,
              boxShadow: filled && enabled
                  ? [
                      BoxShadow(
                        color: AppColors.primaryBrown
                            .withValues(alpha: 0.28),
                        blurRadius: 12,
                        offset: const Offset(0, 5),
                      ),
                    ]
                  : null,
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                AppIcon(widget.icon, size: 16, color: fg),
                const SizedBox(width: 8),
                Text(
                  widget.label,
                  style: GoogleFonts.inter(
                    fontSize: 13.5,
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
        borderRadius: BorderRadius.circular(AppRadius.small),
        border: Border.all(color: color.withValues(alpha: 0.18)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppIcon(icon, size: 15, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: GoogleFonts.inter(
                fontSize: 11.5,
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

// ─── Privacy footer (compact, page-end trust note) ────────────────

class _PrivacyFooter extends StatelessWidget {
  const _PrivacyFooter();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          AppIcon(
            AppIcons.shield,
            size: 12,
            color: AppColors.muted.withValues(alpha: 0.7),
          ),
          const SizedBox(width: 6),
          Text(
            'Your privacy is our priority — all calls are secure',
            style: GoogleFonts.inter(
              fontSize: 11,
              fontWeight: FontWeight.w500,
              color: AppColors.muted,
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Specialization (wrap of icon pills, ALL items always visible) ──
//
// Replaces the horizontal-scroll-cards design after user feedback
// that scrolling sideways hid items. Now every specialization
// renders as a small icon + label pill, and the row wraps onto as
// many lines as needed — no scrolling, no "+N more" overflow, the
// full list is visible in a single glance.
//
// Pill aesthetic (icon-leading) over a plain chip because the priest
// profile is already text-heavy by the time the user gets here; the
// gold mini-icons give the section a quick visual rhythm so users
// can scan by symbol instead of reading every label.

class _SpecializationSection extends StatelessWidget {
  final List<String> items;
  const _SpecializationSection({required this.items});

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Specialization',
          style: GoogleFonts.inter(
            fontSize: 15,
            fontWeight: FontWeight.w700,
            color: AppColors.deepDarkBrown,
          ),
        ),
        const SizedBox(height: 12),
        // Wrap auto-flows pills onto new rows as the list grows; each
        // pill is intrinsic-width so a long label like "Children's
        // Ministry" doesn't force the whole row to that width.
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final item in items)
              _SpecializationChip(
                label: item,
                icon: _iconForSpec(item),
              ),
          ],
        ),
      ],
    );
  }

  IconData _iconForSpec(String name) {
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

// Compact icon-leading pill. Renders one specialization per chip; a
// row of these wraps onto new lines as the list grows.
class _SpecializationChip extends StatelessWidget {
  final String label;
  final IconData icon;

  const _SpecializationChip({
    required this.label,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 6, 12, 6),
      decoration: BoxDecoration(
        color: AppColors.surfaceWhite,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: AppColors.primaryBrown.withValues(alpha: 0.2),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Small brown disc behind the icon — the visual anchor that
          // separates this from a plain text chip. Keeps the pill
          // reading as "feature" rather than "tag".
          Container(
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.primaryBrown.withValues(alpha: 0.1),
            ),
            child: AppIcon(
              icon,
              size: 12,
              color: AppColors.primaryBrown,
            ),
          ),
          const SizedBox(width: 7),
          Text(
            label,
            style: GoogleFonts.inter(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: AppColors.deepDarkBrown,
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Languages stat cell (capped, tappable "+N more") ─────────────

// Sits in the stat row beside Church / Experience. Shows the first
// language plus a "+N" overflow badge so the cell stays a single line
// and the card height never grows with the list. Tapping opens a sheet
// listing every language as pills.
class _LanguagesStatCell extends StatelessWidget {
  final List<String> languages;
  const _LanguagesStatCell({required this.languages});

  @override
  Widget build(BuildContext context) {
    final hasLangs = languages.isNotEmpty;
    final first = hasLangs ? languages.first : 'Languages';
    // Everything past the first name collapses into the "+N" badge.
    final extra = languages.length - 1;

    final cell = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 30,
          height: 30,
          decoration: BoxDecoration(
            color: AppColors.warmBeige,
            borderRadius: BorderRadius.circular(8),
          ),
          child: AppIcon(
            AppIcons.podcast,
            size: 14,
            color: AppColors.primaryBrown,
          ),
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Flexible(
              child: Text(
                first,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: GoogleFonts.inter(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  height: 1.3,
                  color: AppColors.deepDarkBrown,
                ),
              ),
            ),
            if (extra > 0) ...[
              const SizedBox(width: 5),
              // Filled brown badge so the overflow reads as a tappable
              // control, not just dim text.
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: AppColors.primaryBrown,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  '+$extra',
                  style: GoogleFonts.inter(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    height: 1.1,
                    color: Colors.white,
                  ),
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 3),
        // Sub-label doubles as the affordance: when there's a "+N",
        // it tells the user the cell is tappable.
        Text(
          extra > 0 ? 'Tap to view all' : 'Languages',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: GoogleFonts.inter(
            fontSize: 10.5,
            fontWeight: extra > 0 ? FontWeight.w600 : FontWeight.w400,
            height: 1.25,
            color: extra > 0 ? AppColors.primaryBrown : AppColors.muted,
          ),
        ),
      ],
    );

    // Only tappable when there's something hidden behind the "+N".
    if (extra <= 0) return cell;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _showAllLanguages(context, languages),
      child: cell,
    );
  }
}

// Bottom sheet listing every language as wrapping pills. Reached by
// tapping the "+N" overflow badge on the languages stat cell.
void _showAllLanguages(BuildContext context, List<String> languages) {
  showModalBottomSheet<void>(
    context: context,
    backgroundColor: AppColors.surfaceWhite,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) {
      final bottomInset = MediaQuery.of(ctx).padding.bottom;
      return Padding(
        padding: EdgeInsets.fromLTRB(20, 14, 20, bottomInset + 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.muted.withValues(alpha: 0.25),
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Languages',
              style: GoogleFonts.inter(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: AppColors.deepDarkBrown,
              ),
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final l in languages) _LanguageChip(label: l),
              ],
            ),
          ],
        ),
      );
    },
  );
}

class _LanguageChip extends StatelessWidget {
  final String label;
  const _LanguageChip({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: AppColors.warmBeige,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: AppColors.primaryBrown.withValues(alpha: 0.15),
        ),
      ),
      child: Text(
        label,
        style: GoogleFonts.inter(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: AppColors.deepDarkBrown,
        ),
      ),
    );
  }
}

// ─── Reviews (preview 3 + "Show all N reviews" toggle) ────────────

class _ReviewsSection extends StatefulWidget {
  final List<PriestReview> reviews;
  // Aggregate count from priests/{id}.reviewCount. Lets us tell
  // apart "no reviews exist" (count == 0, hide the whole section)
  // from "reviews exist but the recentReviews array hasn't been
  // populated yet" (count > 0 but list empty — show an empty state
  // so the user understands why it's blank).
  final int reviewCount;
  // Threaded down to each review card so the priest's reply bubble
  // can attribute itself ("Fr. Thomas replied") instead of using a
  // generic "Priest's reply" label.
  final String priestName;
  final String priestPhotoUrl;

  const _ReviewsSection({
    required this.reviews,
    required this.reviewCount,
    required this.priestName,
    required this.priestPhotoUrl,
  });

  @override
  State<_ReviewsSection> createState() => _ReviewsSectionState();
}

class _ReviewsSectionState extends State<_ReviewsSection> {
  // Default preview is 3 reviews. Tapping "Show all" expands the
  // list inline — keeps the user's scroll context, no extra page,
  // and the heading's count tells them upfront how many to expect.
  static const int _previewCount = 3;
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final reviews = widget.reviews;
    final reviewCount = widget.reviewCount;

    // No reviews at all on this priest — hide the section entirely.
    if (reviewCount == 0 && reviews.isEmpty) {
      return const SizedBox.shrink();
    }

    final shown = _expanded
        ? reviews
        : reviews.take(_previewCount).toList();
    final hasMore = reviews.length > _previewCount;
    // Prefer reviews.length so the button copy matches what's
    // actually loaded; fall back to the aggregate count if we
    // somehow have more counted than loaded.
    final totalForCopy =
        reviews.length >= reviewCount ? reviews.length : reviewCount;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Reviews',
          style: GoogleFonts.inter(
            fontSize: 15,
            fontWeight: FontWeight.w700,
            color: AppColors.deepDarkBrown,
          ),
        ),
        const SizedBox(height: 10),
        if (reviews.isEmpty)
          _ReviewsEmptyState(reviewCount: reviewCount)
        else ...[
          for (int i = 0; i < shown.length; i++) ...[
            if (i > 0) const SizedBox(height: 10),
            _ReviewCard(
              review: shown[i],
              priestName: widget.priestName,
              priestPhotoUrl: widget.priestPhotoUrl,
            ),
          ],
          if (hasMore) ...[
            const SizedBox(height: 12),
            _ShowAllReviewsButton(
              expanded: _expanded,
              totalCount: totalForCopy,
              onTap: () => setState(() => _expanded = !_expanded),
            ),
          ],
        ],
      ],
    );
  }
}

// Full-width toggle button that opens/closes the rest of the review
// list. Copy switches between "Show all N reviews" and "Show less"
// so the affordance is obvious in both directions.
class _ShowAllReviewsButton extends StatelessWidget {
  final bool expanded;
  final int totalCount;
  final VoidCallback onTap;

  const _ShowAllReviewsButton({
    required this.expanded,
    required this.totalCount,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: AppColors.primaryBrown.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(AppRadius.small),
          border: Border.all(
            color: AppColors.primaryBrown.withValues(alpha: 0.2),
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              expanded
                  ? 'Show less'
                  : 'Show all $totalCount reviews',
              style: GoogleFonts.inter(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: AppColors.primaryBrown,
              ),
            ),
            const SizedBox(width: 6),
            AppIcon(
              expanded ? AppIcons.chevronDown : AppIcons.chevronRight,
              size: 14,
              color: AppColors.primaryBrown,
            ),
          ],
        ),
      ),
    );
  }
}

// Shown when reviewCount > 0 but the loaded list is empty — usually
// means the priests/{id}.recentReviews array hasn't been backfilled
// yet, or the sessions-collection fallback was blocked by rules.
// Either way the user sees a clear "we know you have N reviews, they
// just aren't loaded yet" rather than a missing section.
class _ReviewsEmptyState extends StatelessWidget {
  final int reviewCount;
  const _ReviewsEmptyState({required this.reviewCount});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      decoration: BoxDecoration(
        color: AppColors.surfaceWhite,
        borderRadius: BorderRadius.circular(AppRadius.small),
        border: Border.all(color: AppColors.borderLight),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              AppIcon(
                AppIcons.starOutline,
                size: 16,
                color: AppColors.amberGold,
              ),
              const SizedBox(width: 8),
              Text(
                '$reviewCount ${reviewCount == 1 ? "review" : "reviews"}',
                style: GoogleFonts.inter(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: AppColors.deepDarkBrown,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            "We couldn't load the reviews yet. Pull the page down to "
            'try again — they should appear in a moment.',
            style: GoogleFonts.inter(
              fontSize: 12,
              fontWeight: FontWeight.w400,
              height: 1.4,
              color: AppColors.muted,
            ),
          ),
        ],
      ),
    );
  }
}

class _ReviewCard extends StatelessWidget {
  final PriestReview review;
  // Used by the embedded reply bubble so the attribution reads
  // "<priestName> replied" and the priest's avatar appears next to
  // their words — makes it crystal clear which voice is replying.
  final String priestName;
  final String priestPhotoUrl;

  const _ReviewCard({
    required this.review,
    required this.priestName,
    required this.priestPhotoUrl,
  });

  @override
  Widget build(BuildContext context) {
    final initial = review.userName.isNotEmpty
        ? review.userName.trim().substring(0, 1).toUpperCase()
        : '?';
    final reply = review.priestReply;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surfaceWhite,
        borderRadius: BorderRadius.circular(AppRadius.small),
        border: Border.all(color: AppColors.borderLight),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 32,
                height: 32,
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
                        fontSize: 12.5,
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
                              size: 11,
                              color: AppColors.amberGold,
                            ),
                          ),
                        const SizedBox(width: 5),
                        Text(
                          review.rating.toStringAsFixed(1),
                          style: GoogleFonts.inter(
                            fontSize: 10.5,
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
          if (review.feedback.trim().isNotEmpty) ...[
            const SizedBox(height: 10),
            // No maxLines — full review text renders. Card height
            // grows with content; the page is scrollable so long
            // reviews simply add to scroll length.
            Text(
              '"${review.feedback}"',
              style: GoogleFonts.inter(
                fontSize: 12.5,
                fontWeight: FontWeight.w400,
                fontStyle: FontStyle.italic,
                height: 1.5,
                color: AppColors.deepDarkBrown.withValues(alpha: 0.85),
              ),
            ),
          ] else ...[
            // Star-only review: no text to quote, so render a quiet
            // placeholder rather than nothing — keeps card heights
            // visually consistent.
            const SizedBox(height: 8),
            Text(
              'Rated this session.',
              style: GoogleFonts.inter(
                fontSize: 11.5,
                fontWeight: FontWeight.w400,
                fontStyle: FontStyle.italic,
                color: AppColors.muted,
              ),
            ),
          ],
          if (reply != null) ...[
            const SizedBox(height: 10),
            _ReplyBubble(
              text: reply,
              priestName: priestName,
              priestPhotoUrl: priestPhotoUrl,
            ),
          ],
        ],
      ),
    );
  }

  Widget _avatarFallback(String initial) {
    return Center(
      child: Text(
        initial,
        style: GoogleFonts.inter(
          fontSize: 13,
          fontWeight: FontWeight.w700,
          color: AppColors.primaryBrown,
        ),
      ),
    );
  }
}

// Priest's reply nested visually under the user's review. Indented
// (so it reads as a threaded conversation), warm-beige background +
// gold left accent bar to match the brand, with the priest's tiny
// avatar + name + "replied" header so the user sees at a glance
// whose voice is responding to the review.
class _ReplyBubble extends StatelessWidget {
  final String text;
  final String priestName;
  final String priestPhotoUrl;

  const _ReplyBubble({
    required this.text,
    required this.priestName,
    required this.priestPhotoUrl,
  });

  @override
  Widget build(BuildContext context) {
    // Short display name — "Fr. Thomas Mathew" → "Fr. Thomas".
    // Keeps the attribution line compact while still being personal.
    // Empty/blank names fall back to the generic label.
    final shortName = _shortName(priestName);
    final initial = priestName.trim().isNotEmpty
        ? priestName.trim().substring(0, 1).toUpperCase()
        : '?';

    return Container(
      margin: const EdgeInsets.only(left: 12),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.warmBeige.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(10),
        border: Border(
          left: BorderSide(
            color: AppColors.amberGold.withValues(alpha: 0.8),
            width: 3,
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 22,
                height: 22,
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.amberGold.withValues(alpha: 0.18),
                ),
                child: priestPhotoUrl.isNotEmpty
                    ? CachedNetworkImage(
                        imageUrl: priestPhotoUrl,
                        fit: BoxFit.cover,
                        errorWidget: (_, _, _) =>
                            _avatarFallback(initial),
                        placeholder: (_, _) =>
                            const SizedBox.shrink(),
                      )
                    : _avatarFallback(initial),
              ),
              const SizedBox(width: 7),
              Flexible(
                child: Text(
                  shortName.isEmpty
                      ? "Priest's reply"
                      : '$shortName replied',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.inter(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: AppColors.primaryBrown,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          // Full reply rendered — no truncation so the priest's
          // entire response is visible.
          Text(
            text,
            style: GoogleFonts.inter(
              fontSize: 12,
              fontWeight: FontWeight.w400,
              height: 1.45,
              color: AppColors.deepDarkBrown.withValues(alpha: 0.85),
            ),
          ),
        ],
      ),
    );
  }

  // "Fr. Thomas Mathew" → "Fr. Thomas" so the attribution line stays
  // compact next to the small avatar. If the name has a religious
  // prefix (Fr./Rev./Pr./Bro./Br./Sr./Dr.), we keep the prefix + the
  // next word. Otherwise we take the first word.
  String _shortName(String full) {
    final trimmed = full.trim();
    if (trimmed.isEmpty) return '';
    final parts = trimmed.split(RegExp(r'\s+'));
    if (parts.length == 1) return parts.first;
    const prefixes = {'fr.', 'fr', 'rev.', 'rev', 'pr.', 'pr',
        'bro.', 'bro', 'br.', 'br', 'sr.', 'sr', 'dr.', 'dr'};
    if (prefixes.contains(parts.first.toLowerCase())) {
      return '${parts[0]} ${parts[1]}';
    }
    return parts.first;
  }

  Widget _avatarFallback(String initial) {
    return Center(
      child: Text(
        initial,
        style: GoogleFonts.inter(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          color: AppColors.amberGold,
        ),
      ),
    );
  }
}

// ─── Shimmer while loading ─────────────────────────────────────────

class _ProfileShimmer extends StatelessWidget {
  final double heroHeight;
  const _ProfileShimmer({required this.heroHeight});

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
      highlightColor: AppColors.surfaceCream,
      child: SingleChildScrollView(
        physics: const NeverScrollableScrollPhysics(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              height: heroHeight,
              color: AppColors.muted.withValues(alpha: 0.18),
            ),
            Transform.translate(
              offset: const Offset(0, -_kCardOverlap),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    box(h: 150, radius: BorderRadius.circular(20)),
                    const SizedBox(height: 22),
                    box(h: 12, w: 80),
                    const SizedBox(height: 8),
                    box(h: 44, radius: BorderRadius.circular(8)),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: box(
                            h: 50,
                            radius: BorderRadius.circular(16),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: box(
                            h: 50,
                            radius: BorderRadius.circular(16),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    box(h: 56, radius: BorderRadius.circular(12)),
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
