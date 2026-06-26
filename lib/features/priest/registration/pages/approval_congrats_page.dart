// Application-approved congratulations screen.
//
// Shown exactly once, the first time a priest reaches the "approved"
// state — whether they were sitting on the "Under Review" screen when
// the admin approved (the pending page's live listener routes here) or
// they cold-start the app after approval (the router routes here). A
// persistent SharedPreferences flag (set on Continue) guarantees it
// never shows twice. See _resolvePriestDestination + markApproval
// CongratsSeen in app_router.dart.
//
// Note: approval is NOT activation. An approved priest still completes
// activation to go online — so the CTA lands on the dashboard, where the
// activation gate lives at action points, rather than implying they're
// fully live.
//
// Back navigation is disabled via PopScope: there's nothing useful
// behind this screen (the pending page they came from no longer applies).

import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:gospel_vox/core/router/app_router.dart';
import 'package:gospel_vox/core/theme/app_colors.dart';
import 'package:gospel_vox/core/widgets/app_icons.dart';

const Color _kSuccessGreen = AppColors.successGreen;
const Color _kSuccessGreenLight = Color(0xFF3A9D63);

class ApprovalCongratsPage extends StatefulWidget {
  const ApprovalCongratsPage({super.key});

  @override
  State<ApprovalCongratsPage> createState() => _ApprovalCongratsPageState();
}

class _ApprovalCongratsPageState extends State<ApprovalCongratsPage>
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
    _scaleAnim = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.0, 0.5, curve: Curves.easeOutBack),
      ),
    );
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

  Future<void> _continue() async {
    // Mark seen BEFORE navigating so the router's approved-state
    // resolution sends them to the dashboard (not back here) from now on.
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid != null) {
      await markApprovalCongratsSeen(uid);
    }
    if (!mounted) return;
    context.go('/priest');
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
                    child: const AppIcon(
                      AppIcons.check,
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
                        "You're Approved!",
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
                        'Congratulations! Your speaker application has been '
                        'approved. Complete your activation to start '
                        'accepting sessions and earning on Gospel Vox.',
                        textAlign: TextAlign.center,
                        style: GoogleFonts.inter(
                          fontSize: 14,
                          fontWeight: FontWeight.w400,
                          color: AppColors.muted,
                          height: 1.6,
                        ),
                      ),
                      const SizedBox(height: 36),
                      const _NextStepsCard(),
                    ],
                  ),
                ),
                const Spacer(flex: 4),
                FadeTransition(
                  opacity: _fadeAnim,
                  child: _CtaButton(onTap: _continue),
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

class _NextStepsCard extends StatelessWidget {
  const _NextStepsCard();

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
          _StepRow(
            icon: AppIcons.userOutline,
            text: 'Review and complete your speaker profile',
          ),
          SizedBox(height: 14),
          _StepRow(
            icon: AppIcons.wallet,
            text: 'Activate your account to start accepting sessions',
          ),
          SizedBox(height: 14),
          _StepRow(
            icon: AppIcons.wifi,
            text: "You'll appear online whenever the app is open",
          ),
        ],
      ),
    );
  }
}

class _StepRow extends StatelessWidget {
  final IconData icon;
  final String text;
  const _StepRow({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AppIcon(
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
            'Continue to Dashboard',
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
