// Cinematic onboarding carousel — 5 auto-advancing slides + sign-in

import 'dart:async';
import 'dart:math' as math;

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

const double _kCardWidth = 280;
const double _kCardHeight = 320;
const Duration _kTransitionDuration = Duration(milliseconds: 500);

const List<Duration> _kIdleDurations = [
  Duration(milliseconds: 1500),
  Duration(milliseconds: 900),
  Duration(milliseconds: 1200),
  Duration(milliseconds: 900),
  Duration(milliseconds: 2500),
];

class OnboardingPage extends StatefulWidget {
  final String presetRole;

  const OnboardingPage({super.key, required this.presetRole});

  @override
  State<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends State<OnboardingPage>
    with SingleTickerProviderStateMixin {
  late AnimationController _transitionController;
  Timer? _idleTimer;
  int _currentIndex = 0;
  int _nextIndex = 1;
  bool _isTransitioning = false;
  bool _autoSelectInProgress = false;
  late List<_SlideData> _slides;

  @override
  void initState() {
    super.initState();
    _slides = _buildSlides(widget.presetRole);

    _transitionController = AnimationController(
      vsync: this,
      duration: _kTransitionDuration,
    );

    _scheduleNextTransition();
  }

  void _scheduleNextTransition() {
    _idleTimer?.cancel();
    _idleTimer = Timer(_kIdleDurations[_currentIndex], _startTransition);
  }

  void _startTransition() {
    if (!mounted) return;
    setState(() {
      _nextIndex = (_currentIndex + 1) % _slides.length;
      _isTransitioning = true;
    });
    _transitionController.forward(from: 0).then((_) {
      if (!mounted) return;
      setState(() {
        _currentIndex = _nextIndex;
        _isTransitioning = false;
      });
      _transitionController.reset();
      _scheduleNextTransition();
    });
  }

  @override
  void dispose() {
    _idleTimer?.cancel();
    _transitionController.dispose();
    super.dispose();
  }

  Color _headerColorFor(int index) =>
      index == 4 ? AppColors.warmBeige : AppColors.deepDarkBrown;

  Color _headingColorFor(int index) =>
      index == 4 ? AppColors.warmBeige : AppColors.deepDarkBrown;

  Color _subtitleColorFor(int index) => index == 4
      ? AppColors.warmBeige.withValues(alpha: 0.75)
      : AppColors.muted;

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
          } else if (state is AuthError) {
            _autoSelectInProgress = false;
            AppSnackBar.error(context, state.message);
          }
        },
        builder: (context, state) {
          final cubit = context.read<AuthCubit>();
          final isBusy = state is AuthLoading || _autoSelectInProgress;

          return AnimatedBuilder(
            animation: _transitionController,
            builder: (context, _) {
              final size = MediaQuery.of(context).size;
              final screenWidth = size.width;
              final progress = _transitionController.value;
              final eased = Curves.easeInOutCubic.transform(progress);
              final outOpacity =
                  1.0 - (progress / 0.6).clamp(0.0, 1.0).toDouble();
              final inOpacity =
                  ((progress - 0.4) / 0.6).clamp(0.0, 1.0).toDouble();

              final currentSlide = _slides[_currentIndex];
              final nextSlide = _slides[_nextIndex];

              final bgColor = _isTransitioning
                  ? Color.lerp(
                      currentSlide.bgColor, nextSlide.bgColor, progress)!
                  : currentSlide.bgColor;

              final headerColor = _isTransitioning
                  ? Color.lerp(_headerColorFor(_currentIndex),
                      _headerColorFor(_nextIndex), progress)!
                  : _headerColorFor(_currentIndex);

              // Slide 5 has a deep brown background → light status-bar icons
              // would otherwise be invisible against the dark fill. Slides 1–4
              // sit on light backgrounds so dark icons are correct there.
              final overlayStyle = _currentIndex == 4
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
                      extendBodyBehindAppBar: false,
                      body: SafeArea(
                      child: Column(
                        children: [
                          const SizedBox(height: 24),
                          Text(
                            'Gospel Vox',
                            style: GoogleFonts.playfairDisplay(
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                              color: headerColor,
                              letterSpacing: 0.5,
                            ),
                          ),
                          Expanded(
                            child: SingleChildScrollView(
                              physics: const NeverScrollableScrollPhysics(),
                              child: Column(
                                children: [
                                  const SizedBox(height: 40),
                                  _buildCardsArea(
                                    screenWidth: screenWidth,
                                    currentSlide: currentSlide,
                                    nextSlide: nextSlide,
                                    eased: eased,
                                  ),
                                  const SizedBox(height: 24),
                                  _PaginationIndicator(
                                    count: _slides.length,
                                    currentIndex: _currentIndex,
                                    isOnDarkBg: _currentIndex == 4,
                                  ),
                                  const SizedBox(height: 32),
                                  _buildHeadingArea(
                                    screenWidth: screenWidth,
                                    currentSlide: currentSlide,
                                    nextSlide: nextSlide,
                                    eased: eased,
                                    outOpacity: outOpacity,
                                    inOpacity: inOpacity,
                                  ),
                                  const SizedBox(height: 16),
                                  _buildSubtitleArea(
                                    screenWidth: screenWidth,
                                    currentSlide: currentSlide,
                                    nextSlide: nextSlide,
                                    eased: eased,
                                    outOpacity: outOpacity,
                                    inOpacity: inOpacity,
                                  ),
                                  const SizedBox(height: 16),
                                ],
                              ),
                            ),
                          ),
                          _SignInButtons(
                            enabled: !isBusy,
                            onGoogleTap: () => cubit.signInWithGoogle(
                                selectedRole: widget.presetRole),
                            onAppleTap: () => cubit.signInWithApple(
                                selectedRole: widget.presetRole),
                          ),
                          const SizedBox(height: 40),
                        ],
                      ),
                    ),
                  ),
                    if (isBusy)
                      Container(
                        color: Colors.black.withValues(alpha: 0.3),
                        child: const Center(
                          child: CircularProgressIndicator(
                            color: AppColors.deepDarkBrown,
                          ),
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

  Widget _buildCardsArea({
    required double screenWidth,
    required _SlideData currentSlide,
    required _SlideData nextSlide,
    required double eased,
  }) {
    return SizedBox(
      height: _kCardHeight,
      width: double.infinity,
      child: ClipRect(
        child: Stack(
          alignment: Alignment.center,
          children: [
            Transform.translate(
              offset:
                  Offset(_isTransitioning ? -screenWidth * eased : 0, 0),
              child: RepaintBoundary(child: _SlideCard(slide: currentSlide)),
            ),
            if (_isTransitioning)
              Transform.translate(
                offset: Offset(screenWidth * (1 - eased), 0),
                child: RepaintBoundary(child: _SlideCard(slide: nextSlide)),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeadingArea({
    required double screenWidth,
    required _SlideData currentSlide,
    required _SlideData nextSlide,
    required double eased,
    required double outOpacity,
    required double inOpacity,
  }) {
    return SizedBox(
      height: 76,
      width: double.infinity,
      child: ClipRect(
        child: Stack(
          children: [
            Positioned.fill(
              child: Opacity(
                opacity: _isTransitioning ? outOpacity : 1.0,
                child: Transform.translate(
                  offset: Offset(
                      _isTransitioning ? -screenWidth * 0.3 * eased : 0, 0),
                  child: _HeadingText(
                    text: currentSlide.heading,
                    color: _headingColorFor(_currentIndex),
                  ),
                ),
              ),
            ),
            if (_isTransitioning)
              Positioned.fill(
                child: Opacity(
                  opacity: inOpacity,
                  child: Transform.translate(
                    offset:
                        Offset(screenWidth * 0.3 * (1 - eased), 0),
                    child: _HeadingText(
                      text: nextSlide.heading,
                      color: _headingColorFor(_nextIndex),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildSubtitleArea({
    required double screenWidth,
    required _SlideData currentSlide,
    required _SlideData nextSlide,
    required double eased,
    required double outOpacity,
    required double inOpacity,
  }) {
    return SizedBox(
      height: 56,
      width: double.infinity,
      child: ClipRect(
        child: Stack(
          children: [
            Positioned.fill(
              child: Opacity(
                opacity: _isTransitioning ? outOpacity : 1.0,
                child: Transform.translate(
                  offset: Offset(
                      _isTransitioning ? -screenWidth * 0.2 * eased : 0, 0),
                  child: _SubtitleText(
                    text: currentSlide.subtitle,
                    color: _subtitleColorFor(_currentIndex),
                  ),
                ),
              ),
            ),
            if (_isTransitioning)
              Positioned.fill(
                child: Opacity(
                  opacity: inOpacity,
                  child: Transform.translate(
                    offset:
                        Offset(screenWidth * 0.2 * (1 - eased), 0),
                    child: _SubtitleText(
                      text: nextSlide.subtitle,
                      color: _subtitleColorFor(_nextIndex),
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
  final bool isDarkCard;

  const _SlideData({
    required this.bgColor,
    required this.cardGradient,
    required this.mainIcon,
    required this.mainIconColor,
    required this.heading,
    required this.subtitle,
    required this.chips,
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
      mainIcon: Icons.add,
      mainIconColor: const Color(0xFF6B3A2A),
      heading: isPriest
          ? 'Share your calling,\nguide seeking hearts'
          : 'Spiritual guidance,\nanytime you need it',
      subtitle: isPriest
          ? 'Offer spiritual counsel to believers who need\nprayer, direction, and peace.'
          : 'Connect with verified priests for prayer,\ncounseling, and spiritual direction.',
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
      mainIcon: Icons.mic_none,
      mainIconColor: const Color(0xFF6B3A2A),
      heading: isPriest
          ? 'Consult through\nvoice or chat'
          : 'Talk to a priest\nthrough voice or chat',
      subtitle: isPriest
          ? 'Accept requests on your schedule and earn\nfor every minute you serve.'
          : 'Private voice calls and messaging with\nguidance professionals, 24/7.',
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
      mainIcon: Icons.menu_book,
      mainIconColor: AppColors.surfaceWhite,
      heading: isPriest
          ? 'Host Bible\nstudy sessions'
          : 'Join live Bible\nstudy sessions',
      subtitle: isPriest
          ? 'Create and lead group Bible sessions for\nyour community of believers.'
          : 'Schedule and attend Bible reading sessions\nwith experienced speakers.',
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
      mainIcon: Icons.church,
      mainIconColor: const Color(0xFF6B3A2A),
      heading: isPriest
          ? 'Build lasting\nspiritual bonds'
          : 'Find your partner\nin faith and love',
      subtitle: isPriest
          ? 'Become a trusted voice to families and\nfollowers across the platform.'
          : 'Matrimony profiles built on shared faith,\nvalues, and denomination.',
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
      mainIcon: Icons.favorite_border,
      mainIconColor: AppColors.surfaceWhite,
      heading: isPriest
          ? 'Grow your ministry\non Gospel Vox'
          : 'A community built\non trust and prayer',
      subtitle: isPriest
          ? 'Reach believers worldwide and earn as\nyou fulfil your calling.'
          : 'Join thousands of believers growing\ntheir faith with Gospel Vox.',
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
// Slide card
// ────────────────────────────────────────────────────────────────────────────

class _SlideCard extends StatelessWidget {
  final _SlideData slide;

  const _SlideCard({required this.slide});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: _kCardWidth,
      height: _kCardHeight,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: slide.cardGradient,
        ),
        borderRadius: BorderRadius.circular(24),
      ),
      child: Stack(
        children: [
          Center(
            child: Icon(
              slide.mainIcon,
              size: 100,
              color: slide.mainIconColor,
            ),
          ),
          for (final chip in slide.chips)
            Positioned.fill(
              child: Align(
                alignment: chip.alignment,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Transform.rotate(
                    angle: chip.rotationDeg * math.pi / 180,
                    child: _ChipBadge(
                      text: chip.text,
                      isDarkCard: slide.isDarkCard,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _ChipBadge extends StatelessWidget {
  final String text;
  final bool isDarkCard;

  const _ChipBadge({required this.text, this.isDarkCard = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white
            .withValues(alpha: isDarkCard ? 0.95 : 0.92),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            blurRadius: 12,
            color: AppColors.deepDarkBrown.withValues(alpha: 0.1),
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Text(
        text,
        style: GoogleFonts.inter(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: AppColors.deepDarkBrown,
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
          fontSize: 26,
          fontWeight: FontWeight.w700,
          color: color,
          letterSpacing: -0.3,
          height: 1.25,
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
          fontSize: 14,
          fontWeight: FontWeight.w400,
          color: color,
          height: 1.5,
        ),
      ),
    );
  }
}

// ────────────────────────────────────────────────────────────────────────────
// Pagination
// ────────────────────────────────────────────────────────────────────────────

class _PaginationIndicator extends StatelessWidget {
  final int count;
  final int currentIndex;
  final bool isOnDarkBg;

  const _PaginationIndicator({
    required this.count,
    required this.currentIndex,
    required this.isOnDarkBg,
  });

  @override
  Widget build(BuildContext context) {
    final activeColor =
        isOnDarkBg ? AppColors.warmBeige : AppColors.deepDarkBrown;
    final inactiveColor = (isOnDarkBg
            ? AppColors.warmBeige
            : AppColors.deepDarkBrown)
        .withValues(alpha: 0.25);

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(count, (i) {
        final isActive = i == currentIndex;
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 5),
          child: AnimatedContainer(
            duration: _kTransitionDuration,
            curve: Curves.easeInOutCubic,
            width: isActive ? 24 : 8,
            height: 8,
            decoration: BoxDecoration(
              color: isActive ? activeColor : inactiveColor,
              borderRadius: BorderRadius.circular(4),
            ),
          ),
        );
      }),
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
            backgroundColor: AppColors.surfaceWhite,
            border:
                Border.all(color: AppColors.muted.withValues(alpha: 0.3)),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(
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
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.apple, size: 22, color: AppColors.surfaceWhite),
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
  final Widget child;

  const _PressableButton({
    required this.enabled,
    required this.onTap,
    required this.backgroundColor,
    required this.child,
    this.border,
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
      onTapUp:
          widget.enabled ? (_) => setState(() => _pressed = false) : null,
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
              color: widget.backgroundColor,
              borderRadius: BorderRadius.circular(28),
              border: widget.border,
            ),
            child: widget.child,
          ),
        ),
      ),
    );
  }
}
