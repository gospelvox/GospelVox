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
import 'package:gospel_vox/core/widgets/app_icons.dart';
import 'package:gospel_vox/features/auth/bloc/auth_cubit.dart';
import 'package:gospel_vox/features/auth/bloc/auth_state.dart';
import 'package:gospel_vox/features/auth/widgets/admin_login_bottom_sheet.dart';
import 'package:gospel_vox/features/auth/widgets/demo_login_bottom_sheet.dart';
import 'package:gospel_vox/core/widgets/app_loading_widget.dart';

// Soft halo tint behind each card illustration.
const Color _kHalo = AppColors.backgroundPrimary;

// Soft green tint behind the privacy shield.
const Color _kShieldBg = Color(0xFFE4F0E7);

// Soft warm tint for the SELECTED card's inner surface. Swap this to
// try other looks:  cream #FAF5EC  ·  soft gold #FBF3E6.
const Color _kSelectedCardBg = Color(0xFFF7EFE7);

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
  //   'member'  = tap the Member ("I'm seeking guidance") card
  //   'speaker' = tap the Speaker ("I'm a spiritual guide") card
  //   'heading' = tap the "Choose your role" text
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

  // Store-reviewer email/password login, hidden behind a long-press on the
  // "GospelVox" wordmark. `outerContext` must be from below the AuthCubit
  // provider (the BlocBuilder's builder context) so the sheet can read the
  // shared cubit. The sheet routes itself by the account's real role.
  void _showDemoLogin(BuildContext outerContext) {
    HapticFeedback.mediumImpact();
    showModalBottomSheet<void>(
      context: outerContext,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => BlocProvider.value(
        value: outerContext.read<AuthCubit>(),
        child: const DemoLoginBottomSheet(),
      ),
    );
  }

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
    final small = screenWidth < 360;
    final pad = small ? 20.0 : 24.0;

    return BlocProvider(
      create: (_) => sl<AuthCubit>(),
      child: BlocBuilder<AuthCubit, AuthState>(
        builder: (context, state) {
          return Stack(
            children: [
              Scaffold(
                backgroundColor: AppColors.warmBeige,
                resizeToAvoidBottomInset: false,
                body: SafeArea(
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(pad, 16, pad, 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // Header + cards + privacy. Held in a clamping
                        // scroll view as a safety net: it sits still
                        // (no scroll) on a normal screen, and only on a
                        // very small phone will it scroll instead of
                        // overflowing. Sizes/spacing are unchanged.
                        Expanded(
                          child: SingleChildScrollView(
                            physics: const ClampingScrollPhysics(),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                // ── Logo + heading (animated) ──
                                FadeTransition(
                                  opacity: _headingFade,
                                  child: SlideTransition(
                                    position: _headingSlide,
                                    child: Column(
                                      children: [
                                        // Long-pressing the wordmark opens the
                                        // hidden store-reviewer email/password
                                        // login. A normal tap does nothing.
                                        GestureDetector(
                                          behavior: HitTestBehavior.opaque,
                                          onLongPress: () =>
                                              _showDemoLogin(context),
                                          child: const _Logo(),
                                        ),
                                        SizedBox(height: small ? 26 : 32),
                                        // "Choose your role" — heading AND
                                        // the hidden trigger's heading step
                                        // (tap area = glyphs only).
                                        Center(
                                          child: GestureDetector(
                                            onTap: () => _recordAdminTap(
                                                'heading', context),
                                            child: Text(
                                              'Choose your role',
                                              textAlign: TextAlign.center,
                                              style: GoogleFonts.playfairDisplay(
                                                fontSize: small ? 30 : 34,
                                                fontWeight: FontWeight.w700,
                                                color: AppColors.black,
                                                height: 1.05,
                                              ),
                                            ),
                                          ),
                                        ),
                                        const SizedBox(height: 10),
                                        Text(
                                          'This helps us personalise your '
                                          'experience.',
                                          textAlign: TextAlign.center,
                                          style: GoogleFonts.inter(
                                            fontSize: 13.5,
                                            fontWeight: FontWeight.w400,
                                            height: 1.4,
                                            color: AppColors.muted,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                                SizedBox(height: small ? 26 : 32),
                                // ── Role cards ──
                                _RoleCard(
                                  isUser: true,
                                  isSelected: _selectedRole == 'user',
                                  fade: _userFade,
                                  scale: _userScale,
                                  onTap: () {
                                    setState(() => _selectedRole = 'user');
                                    _recordAdminTap('member', context);
                                  },
                                ),
                                const SizedBox(height: 16),
                                _RoleCard(
                                  isUser: false,
                                  isSelected: _selectedRole == 'priest',
                                  fade: _speakerFade,
                                  scale: _speakerScale,
                                  onTap: () {
                                    setState(() => _selectedRole = 'priest');
                                    _recordAdminTap('speaker', context);
                                  },
                                ),
                                const SizedBox(height: 18),
                                // ── Privacy reassurance ──
                                FadeTransition(
                                  opacity: _ctaFade,
                                  child: const _PrivacyNote(),
                                ),
                                const SizedBox(height: 8),
                              ],
                            ),
                          ),
                        ),
                        // Fixed bottom — CTA (footer removed).
                        const SizedBox(height: 12),
                        FadeTransition(
                          opacity: _ctaFade,
                          child: SlideTransition(
                            position: _ctaSlide,
                            child: _ContinueButton(
                              enabled: _selectedRole != null,
                              onTap: _onContinue,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              if (state is AuthLoading)
                Container(
                  color: Colors.black.withValues(alpha: 0.3),
                  child: const Center(
                    child: AppLoader(),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

// ─── Logo (SVG mark + wordmark) ───────────────────────────────────

class _Logo extends StatelessWidget {
  const _Logo();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        'GospelVox',
        textAlign: TextAlign.center,
        style: GoogleFonts.playfairDisplay(
          fontSize: 22,
          fontWeight: FontWeight.w700,
          height: 1.0,
          color: AppColors.deepDarkBrown,
        ),
      ),
    );
  }
}

// ─── Role card ────────────────────────────────────────────────────

class _RoleCard extends StatelessWidget {
  final bool isUser;
  final bool isSelected;
  final Animation<double> fade;
  final Animation<double> scale;
  final VoidCallback onTap;

  const _RoleCard({
    required this.isUser,
    required this.isSelected,
    required this.fade,
    required this.scale,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final title = isUser ? "I'm seeking guidance" : "I'm a spiritual guide";
    final subtitle = isUser
        ? 'Connect with a spiritual guide for prayer and support.'
        : 'Counsel and spiritually lead others in faith.';
    final imageAsset = isUser
        ? 'assets/Generated_Image_April_30__2026_-_10_05AM-removebg-preview.png'
        : 'assets/Generated_Image_April_30__2026_-_10_07AM-removebg-preview.png';

    return FadeTransition(
      opacity: fade,
      child: ScaleTransition(
        scale: scale,
        child: GestureDetector(
          onTap: onTap,
          behavior: HitTestBehavior.opaque,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            padding: const EdgeInsets.fromLTRB(14, 16, 14, 16),
            decoration: BoxDecoration(
              color: isSelected ? _kSelectedCardBg : AppColors.surfaceWhite,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: isSelected
                    ? AppColors.primaryBrown
                    : AppColors.borderLight,
                width: isSelected ? 2 : 1,
              ),
              boxShadow: kWarmCardShadow,
            ),
            child: Stack(
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    // Illustration with a soft halo behind it.
                    SizedBox(
                      width: 124,
                      height: 152,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          Container(
                            width: 104,
                            height: 104,
                            decoration: const BoxDecoration(
                              color: _kHalo,
                              shape: BoxShape.circle,
                            ),
                          ),
                          Image.asset(
                            imageAsset,
                            height: 152,
                            fit: BoxFit.contain,
                            filterQuality: FilterQuality.high,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Padding(
                        // Keep the title clear of the corner tick.
                        padding: const EdgeInsets.only(right: 22),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              title,
                              style: GoogleFonts.playfairDisplay(
                                fontSize: 19,
                                fontWeight: FontWeight.w700,
                                height: 1.15,
                                color: AppColors.deepDarkBrown,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              subtitle,
                              style: GoogleFonts.inter(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w400,
                                height: 1.4,
                                color: AppColors.muted,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
                // Tick in the top-right corner of the card.
                Positioned(
                  top: 0,
                  right: 0,
                  child: _SelectionDot(selected: isSelected),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SelectionDot extends StatelessWidget {
  final bool selected;
  const _SelectionDot({required this.selected});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 26,
      height: 26,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: selected ? AppColors.primaryBrown : AppColors.surfaceWhite,
        border: Border.all(
          color: selected ? AppColors.primaryBrown : AppColors.borderLight,
          width: 1.5,
        ),
      ),
      child: selected
          ? const Center(
              child: AppIcon(AppIcons.check, size: 12, color: Colors.white),
            )
          : null,
    );
  }
}

// ─── Privacy note ─────────────────────────────────────────────────

class _PrivacyNote extends StatelessWidget {
  const _PrivacyNote();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: AppColors.surfaceCream,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.borderLight),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 30,
            height: 30,
            decoration: const BoxDecoration(
              color: _kShieldBg,
              shape: BoxShape.circle,
            ),
            child: AppIcon(AppIcons.shield, size: 14, color: AppColors.sageOnline),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Your privacy is protected',
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: AppColors.deepDarkBrown,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'We respect your privacy and keep your information secure.',
                  style: GoogleFonts.inter(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w400,
                    height: 1.35,
                    color: AppColors.muted,
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

// ─── Continue button ──────────────────────────────────────────────

class _ContinueButton extends StatefulWidget {
  final bool enabled;
  final VoidCallback onTap;

  const _ContinueButton({required this.enabled, required this.onTap});

  @override
  State<_ContinueButton> createState() => _ContinueButtonState();
}

class _ContinueButtonState extends State<_ContinueButton> {
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
      child: AnimatedScale(
        scale: _pressed ? 0.98 : 1.0,
        duration: const Duration(milliseconds: 80),
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 200),
          opacity: widget.enabled ? 1.0 : 0.5,
          child: Container(
            width: double.infinity,
            height: 56,
            decoration: BoxDecoration(
              color: AppColors.primaryBrown,
              borderRadius: BorderRadius.circular(18),
              boxShadow: widget.enabled
                  ? [
                      BoxShadow(
                        color: AppColors.primaryBrown.withValues(alpha: 0.25),
                        blurRadius: 14,
                        offset: const Offset(0, 6),
                      ),
                    ]
                  : null,
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  'Continue',
                  style: GoogleFonts.inter(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(width: 10),
                AppIcon(AppIcons.arrowRight, size: 14, color: Colors.white),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
