// Activation success screen.
//
// A short celebratory confirmation — the priest just paid money, so
// we want the "you're in" moment to feel earned, not just a page
// swap. Animated check-ring first, then a calm summary of what's
// now possible, then a clear CTA to the dashboard.
//
// Back navigation is disabled via PopScope: nothing the priest does
// here should revisit the paywall (it'd try to create a second
// Razorpay order for an already-activated account).

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:gospel_vox/core/theme/app_colors.dart';

const Color _kSuccessGreen = Color(0xFF2E7D4F);
const Color _kSuccessGreenLight = Color(0xFF3A9D63);

class ActivationSuccessPage extends StatefulWidget {
  const ActivationSuccessPage({super.key});

  @override
  State<ActivationSuccessPage> createState() => _ActivationSuccessPageState();
}

class _ActivationSuccessPageState extends State<ActivationSuccessPage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _scaleAnim;
  late final Animation<double> _fadeAnim;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );

    // Icon scales up with a little overshoot — tiny spring feel
    // without going full cartoonish.
    _scaleAnim = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.0, 0.5, curve: Curves.easeOutBack),
      ),
    );

    // Everything else fades in after the icon settles.
    _fadeAnim = CurvedAnimation(
      parent: _controller,
      curve: const Interval(0.3, 1.0, curve: Curves.easeOutCubic),
    );

    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bottomPad = MediaQuery.of(context).padding.bottom;

    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: AppColors.background,
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Column(
              children: [
                const Spacer(flex: 3),
                ScaleTransition(
                  scale: _scaleAnim,
                  child: Container(
                    width: 96,
                    height: 96,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: const LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [_kSuccessGreen, _kSuccessGreenLight],
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: _kSuccessGreen.withValues(alpha: 0.25),
                          blurRadius: 24,
                          offset: const Offset(0, 8),
                        ),
                      ],
                    ),
                    child: const Icon(
                      Icons.check_rounded,
                      size: 48,
                      color: Colors.white,
                    ),
                  ),
                ),
                const SizedBox(height: 32),
                FadeTransition(
                  opacity: _fadeAnim,
                  child: Column(
                    children: [
                      Text(
                        "You're Activated!",
                        textAlign: TextAlign.center,
                        style: GoogleFonts.inter(
                          fontSize: 24,
                          fontWeight: FontWeight.w800,
                          color: AppColors.deepDarkBrown,
                          letterSpacing: -0.3,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        'Your speaker account is now active. '
                        'You can start accepting sessions and '
                        'earning on Gospel Vox.',
                        textAlign: TextAlign.center,
                        style: GoogleFonts.inter(
                          fontSize: 14,
                          fontWeight: FontWeight.w400,
                          color: AppColors.muted,
                          height: 1.6,
                        ),
                      ),
                      const SizedBox(height: 36),
                      const _HighlightsCard(),
                    ],
                  ),
                ),
                const Spacer(flex: 4),
                FadeTransition(
                  opacity: _fadeAnim,
                  child: _CtaButton(
                    onTap: () => context.go('/priest'),
                  ),
                ),
                SizedBox(height: bottomPad + 24),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _HighlightsCard extends StatelessWidget {
  const _HighlightsCard();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.surfaceWhite,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: AppColors.muted.withValues(alpha: 0.08),
        ),
      ),
      child: const Column(
        children: [
          _HighlightRow(
            icon: Icons.wifi_tethering_rounded,
            text: "You'll appear online when the app is open",
          ),
          SizedBox(height: 14),
          _HighlightRow(
            icon: Icons.notifications_none_rounded,
            text: "You'll receive notifications for new requests",
          ),
          SizedBox(height: 14),
          _HighlightRow(
            icon: Icons.account_balance_wallet_outlined,
            text: 'Earnings are added to your wallet after each session',
          ),
        ],
      ),
    );
  }
}

class _HighlightRow extends StatelessWidget {
  final IconData icon;
  final String text;
  const _HighlightRow({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          icon,
          size: 18,
          color: AppColors.primaryBrown.withValues(alpha: 0.6),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            text,
            style: GoogleFonts.inter(
              fontSize: 13,
              fontWeight: FontWeight.w400,
              color: AppColors.muted,
              height: 1.4,
            ),
          ),
        ),
      ],
    );
  }
}

class _CtaButton extends StatefulWidget {
  final VoidCallback onTap;
  const _CtaButton({required this.onTap});

  @override
  State<_CtaButton> createState() => _CtaButtonState();
}

class _CtaButtonState extends State<_CtaButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _pressed ? 0.97 : 1.0,
        duration: const Duration(milliseconds: 120),
        child: Container(
          width: double.infinity,
          height: 56,
          decoration: BoxDecoration(
            color: AppColors.primaryBrown,
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: AppColors.primaryBrown.withValues(alpha: 0.25),
                blurRadius: 16,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          alignment: Alignment.center,
          child: Text(
            'Start Accepting Requests',
            style: GoogleFonts.inter(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: Colors.white,
              letterSpacing: 0.2,
            ),
          ),
        ),
      ),
    );
  }
}
