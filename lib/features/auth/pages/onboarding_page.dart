// Cinematic onboarding carousel — 5 swipeable, auto-advancing slides + sign-in.
//
// Architecture: one PageController drives the swipe, the card-deck depth
// (neighbours peek + scale down) AND the per-card parallax — all three read
// the same live scroll offset. Three small, separately-scoped controllers
// handle the story-style progress bar / auto-advance, the kinetic text
// reveal, and the ambient glow, so no single tick rebuilds the whole tree.
// Everything honours the OS "reduce motion" setting.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:gospel_vox/core/services/injection_container.dart';
import 'package:gospel_vox/core/theme/app_colors.dart';
import 'package:gospel_vox/core/widgets/app_snackbar.dart';
import 'package:gospel_vox/features/auth/bloc/auth_cubit.dart';
import 'package:gospel_vox/features/auth/bloc/auth_state.dart';
import 'package:gospel_vox/features/auth/widgets/role_mismatch_bottom_sheet.dart';
import 'package:gospel_vox/core/widgets/app_icons.dart';
import 'package:gospel_vox/core/widgets/app_loading_widget.dart';

const double _kCardWidth = 280;
const double _kCardHeight = 320;

// Reference canvas the onboarding screen is designed against. The whole
// screen is laid out at this width and then uniformly scaled with a
// FittedBox to fit any device, so every proportion (card ratio, fonts,
// chips, spacing) is preserved exactly on small phones and large tablets.
const double _kDesignWidth = 390;

// Each PageView slot is 74% of the canvas → the current card sits centred
// while a sliver of the next/previous card peeks at the edges, giving the
// "deck of cards" depth.
const double _kViewportFraction = 0.74;

// Hero photos live here, named onboarding_<slide>_<role>.webp.
const String _kOnboardImgBase = 'assets/images/onboarding/onboarding_';

// The source photos are 1120px wide, but the card is only ~280–460pt on
// screen. We decode them down to this width so a ~300pt card never holds a
// full 1120px bitmap in memory — keeps the carousel smooth and the image
// cache small on low-end Android. 900px stays crisp up to the largest
// tablet (card ≈460pt × 2x DPI ≈ 920px).
const int _kCardDecodeWidth = 900;

// Slightly quicker, still smooth slide-to-slide glide.
const Duration _kTransitionDuration = Duration(milliseconds: 1150);

// Rewind when looping from the last slide back to the first (it travels
// across all slides, so it gets a bit more time to not feel frantic).
const Duration _kWrapDuration = Duration(milliseconds: 1800);

// After the user touches the carousel, auto-advance stays paused this long
// before quietly resuming — so manual control always wins.
const Duration _kResumeDelay = Duration(seconds: 5);

// How long each slide dwells before auto-advancing (and how long its
// progress segment takes to fill). Long enough to comfortably read the
// heading + subtitle.
const List<Duration> _kIdleDurations = [
  Duration(milliseconds: 2000),
  Duration(milliseconds: 2000),
  Duration(milliseconds: 2000),
  Duration(milliseconds: 2000),
  Duration(milliseconds: 2000),
];

class OnboardingPage extends StatefulWidget {
  final String presetRole;

  const OnboardingPage({super.key, required this.presetRole});

  @override
  State<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends State<OnboardingPage>
    with TickerProviderStateMixin {
  late final PageController _pageController;
  late final AnimationController _progressController; // auto-advance clock
  late final AnimationController _textController; // kinetic heading/subtitle
  late final AnimationController _ambientController; // breathing glow
  // Drives the page glide ourselves so the transition honours its real
  // duration even when the OS has "remove animations" on (which would
  // otherwise make Flutter snap through transitions at 20× speed).
  late final AnimationController _glideController;
  Animation<double>? _glideAnim;
  bool _gliding = false;
  int _glideTarget = 0;

  Timer? _resumeTimer;
  int _index = 0;
  bool _autoSelectInProgress = false;
  bool _imagesPrecached = false;
  bool _animsStarted = false;
  bool _interacting = false;
  bool _reduceMotion = false;
  late List<_SlideData> _slides;

  int get _lastIndex => _slides.length - 1;

  @override
  void initState() {
    super.initState();
    _slides = _buildSlides(widget.presetRole);

    _pageController = PageController(viewportFraction: _kViewportFraction);
    // AnimationBehavior.preserve → these run at their true duration even when
    // the device has animations disabled (otherwise Flutter scales them to
    // 0.05×, which made the carousel flick/snap instead of glide).
    _progressController = AnimationController(
      vsync: this,
      duration: _kIdleDurations[0],
      animationBehavior: AnimationBehavior.preserve,
    )..addStatusListener(_onProgressStatus);
    _textController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
      animationBehavior: AnimationBehavior.preserve,
    );
    _ambientController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 6),
      animationBehavior: AnimationBehavior.preserve,
    );
    _glideController = AnimationController(
      vsync: this,
      animationBehavior: AnimationBehavior.preserve,
    )
      ..addListener(_onGlideTick)
      ..addStatusListener(_onGlideStatus);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.of(context).disableAnimations;

    // Warm the image cache once (decoded at card size) so swiping to a new
    // card never shows a blank frame or hitches while it decodes.
    if (!_imagesPrecached) {
      _imagesPrecached = true;
      for (final slide in _slides) {
        precacheImage(
          ResizeImage(AssetImage(slide.image), width: _kCardDecodeWidth),
          context,
        );
      }
    }

    if (!_animsStarted) {
      _animsStarted = true;
      // Auto-advance always runs (it's core navigation). Only the
      // decorative motion — glow pulse + text reveal — honours reduce-motion.
      if (_reduceMotion) {
        _textController.value = 1; // show text immediately, no reveal
      } else {
        _ambientController.repeat(reverse: true);
        _textController.forward(from: 0);
      }
      _startProgress();
    }
  }

  @override
  void dispose() {
    _resumeTimer?.cancel();
    _pageController.dispose();
    _progressController.dispose();
    _textController.dispose();
    _ambientController.dispose();
    _glideController.dispose();
    super.dispose();
  }

  // ── Auto-advance + progress ────────────────────────────────────────────

  double _safePage() {
    if (_pageController.hasClients &&
        _pageController.position.haveDimensions) {
      return _pageController.page ?? _index.toDouble();
    }
    return _index.toDouble();
  }

  void _startProgress() {
    if (!mounted) return;
    _progressController
      ..duration = _kIdleDurations[_index]
      ..forward(from: 0);
  }

  void _onProgressStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed && !_interacting && mounted) {
      // Loop endlessly: after the last slide, glide back to the first.
      final next = (_index + 1) % _slides.length;
      final wrapping = next == 0;
      _glideTo(next, wrapping ? _kWrapDuration : _kTransitionDuration);
    }
  }

  // Smoothly drives the PageView to [target] over [duration], honouring the
  // real duration regardless of the OS "remove animations" setting (unlike
  // PageController.animateToPage, which Flutter scales to 0.05×).
  void _glideTo(int target, Duration duration) {
    if (!_pageController.hasClients ||
        !_pageController.position.haveDimensions) {
      return;
    }
    final from = _pageController.page ?? _index.toDouble();
    _glideTarget = target;
    _gliding = true;
    _glideAnim = Tween<double>(begin: from, end: target.toDouble()).animate(
      CurvedAnimation(parent: _glideController, curve: Curves.easeInOutCubic),
    );
    _glideController
      ..duration = duration
      ..forward(from: 0);
  }

  void _onGlideTick() {
    final anim = _glideAnim;
    if (anim == null ||
        !_pageController.hasClients ||
        !_pageController.position.haveDimensions) {
      return;
    }
    final vp = _pageController.position.viewportDimension;
    _pageController.jumpTo(anim.value * vp * _kViewportFraction);
  }

  void _onGlideStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed) {
      _gliding = false;
      _settleOn(_glideTarget);
    }
  }

  // Called when a slide truly lands — updates state, gives feedback, and
  // restarts the dwell clock. Glides settle here once (via _onGlideStatus)
  // so a multi-slide loop rewind doesn't fire a burst of haptics/reveals.
  void _settleOn(int i) {
    if (!mounted) return;
    setState(() => _index = i);
    if (!_reduceMotion) {
      HapticFeedback.selectionClick();
      _textController.forward(from: 0);
    }
    if (!_interacting) _startProgress();
  }

  void _onPageSettled(int i) {
    // Our own glide settles via _onGlideStatus; ignore the intermediate
    // page-change callbacks it emits. Manual swipes land here directly.
    if (_gliding) return;
    _settleOn(i);
  }

  void _pauseAuto() {
    _interacting = true;
    _resumeTimer?.cancel();
    _gliding = false;
    if (_glideController.isAnimating) _glideController.stop();
    if (_progressController.isAnimating) _progressController.stop();
  }

  void _scheduleResume() {
    _resumeTimer?.cancel();
    _resumeTimer = Timer(_kResumeDelay, () {
      if (!mounted) return;
      _interacting = false;
      _startProgress();
    });
  }

  void _jumpTo(int i) {
    HapticFeedback.selectionClick();
    _resumeTimer?.cancel();
    _interacting = false;
    // Stop the dwell clock so it can't auto-advance mid-jump and override
    // the tapped target; it restarts cleanly once the jump settles.
    if (_progressController.isAnimating) _progressController.stop();
    _glideTo(i, _kTransitionDuration);
  }

  // ── Auth flow (unchanged) ──────────────────────────────────────────────

  // Triggered when the signed-in account already has a different role
  // than the one the user picked on the role-selection screen. The
  // user is still authenticated when this opens — the sheet routes
  // them to their existing shell or signs out and re-prompts.
  void _showRoleMismatchSheet(BuildContext context, AuthRoleMismatch state) {
    final cubit = context.read<AuthCubit>();
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetCtx) => RoleMismatchBottomSheet(
        email: state.email,
        existingRole: state.existingRole,
        selectedRole: state.selectedRole,
        onContinueAsExisting: () {
          Navigator.pop(sheetCtx);
          if (!mounted) return;
          switch (state.existingRole) {
            case 'priest':
              context.go('/priest');
            case 'admin':
              context.go('/admin');
            default:
              context.go('/user');
          }
        },
        onUseDifferentAccount: () async {
          Navigator.pop(sheetCtx);
          await cubit.signInWithDifferentAccount(
            selectedRole: state.selectedRole,
            provider: state.provider,
          );
        },
      ),
    );
  }

  Color _headerColorFor(int index) =>
      index == 4 ? AppColors.warmBeige : AppColors.deepDarkBrown;

  Color _headingColorFor(int index) =>
      index == 4 ? AppColors.warmBeige : AppColors.deepDarkBrown;

  Color _subtitleColorFor(int index) => index == 4
      ? AppColors.warmBeige.withValues(alpha: 0.78)
      : AppColors.deepDarkBrown.withValues(alpha: 0.62);

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) => sl<AuthCubit>(),
      child: BlocConsumer<AuthCubit, AuthState>(
        listener: (context, state) {
          if (state is AuthNeedsRole && !_autoSelectInProgress) {
            _autoSelectInProgress = true;
            context.read<AuthCubit>().selectRole(widget.presetRole, state);
          } else if (state is AuthAuthenticated) {
            _autoSelectInProgress = false;
            switch (state.role) {
              case 'priest':
                context.go('/priest');
              case 'admin':
                context.go('/admin');
              default:
                context.go('/user');
            }
          } else if (state is AuthRoleMismatch) {
            _autoSelectInProgress = false;
            _showRoleMismatchSheet(context, state);
          } else if (state is AuthError) {
            _autoSelectInProgress = false;
            AppSnackBar.error(context, state.message);
          }
        },
        builder: (context, state) {
          final cubit = context.read<AuthCubit>();
          final isBusy = state is AuthLoading || _autoSelectInProgress;

          // Pre-built once; its internal animations are independent of the
          // outer page rebuild, so it's safe to cache as the AnimatedBuilder
          // child and avoid rebuilding the PageView on every scroll frame.
          final carousel = _buildCardArea();

          return AnimatedBuilder(
            animation: _pageController,
            builder: (context, _) {
              final p = _safePage();
              final lo = p.floor().clamp(0, _lastIndex);
              final hi = p.ceil().clamp(0, _lastIndex);
              final t = (p - lo).clamp(0.0, 1.0);

              // Background + chrome colours cross-fade smoothly as you swipe
              // between two slides.
              final bgColor =
                  Color.lerp(_slides[lo].bgColor, _slides[hi].bgColor, t)!;
              final headerColor = Color.lerp(
                  _headerColorFor(lo), _headerColorFor(hi), t)!;
              final onDark = p > _lastIndex - 0.5;

              final overlayStyle = onDark
                  ? const SystemUiOverlayStyle(
                      statusBarColor: Colors.transparent,
                      statusBarIconBrightness: Brightness.light,
                      statusBarBrightness: Brightness.dark,
                    )
                  : const SystemUiOverlayStyle(
                      statusBarColor: Colors.transparent,
                      statusBarIconBrightness: Brightness.dark,
                      statusBarBrightness: Brightness.light,
                    );

              return AnnotatedRegion<SystemUiOverlayStyle>(
                value: overlayStyle,
                child: Stack(
                  children: [
                    Scaffold(
                      backgroundColor: bgColor,
                      body: SafeArea(
                        child: Center(
                          child: FittedBox(
                            fit: BoxFit.contain,
                            child: SizedBox(
                              width: _kDesignWidth,
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const SizedBox(height: 18),
                                  _buildTopBar(headerColor),
                                  const SizedBox(height: 30),
                                  carousel,
                                  const SizedBox(height: 22),
                                  _buildDots(onDark),
                                  const SizedBox(height: 24),
                                  _buildText(),
                                  const SizedBox(height: 28),
                                  _SignInButtons(
                                    enabled: !isBusy,
                                    onGoogleTap: () {
                                      HapticFeedback.lightImpact();
                                      cubit.signInWithGoogle(
                                          selectedRole: widget.presetRole);
                                    },
                                    onAppleTap: () {
                                      HapticFeedback.lightImpact();
                                      cubit.signInWithApple(
                                          selectedRole: widget.presetRole);
                                    },
                                  ),
                                  const SizedBox(height: 14),
                                  _TrustLine(onDark: onDark),
                                  const SizedBox(height: 28),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    // Normal full-screen loading while signing in.
                    if (isBusy)
                      const ColoredBox(
                        color: Color(0x66000000),
                        child: Center(
                          child: AppLoader(),
                        ),
                      ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }

  // ── Pieces ─────────────────────────────────────────────────────────────

  Widget _buildTopBar(Color color) {
    return SizedBox(
      height: 30,
      child: Center(
        child: Text(
          'GospelVox',
          style: GoogleFonts.playfairDisplay(
            fontSize: 19,
            fontWeight: FontWeight.w700,
            color: color,
            letterSpacing: 0.3,
          ),
        ),
      ),
    );
  }

  // Scroll-synced indicator: the active pill tracks the carousel's live
  // scroll position, so it slides exactly in step with the cards (during
  // both swipes and auto-advance) instead of a timer fill.
  Widget _buildDots(bool onDark) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 120),
      child: _DotsIndicator(
        controller: _pageController,
        count: _slides.length,
        fallbackIndex: _index,
        onDark: onDark,
        onTap: _jumpTo,
      ),
    );
  }

  Widget _buildCardArea() {
    return SizedBox(
      height: 334,
      child: Listener(
        onPointerDown: (_) => _pauseAuto(),
        onPointerUp: (_) => _scheduleResume(),
        onPointerCancel: (_) => _scheduleResume(),
        child: Stack(
          alignment: Alignment.center,
          clipBehavior: Clip.none,
          children: [
            _buildGlow(),
            Semantics(
              label: 'Feature highlights, swipe to explore',
              child: PageView.builder(
                controller: _pageController,
                clipBehavior: Clip.none,
                onPageChanged: _onPageSettled,
                itemCount: _slides.length,
                itemBuilder: (context, i) => _carouselItem(i),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Soft warm halo behind the deck — gives the carousel a "sacred",
  // atmospheric depth that a flat background can't. Pulses slowly; static
  // under reduce-motion.
  Widget _buildGlow() {
    return AnimatedBuilder(
      animation: _ambientController,
      builder: (context, _) {
        final t = _reduceMotion ? 0.45 : _ambientController.value;
        final alpha = 0.10 + 0.12 * t;
        return IgnorePointer(
          child: RepaintBoundary(
            child: Container(
              width: 360,
              height: 360,
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  colors: [
                    AppColors.amberGold.withValues(alpha: alpha),
                    Colors.transparent,
                  ],
                  stops: const [0.0, 0.72],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _carouselItem(int i) {
    return AnimatedBuilder(
      animation: _pageController,
      builder: (context, _) {
        final delta = _safePage() - i;
        final ad = delta.abs().clamp(0.0, 1.0);
        // Centre card full size/opacity; neighbours shrink + fade → deck.
        final scale = 1 - ad * 0.12;
        final opacity = (1 - ad * 0.42).clamp(0.0, 1.0);
        return Center(
          child: Opacity(
            opacity: opacity,
            child: Transform.scale(
              scale: scale,
              child: RepaintBoundary(
                child: _SlideCard(
                  slide: _slides[i],
                  parallax: _reduceMotion ? 0 : delta,
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  // Kinetic reveal: heading rises + fades in first, subtitle follows a beat
  // later (staggered intervals on one controller).
  Widget _buildText() {
    final slide = _slides[_index];
    final headingColor = _headingColorFor(_index);
    final subColor = _subtitleColorFor(_index);
    return AnimatedBuilder(
      animation: _textController,
      builder: (context, _) {
        final t = _reduceMotion ? 1.0 : _textController.value;
        final hv = Curves.easeOutCubic.transform(_seg(t, 0.0, 0.55));
        final sv = Curves.easeOutCubic.transform(_seg(t, 0.30, 1.0));
        return Column(
          children: [
            SizedBox(
              height: 80,
              child: Opacity(
                opacity: hv,
                child: Transform.translate(
                  offset: Offset(0, (1 - hv) * 16),
                  child: _HeadingText(text: slide.heading, color: headingColor),
                ),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 54,
              child: Opacity(
                opacity: sv,
                child: Transform.translate(
                  offset: Offset(0, (1 - sv) * 14),
                  child: _SubtitleText(text: slide.subtitle, color: subColor),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  double _seg(double v, double a, double b) =>
      ((v - a) / (b - a)).clamp(0.0, 1.0);
}

// ────────────────────────────────────────────────────────────────────────────
// Slide data
// ────────────────────────────────────────────────────────────────────────────

class _ChipData {
  final String text;
  final AlignmentGeometry alignment;
  final double rotationDeg;

  const _ChipData({
    required this.text,
    required this.alignment,
    this.rotationDeg = 0,
  });
}

class _SlideData {
  final Color bgColor;
  final List<Color> cardGradient;
  final IconData mainIcon;
  final Color mainIconColor;
  final String heading;
  final String subtitle;
  final List<_ChipData> chips;
  final String image;
  final bool isDarkCard;

  const _SlideData({
    required this.bgColor,
    required this.cardGradient,
    required this.mainIcon,
    required this.mainIconColor,
    required this.heading,
    required this.subtitle,
    required this.chips,
    required this.image,
    this.isDarkCard = false,
  });
}

List<_SlideData> _buildSlides(String role) {
  final isPriest = role == 'priest';

  return [
    // Slide 1
    _SlideData(
      bgColor: AppColors.warmBeige,
      cardGradient: const [Color(0xFFE8D5C4), Color(0xFFF4EDE3)],
      image: '${_kOnboardImgBase}1_${isPriest ? 'priest' : 'user'}.webp',
      mainIcon: AppIcons.add,
      mainIconColor: const Color(0xFF6B3A2A),
      heading: isPriest
          ? 'Share your calling,\nguide seeking hearts'
          : 'Spiritual guidance,\nanytime you need it',
      subtitle: isPriest
          ? 'Offer spiritual counsel to believers who need\nprayer, direction, and peace.'
          : 'Find prayer, counsel, and calm — with\nverified priests who truly listen.',
      chips: isPriest
          ? const [
              _ChipData(
                text: '✝️ Serve',
                alignment: Alignment.topRight,
                rotationDeg: -5,
              ),
              _ChipData(
                text: '🙏 Guide',
                alignment: Alignment.bottomLeft,
                rotationDeg: 3,
              ),
            ]
          : const [
              _ChipData(
                text: '🙏 Prayer',
                alignment: Alignment.topRight,
                rotationDeg: -5,
              ),
              _ChipData(
                text: '📖 Bible',
                alignment: Alignment.bottomLeft,
                rotationDeg: 3,
              ),
            ],
    ),

    // Slide 2
    _SlideData(
      bgColor: AppColors.amberGold,
      cardGradient: const [Color(0xFFD4A060), Color(0xFFE8C88A)],
      image: '${_kOnboardImgBase}2_${isPriest ? 'priest' : 'user'}.webp',
      mainIcon: AppIcons.mic,
      mainIconColor: const Color(0xFF6B3A2A),
      heading: isPriest
          ? 'Consult through\nvoice or chat'
          : 'Talk to a priest\nthrough voice or chat',
      subtitle: isPriest
          ? 'Accept requests on your schedule and earn\nfor every minute you serve.'
          : 'Private voice calls and chats, day or night —\nguidance is always a tap away.',
      chips: isPriest
          ? const [
              _ChipData(
                text: '🗣️ Consult',
                alignment: Alignment.topLeft,
                rotationDeg: 4,
              ),
              _ChipData(
                text: '💬 Respond',
                alignment: Alignment.bottomRight,
                rotationDeg: -3,
              ),
              _ChipData(
                text: 'Earn',
                alignment: Alignment.topRight,
              ),
            ]
          : const [
              _ChipData(
                text: '🗣️ Voice Call',
                alignment: Alignment.topLeft,
                rotationDeg: 4,
              ),
              _ChipData(
                text: '💬 Chat',
                alignment: Alignment.bottomRight,
                rotationDeg: -3,
              ),
              _ChipData(
                text: '24/7',
                alignment: Alignment.topRight,
              ),
            ],
    ),

    // Slide 3
    _SlideData(
      bgColor: const Color(0xFFB8C8A0),
      cardGradient: const [Color(0xFF8BA070), Color(0xFFB8C98A)],
      image: '${_kOnboardImgBase}3_${isPriest ? 'priest' : 'user'}.webp',
      mainIcon: AppIcons.bible,
      mainIconColor: AppColors.surfaceWhite,
      heading: isPriest
          ? 'Host Bible\nstudy sessions'
          : 'Join live Bible\nstudy sessions',
      subtitle: isPriest
          ? 'Create and lead group Bible sessions for\nyour community of believers.'
          : 'Gather in live Bible sessions and grow\nin faith, together.',
      chips: isPriest
          ? const [
              _ChipData(
                text: '📖 Teach',
                alignment: Alignment.topRight,
                rotationDeg: -4,
              ),
              _ChipData(
                text: '🎙️ Host',
                alignment: Alignment.bottomLeft,
                rotationDeg: 5,
              ),
            ]
          : const [
              _ChipData(
                text: '📅 Schedule',
                alignment: Alignment.topRight,
                rotationDeg: -4,
              ),
              _ChipData(
                text: '🕊️ Peace',
                alignment: Alignment.bottomLeft,
                rotationDeg: 5,
              ),
            ],
    ),

    // Slide 4
    _SlideData(
      bgColor: const Color(0xFFF9F0E3),
      cardGradient: const [Color(0xFFF0D5D5), Color(0xFFF9E8E0)],
      image: '${_kOnboardImgBase}4_${isPriest ? 'priest' : 'user'}.webp',
      mainIcon: AppIcons.church,
      mainIconColor: const Color(0xFF6B3A2A),
      heading: isPriest
          ? 'Build lasting\nspiritual bonds'
          : 'Find your partner\nin faith and love',
      subtitle: isPriest
          ? 'Become a trusted voice to families and\nfollowers across the platform.'
          : 'Meet someone who shares your faith,\nyour values, and your prayers.',
      chips: isPriest
          ? const [
              _ChipData(
                text: '👨‍👩‍👧 Family',
                alignment: Alignment.topRight,
                rotationDeg: -3,
              ),
              _ChipData(
                text: '🤝 Trust',
                alignment: Alignment.bottomLeft,
                rotationDeg: 4,
              ),
              _ChipData(
                text: '💒 Bless',
                alignment: Alignment.centerLeft,
              ),
            ]
          : const [
              _ChipData(
                text: '💍 Match',
                alignment: Alignment.topRight,
                rotationDeg: -3,
              ),
              _ChipData(
                text: '❤️ Love',
                alignment: Alignment.bottomLeft,
                rotationDeg: 4,
              ),
              _ChipData(
                text: '🤝 Trust',
                alignment: Alignment.centerLeft,
              ),
            ],
    ),

    // Slide 5
    _SlideData(
      bgColor: AppColors.primaryBrown,
      cardGradient: const [Color(0xFF6B3A2A), Color(0xFF8B5A3A)],
      image: '${_kOnboardImgBase}5_${isPriest ? 'priest' : 'user'}.webp',
      mainIcon: AppIcons.starOutline,
      mainIconColor: AppColors.surfaceWhite,
      heading: isPriest
          ? 'Grow your ministry\non Gospel Vox'
          : 'A community built\non trust and prayer',
      subtitle: isPriest
          ? 'Reach believers worldwide and earn as\nyou fulfil your calling.'
          : 'Belong to a community that prays for you,\nand grows with you.',
      chips: isPriest
          ? const [
              _ChipData(
                text: '⛪ Ministry',
                alignment: Alignment.topRight,
              ),
              _ChipData(
                text: '🌱 Grow',
                alignment: Alignment.bottomLeft,
              ),
            ]
          : const [
              _ChipData(
                text: '👥 Community',
                alignment: Alignment.topRight,
              ),
              _ChipData(
                text: '⭐ Faith',
                alignment: Alignment.bottomLeft,
              ),
            ],
      isDarkCard: true,
    ),
  ];
}

// ────────────────────────────────────────────────────────────────────────────
// Slide card — photo hero, warm colour grade, scrim, parallax chips
// ────────────────────────────────────────────────────────────────────────────

class _SlideCard extends StatelessWidget {
  final _SlideData slide;

  /// Signed distance of this card from the centre of the viewport
  /// (-1 … 0 … 1). Drives the multi-layer parallax: the photo drifts one
  /// way, the chips drift further the other → a real sense of depth on swipe.
  final double parallax;

  const _SlideCard({required this.slide, this.parallax = 0});

  @override
  Widget build(BuildContext context) {
    final photoDx = -parallax * 10;
    final chipDx = parallax * 16;

    return Container(
      width: _kCardWidth,
      height: _kCardHeight,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        // Two-layer warm lift: a broad soft shadow for the float, plus a
        // tighter contact shadow so the card edge feels grounded. Reads as
        // real depth rather than a flat drop shadow.
        boxShadow: [
          BoxShadow(
            color: AppColors.deepDarkBrown.withValues(alpha: 0.22),
            blurRadius: 34,
            spreadRadius: -6,
            offset: const Offset(0, 20),
          ),
          BoxShadow(
            color: AppColors.deepDarkBrown.withValues(alpha: 0.12),
            blurRadius: 10,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: Stack(
          fit: StackFit.expand,
          children: [
            // 1. Slide gradient — the fallback shown for the split second
            //    before the photo paints, and the base the tint sits on.
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: slide.cardGradient,
                ),
              ),
            ),

            // 2. The hero photo. Slightly over-scaled so the parallax shift
            //    never reveals an edge, faded in so it never "pops".
            Transform.translate(
              offset: Offset(photoDx, 0),
              child: Transform.scale(
                scale: 1.12,
                child: Image.asset(
                  slide.image,
                  fit: BoxFit.cover,
                  cacheWidth: _kCardDecodeWidth,
                  gaplessPlayback: true,
                  frameBuilder:
                      (context, child, frame, wasSynchronouslyLoaded) {
                    if (wasSynchronouslyLoaded) return child;
                    return AnimatedOpacity(
                      opacity: frame == null ? 0 : 1,
                      duration: const Duration(milliseconds: 350),
                      curve: Curves.easeOut,
                      child: child,
                    );
                  },
                ),
              ),
            ),

            // 3. Colour grade — every photo is washed toward this slide's
            //    own hue (top-left) and anchored to the brand brown
            //    (bottom-right). That shared brown undertone is what makes
            //    all five photos read as ONE palette instead of five
            //    unrelated stock shots, while each card keeps its identity.
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    slide.cardGradient.first.withValues(alpha: 0.30),
                    AppColors.primaryBrown.withValues(alpha: 0.34),
                  ],
                ),
              ),
            ),

            // 4. Legibility scrim — darkens only the bottom third so the
            //    white chip badges and the card edge stay readable on any
            //    photo, and gives the card cinematic depth.
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.transparent,
                    AppColors.deepDarkBrown.withValues(alpha: 0.55),
                  ],
                  stops: const [0.45, 1.0],
                ),
              ),
            ),

            // 5. Quiet glass caption chips — upright (not rotated stickers),
            //    drifting slightly for the parallax depth effect.
            for (final chip in slide.chips)
              Positioned.fill(
                child: Align(
                  alignment: chip.alignment,
                  child: Transform.translate(
                    offset: Offset(chipDx, 0),
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: _ChipBadge(text: chip.text),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ChipBadge extends StatelessWidget {
  final String text;

  const _ChipBadge({required this.text});

  @override
  Widget build(BuildContext context) {
    // Quiet glass caption: a dark translucent panel with a bright hairline
    // edge and light text — reads as a calm caption over the photo (matching
    // the bottom trust pills), not a playful sticker. No backdrop blur, so
    // it stays smooth on low-end Android.
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6.5),
      decoration: BoxDecoration(
        color: AppColors.deepDarkBrown.withValues(alpha: 0.38),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.22),
          width: 0.8,
        ),
      ),
      child: Text(
        text,
        style: GoogleFonts.inter(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: AppColors.warmBeige,
          letterSpacing: 0.2,
        ),
      ),
    );
  }
}

// ────────────────────────────────────────────────────────────────────────────
// Heading + subtitle widgets
// ────────────────────────────────────────────────────────────────────────────

class _HeadingText extends StatelessWidget {
  final String text;
  final Color color;

  const _HeadingText({required this.text, required this.color});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: GoogleFonts.playfairDisplay(
          fontSize: 28,
          fontWeight: FontWeight.w700,
          color: color,
          letterSpacing: -0.4,
          height: 1.18,
        ),
      ),
    );
  }
}

class _SubtitleText extends StatelessWidget {
  final String text;
  final Color color;

  const _SubtitleText({required this.text, required this.color});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: GoogleFonts.inter(
          fontSize: 14.5,
          fontWeight: FontWeight.w400,
          color: color,
          height: 1.55,
          letterSpacing: 0.15,
        ),
      ),
    );
  }
}

// ────────────────────────────────────────────────────────────────────────────
// Scroll-synced dots indicator (active pill slides with the carousel)
// ────────────────────────────────────────────────────────────────────────────

class _DotsIndicator extends StatelessWidget {
  final PageController controller;
  final int count;
  final int fallbackIndex;
  final bool onDark;
  final ValueChanged<int> onTap;

  const _DotsIndicator({
    required this.controller,
    required this.count,
    required this.fallbackIndex,
    required this.onDark,
    required this.onTap,
  });

  static const double _dot = 7;
  static const double _activeWidth = 24;
  static const double _height = 18;

  @override
  Widget build(BuildContext context) {
    final active = onDark ? AppColors.warmBeige : AppColors.deepDarkBrown;
    final inactive = active.withValues(alpha: 0.25);

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final slot = width / count;
        return AnimatedBuilder(
          animation: controller,
          builder: (context, _) {
            double page;
            if (controller.hasClients &&
                controller.position.haveDimensions) {
              page = controller.page ?? fallbackIndex.toDouble();
            } else {
              page = fallbackIndex.toDouble();
            }
            page = page.clamp(0.0, (count - 1).toDouble());

            return SizedBox(
              height: _height,
              width: width,
              child: Stack(
                children: [
                  // Tappable inactive dots, evenly spaced.
                  Row(
                    children: List.generate(count, (i) {
                      return Expanded(
                        child: Semantics(
                          button: true,
                          label: 'Go to slide ${i + 1}',
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () => onTap(i),
                            child: Center(
                              child: Container(
                                width: _dot,
                                height: _dot,
                                decoration: BoxDecoration(
                                  color: inactive,
                                  shape: BoxShape.circle,
                                ),
                              ),
                            ),
                          ),
                        ),
                      );
                    }),
                  ),
                  // Active pill — slides smoothly to the live scroll position.
                  Positioned(
                    top: (_height - _dot) / 2,
                    left: (page + 0.5) * slot - _activeWidth / 2,
                    child: IgnorePointer(
                      child: Container(
                        width: _activeWidth,
                        height: _dot,
                        decoration: BoxDecoration(
                          color: active,
                          borderRadius: BorderRadius.circular(_dot / 2),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

// ────────────────────────────────────────────────────────────────────────────
// Trust line
// ────────────────────────────────────────────────────────────────────────────

class _TrustLine extends StatelessWidget {
  final bool onDark;

  const _TrustLine({required this.onDark});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _TrustPill(icon: AppIcons.verified, label: 'Verified priests', onDark: onDark),
        const SizedBox(width: 8),
        _TrustPill(icon: AppIcons.lock, label: 'Private & secure', onDark: onDark),
      ],
    );
  }
}

class _TrustPill extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool onDark;

  const _TrustPill({required this.icon, required this.label, required this.onDark});

  @override
  Widget build(BuildContext context) {
    final fg = onDark
        ? AppColors.warmBeige.withValues(alpha: 0.85)
        : AppColors.deepDarkBrown.withValues(alpha: 0.72);
    final base = onDark ? AppColors.warmBeige : AppColors.deepDarkBrown;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: base.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: base.withValues(alpha: 0.16), width: 0.8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AppIcon(icon, size: 11, color: fg),
          const SizedBox(width: 5),
          Text(
            label,
            style: GoogleFonts.inter(
              fontSize: 10.5,
              fontWeight: FontWeight.w600,
              color: fg,
            ),
          ),
        ],
      ),
    );
  }
}

// ────────────────────────────────────────────────────────────────────────────
// Sign-in buttons
// ────────────────────────────────────────────────────────────────────────────

class _SignInButtons extends StatelessWidget {
  final VoidCallback onGoogleTap;
  final VoidCallback onAppleTap;
  final bool enabled;

  const _SignInButtons({
    required this.onGoogleTap,
    required this.onAppleTap,
    required this.enabled,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        children: [
          _PressableButton(
            enabled: enabled,
            onTap: onGoogleTap,
            // Warm-white (not pure #FFFFFF) so it sits in the palette without
            // jarring — but still clearly lighter than the beige background,
            // so it never blends into the slide behind it.
            backgroundColor: AppColors.surfaceCream,
            border: Border.all(color: AppColors.muted.withValues(alpha: 0.3)),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const AppIcon(
                  Icons.g_mobiledata,
                  size: 28,
                  color: AppColors.deepDarkBrown,
                ),
                const SizedBox(width: 8),
                Text(
                  'Continue with Google',
                  style: GoogleFonts.inter(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: AppColors.deepDarkBrown,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          _PressableButton(
            enabled: enabled,
            onTap: onAppleTap,
            backgroundColor: AppColors.deepDarkBrown,
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF6B3A2A), Color(0xFF3D1F0F)],
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const AppIcon(AppIcons.apple,
                    size: 22, color: AppColors.surfaceWhite),
                const SizedBox(width: 12),
                Text(
                  'Continue with Apple',
                  style: GoogleFonts.inter(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: AppColors.warmBeige,
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

class _PressableButton extends StatefulWidget {
  final bool enabled;
  final VoidCallback onTap;
  final Color backgroundColor;
  final BoxBorder? border;

  /// Optional gradient fill (overrides [backgroundColor]). When set, the
  /// button also gets a soft drop shadow for a premium, lifted CTA.
  final Gradient? gradient;
  final Widget child;

  const _PressableButton({
    required this.enabled,
    required this.onTap,
    required this.backgroundColor,
    required this.child,
    this.border,
    this.gradient,
  });

  @override
  State<_PressableButton> createState() => _PressableButtonState();
}

class _PressableButtonState extends State<_PressableButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown:
          widget.enabled ? (_) => setState(() => _pressed = true) : null,
      onTapUp: widget.enabled ? (_) => setState(() => _pressed = false) : null,
      onTapCancel:
          widget.enabled ? () => setState(() => _pressed = false) : null,
      onTap: widget.enabled ? widget.onTap : null,
      behavior: HitTestBehavior.opaque,
      child: AnimatedScale(
        scale: _pressed ? 0.97 : 1.0,
        duration: const Duration(milliseconds: 80),
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 200),
          opacity: widget.enabled ? 1.0 : 0.4,
          child: Container(
            width: double.infinity,
            height: 56,
            decoration: BoxDecoration(
              color: widget.gradient == null ? widget.backgroundColor : null,
              gradient: widget.gradient,
              borderRadius: BorderRadius.circular(28),
              border: widget.border,
              boxShadow: widget.gradient != null
                  ? [
                      BoxShadow(
                        color: AppColors.deepDarkBrown.withValues(alpha: 0.28),
                        blurRadius: 18,
                        offset: const Offset(0, 8),
                      ),
                    ]
                  : null,
            ),
            child: widget.child,
          ),
        ),
      ),
    );
  }
}
