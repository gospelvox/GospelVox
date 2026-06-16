// Role selection screen — landing page for unauthenticated users
//
// Admin login is hidden behind a secret tap SEQUENCE on the existing
// cards + heading (see _kAdminUnlockSequence). There is nothing visible
// on screen — only someone who already knows the sequence can open the
// admin sheet, and the sheet itself still requires admin credentials.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:gospel_vox/core/services/injection_container.dart';
import 'package:gospel_vox/core/theme/app_colors.dart';
import 'package:gospel_vox/features/auth/bloc/auth_cubit.dart';
import 'package:gospel_vox/features/auth/bloc/auth_state.dart';
import 'package:gospel_vox/features/auth/widgets/admin_login_bottom_sheet.dart';

class RoleSelectionPage extends StatefulWidget {
  const RoleSelectionPage({super.key});

  @override
  State<RoleSelectionPage> createState() => _RoleSelectionPageState();
}

class _RoleSelectionPageState extends State<RoleSelectionPage>
    with SingleTickerProviderStateMixin {
  String? _selectedRole;

  // ─── Hidden admin unlock ──────────────────────────────────
  // A secret tap sequence on the existing UI opens the admin sheet —
  // invisible to anyone who doesn't already know it. Tokens:
  //   'member'  = tap the Member card
  //   'speaker' = tap the Speaker card
  //   'heading' = tap the "Who are you?" text
  // Sequence: Speaker, Member, Member, Speaker, then double-tap the
  // heading, then triple-tap Speaker.
  static const List<String> _kAdminUnlockSequence = [
    'speaker', 'member', 'member', 'speaker',
    'heading', 'heading',
    'speaker', 'speaker', 'speaker',
  ];
  final List<String> _adminSeq = [];
  Timer? _adminSeqResetTimer;
  // Deliberate delay between a correct sequence and the sheet opening,
  // so an onlooker can't tie the taps to the result.
  Timer? _adminOpenTimer;

  late final AnimationController _controller;
  late final Animation<double> _headingFade;
  late final Animation<Offset> _headingSlide;
  late final Animation<double> _userFade;
  late final Animation<double> _userScale;
  late final Animation<double> _speakerFade;
  late final Animation<double> _speakerScale;
  late final Animation<double> _ctaFade;
  late final Animation<Offset> _ctaSlide;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );

    _headingFade = CurvedAnimation(
      parent: _controller,
      curve: const Interval(0.0, 0.5, curve: Curves.easeOutCubic),
    );
    _headingSlide = Tween<Offset>(
      begin: const Offset(0, 0.1),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _controller,
      curve: const Interval(0.0, 0.5, curve: Curves.easeOutCubic),
    ));

    _userFade = CurvedAnimation(
      parent: _controller,
      curve: const Interval(0.2, 0.7, curve: Curves.easeOutBack),
    );
    _userScale = Tween<double>(begin: 0.92, end: 1.0).animate(CurvedAnimation(
      parent: _controller,
      curve: const Interval(0.2, 0.7, curve: Curves.easeOutBack),
    ));

    _speakerFade = CurvedAnimation(
      parent: _controller,
      curve: const Interval(0.35, 0.85, curve: Curves.easeOutBack),
    );
    _speakerScale =
        Tween<double>(begin: 0.92, end: 1.0).animate(CurvedAnimation(
      parent: _controller,
      curve: const Interval(0.35, 0.85, curve: Curves.easeOutBack),
    ));

    _ctaFade = CurvedAnimation(
      parent: _controller,
      curve: const Interval(0.5, 1.0, curve: Curves.easeOutQuart),
    );
    _ctaSlide = Tween<Offset>(
      begin: const Offset(0, 0.15),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _controller,
      curve: const Interval(0.5, 1.0, curve: Curves.easeOutQuart),
    ));

    _controller.forward();
  }

  @override
  void dispose() {
    _adminSeqResetTimer?.cancel();
    _adminOpenTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onContinue() {
    if (_selectedRole == null) return;
    HapticFeedback.mediumImpact();
    context.push('/onboarding', extra: _selectedRole);
  }

  void _showAdminLogin(BuildContext outerContext) {
    HapticFeedback.mediumImpact();
    showModalBottomSheet<void>(
      context: outerContext,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => BlocProvider.value(
        value: outerContext.read<AuthCubit>(),
        child: const AdminLoginBottomSheet(),
      ),
    );
  }

  // Records one step of the hidden admin unlock sequence. Keeps only the
  // last N taps so stray taps never block a correct run, and resets if
  // the user pauses >5s between taps so the gesture stays deliberate.
  // `context` MUST be a context from below the AuthCubit provider (the
  // BlocBuilder's builder context) — _showAdminLogin reads AuthCubit
  // from it. The State's own `this.context` sits ABOVE the provider
  // (it's created inside build), so passing it would throw
  // ProviderNotFoundException.
  void _recordAdminTap(String token, BuildContext context) {
    _adminSeq.add(token);
    if (_adminSeq.length > _kAdminUnlockSequence.length) {
      _adminSeq.removeRange(
          0, _adminSeq.length - _kAdminUnlockSequence.length);
    }

    _adminSeqResetTimer?.cancel();
    _adminSeqResetTimer =
        Timer(const Duration(seconds: 5), () => _adminSeq.clear());

    if (_matchesAdminSequence()) {
      _adminSeq.clear();
      _adminSeqResetTimer?.cancel();
      // Wait 5s after the correct sequence before opening the sheet.
      _adminOpenTimer?.cancel();
      _adminOpenTimer = Timer(const Duration(seconds: 5), () {
        if (!mounted) return;
        _showAdminLogin(context);
      });
    }
  }

  bool _matchesAdminSequence() {
    if (_adminSeq.length != _kAdminUnlockSequence.length) return false;
    for (var i = 0; i < _adminSeq.length; i++) {
      if (_adminSeq[i] != _kAdminUnlockSequence[i]) return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final isSmallScreen = screenWidth < 360;
    final horizontalPadding = isSmallScreen ? 16.0 : 24.0;
    final cardHorizontalPadding = isSmallScreen ? 12.0 : 16.0;

    return BlocProvider(
      create: (_) => sl<AuthCubit>(),
      // No listener at this level — the only auth interaction reachable
      // from this page is the admin login bottom sheet, which owns its
      // own listener. Having two listeners on the same cubit was racing
      // navigation calls on AuthAuthenticated.
      child: BlocBuilder<AuthCubit, AuthState>(
        builder: (context, state) {
          return Stack(
            children: [
              Scaffold(
                backgroundColor: AppColors.warmBeige,
                resizeToAvoidBottomInset: true,
                body: SafeArea(
                  child: Column(
                    children: [
                      const SizedBox(height: 52),
                      SlideTransition(
                        position: _headingSlide,
                        child: FadeTransition(
                          opacity: _headingFade,
                          child: Padding(
                            padding: EdgeInsets.symmetric(
                                horizontal: horizontalPadding),
                            child: _Heading(
                              isSmallScreen: isSmallScreen,
                              onSecretTap: () =>
                                  _recordAdminTap('heading', context),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 32),
                      Expanded(
                        child: SingleChildScrollView(
                          physics: const BouncingScrollPhysics(),
                          child: Column(
                            children: [
                              Padding(
                                padding: EdgeInsets.symmetric(
                                    horizontal: cardHorizontalPadding),
                                child: _RoleCard(
                                  isUser: true,
                                  isSelected: _selectedRole == 'user',
                                  otherSelected: _selectedRole == 'priest',
                                  fadeAnimation: _userFade,
                                  scaleAnimation: _userScale,
                                  onTap: () {
                                    setState(() => _selectedRole = 'user');
                                    _recordAdminTap('member', context);
                                  },
                                ),
                              ),
                              const _OrSeparator(),
                              Padding(
                                padding: EdgeInsets.symmetric(
                                    horizontal: cardHorizontalPadding),
                                child: _RoleCard(
                                  isUser: false,
                                  isSelected: _selectedRole == 'priest',
                                  otherSelected: _selectedRole == 'user',
                                  fadeAnimation: _speakerFade,
                                  scaleAnimation: _speakerScale,
                                  onTap: () {
                                    setState(() => _selectedRole = 'priest');
                                    _recordAdminTap('speaker', context);
                                  },
                                ),
                              ),
                              const SizedBox(height: 16),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Padding(
                        padding: EdgeInsets.symmetric(
                            horizontal: horizontalPadding),
                        child: _CtaButton(
                          enabled: _selectedRole != null,
                          fadeAnimation: _ctaFade,
                          slideAnimation: _ctaSlide,
                          onTap: _onContinue,
                        ),
                      ),
                      const SizedBox(height: 24),
                    ],
                  ),
                ),
              ),
              if (state is AuthLoading)
                Container(
                  color: Colors.black.withValues(alpha: 0.3),
                  child: const Center(
                    child: CircularProgressIndicator(
                      color: AppColors.primaryBrown,
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _Heading extends StatelessWidget {
  final bool isSmallScreen;
  final VoidCallback onSecretTap;

  const _Heading({required this.isSmallScreen, required this.onSecretTap});

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      // GestureDetector wraps ONLY the text, so the hidden trigger's hit
      // area is the glyphs themselves — not the full-width band the old
      // long-press used (which made the empty right side hot too).
      child: GestureDetector(
        onTap: onSecretTap,
        child: Text(
          'Who are\nyou?',
          style: GoogleFonts.inter(
            fontSize: isSmallScreen ? 32 : 40,
            fontWeight: FontWeight.w900,
            color: AppColors.black,
            letterSpacing: isSmallScreen ? -0.96 : -1.2,
            height: 1.1,
          ),
        ),
      ),
    );
  }
}

class _RoleCard extends StatelessWidget {
  final bool isUser;
  final bool isSelected;
  final bool otherSelected;
  final Animation<double> fadeAnimation;
  final Animation<double> scaleAnimation;
  final VoidCallback onTap;

  const _RoleCard({
    required this.isUser,
    required this.isSelected,
    required this.otherSelected,
    required this.fadeAnimation,
    required this.scaleAnimation,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final bgColor = isUser ? AppColors.primaryBrown : AppColors.amberGold;
    final textColor = isUser ? AppColors.warmBeige : AppColors.black;
    final subtleColor = textColor.withValues(alpha: 0.5);
    final label = isUser ? 'member' : 'speaker';
    final title = isUser ? 'I seek\nguidance' : 'I guide\nothers';
    final subtitle = isUser
        ? 'connect with a\nspiritual guide'
        : 'counsel and\nspiritually lead';
    final imageAsset = isUser
        ? 'assets/Generated_Image_April_30__2026_-_10_05AM-removebg-preview.png'
        : 'assets/Generated_Image_April_30__2026_-_10_07AM-removebg-preview.png';

    return FadeTransition(
      opacity: fadeAnimation,
      child: ScaleTransition(
        scale: scaleAnimation,
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 200),
          opacity: otherSelected ? 0.4 : 1.0,
          child: AnimatedScale(
            scale: isSelected ? 0.97 : 1.0,
            duration: const Duration(milliseconds: 80),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final cardWidth = constraints.maxWidth;
                final innerWidth = cardWidth - 6;
                final iconAreaWidth = innerWidth * 0.45;
                final iconPlaceholderWidth = iconAreaWidth - 16;

                return GestureDetector(
                  onTap: onTap,
                  behavior: HitTestBehavior.opaque,
                  child: SizedBox(
                    width: cardWidth,
                    height: 196,
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Positioned(
                          bottom: 0,
                          left: isUser ? null : 0,
                          right: isUser ? 0 : null,
                          width: innerWidth,
                          height: 160,
                          child: Container(
                            decoration: BoxDecoration(
                              color: Colors.transparent,
                              borderRadius: BorderRadius.circular(24),
                              border: Border.all(
                                color: AppColors.primaryBrown,
                                width: 1.5,
                              ),
                            ),
                          ),
                        ),
                        Positioned(
                          top: 30,
                          left: isUser ? 0 : null,
                          right: isUser ? null : 0,
                          width: innerWidth,
                          height: 160,
                          child: Container(
                            decoration: BoxDecoration(
                              color: bgColor,
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Row(
                              children: isUser
                                  ? [
                                      SizedBox(width: iconAreaWidth),
                                      Expanded(
                                        child: Padding(
                                          padding: const EdgeInsets.only(
                                              right: 20),
                                          child: _CardText(
                                            label: label,
                                            title: title,
                                            subtitle: subtitle,
                                            textColor: textColor,
                                            subtleColor: subtleColor,
                                            alignRight: true,
                                          ),
                                        ),
                                      ),
                                    ]
                                  : [
                                      Expanded(
                                        child: Padding(
                                          padding: const EdgeInsets.only(
                                              left: 20),
                                          child: _CardText(
                                            label: label,
                                            title: title,
                                            subtitle: subtitle,
                                            textColor: textColor,
                                            subtleColor: subtleColor,
                                            alignRight: false,
                                          ),
                                        ),
                                      ),
                                      SizedBox(width: iconAreaWidth),
                                    ],
                            ),
                          ),
                        ),
                        Positioned(
                          top: 0,
                          left: isUser ? 16 : null,
                          right: isUser ? null : 16,
                          width: iconPlaceholderWidth,
                          height: 190,
                          child: _RoleIllustration(assetPath: imageAsset),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _CardText extends StatelessWidget {
  final String label;
  final String title;
  final String subtitle;
  final Color textColor;
  final Color subtleColor;
  final bool alignRight;

  const _CardText({
    required this.label,
    required this.title,
    required this.subtitle,
    required this.textColor,
    required this.subtleColor,
    required this.alignRight,
  });

  @override
  Widget build(BuildContext context) {
    final textAlign = alignRight ? TextAlign.right : TextAlign.left;
    final crossAxis =
        alignRight ? CrossAxisAlignment.end : CrossAxisAlignment.start;

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: crossAxis,
      children: [
        Text(
          label,
          style: GoogleFonts.inter(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.8,
            color: subtleColor,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          title,
          textAlign: textAlign,
          style: GoogleFonts.inter(
            fontSize: 22,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.44,
            height: 1.15,
            color: textColor,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          subtitle,
          textAlign: textAlign,
          style: GoogleFonts.inter(
            fontSize: 11,
            fontWeight: FontWeight.w300,
            letterSpacing: 0.22,
            color: subtleColor,
          ),
        ),
      ],
    );
  }
}

class _RoleIllustration extends StatelessWidget {
  final String assetPath;

  const _RoleIllustration({required this.assetPath});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Image.asset(
        assetPath,
        fit: BoxFit.contain,
        filterQuality: FilterQuality.high,
      ),
    );
  }
}

class _OrSeparator extends StatelessWidget {
  const _OrSeparator();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 20),
      child: Row(
        children: [
          Expanded(
            child: Container(
              height: 0.5,
              color: AppColors.primaryBrown.withValues(alpha: 0.15),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              'or',
              style: GoogleFonts.inter(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: AppColors.primaryBrown.withValues(alpha: 0.4),
              ),
            ),
          ),
          Expanded(
            child: Container(
              height: 0.5,
              color: AppColors.primaryBrown.withValues(alpha: 0.15),
            ),
          ),
        ],
      ),
    );
  }
}

class _CtaButton extends StatefulWidget {
  final bool enabled;
  final Animation<double> fadeAnimation;
  final Animation<Offset> slideAnimation;
  final VoidCallback onTap;

  const _CtaButton({
    required this.enabled,
    required this.fadeAnimation,
    required this.slideAnimation,
    required this.onTap,
  });

  @override
  State<_CtaButton> createState() => _CtaButtonState();
}

class _CtaButtonState extends State<_CtaButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: widget.fadeAnimation,
      child: SlideTransition(
        position: widget.slideAnimation,
        child: GestureDetector(
          onTapDown: widget.enabled
              ? (_) => setState(() => _pressed = true)
              : null,
          onTapUp: widget.enabled
              ? (_) => setState(() => _pressed = false)
              : null,
          onTapCancel: widget.enabled
              ? () => setState(() => _pressed = false)
              : null,
          onTap: widget.enabled ? widget.onTap : null,
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
                  color: AppColors.black,
                  borderRadius: BorderRadius.circular(28),
                ),
                child: Center(
                  child: RichText(
                    text: TextSpan(
                      children: [
                        TextSpan(
                          text: 'Continue ',
                          style: GoogleFonts.inter(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: AppColors.warmBeige,
                            letterSpacing: 0.15,
                          ),
                        ),
                        TextSpan(
                          text: '→',
                          style: GoogleFonts.inter(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: AppColors.amberGold,
                            letterSpacing: 0.15,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
