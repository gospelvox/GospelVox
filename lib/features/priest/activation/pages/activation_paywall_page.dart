// Activation paywall — one-time ₹X fee to unlock earning.
//
// Designed to feel like Apple's "Welcome to iCloud+" confirmation, not
// a traditional paywall: approval celebration badge, benefit list,
// clear pricing, single CTA. No up-sells, no urgency tricks, no
// countdown timers.
//
// Play Billing flow:
//   priest taps Activate → cubit.activate() → Play sheet opens
//   → IapService verifier round-trip → ActivationSuccess →
//   push to /priest/activation-success.
//
// The cubit owns the IapService subscription (Pattern A). The page
// is pure presentation — it renders state and dispatches a single
// `activate()` call. No native SDK lifecycle / callbacks to manage.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:gospel_vox/core/router/app_router.dart';
import 'package:gospel_vox/core/services/injection_container.dart';
import 'package:gospel_vox/core/theme/app_colors.dart';
import 'package:gospel_vox/core/widgets/app_snackbar.dart';
import 'package:gospel_vox/features/auth/data/auth_repository.dart';
import 'package:gospel_vox/features/priest/activation/bloc/activation_cubit.dart';
import 'package:gospel_vox/features/priest/activation/bloc/activation_state.dart';
import 'package:gospel_vox/core/widgets/app_icons.dart';

const Color _kSuccessGreen = Color(0xFF2E7D4F);

class ActivationPaywallPage extends StatelessWidget {
  const ActivationPaywallPage({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocProvider<ActivationCubit>(
      create: (_) => sl<ActivationCubit>()..loadFee(),
      child: const _ActivationPaywallView(),
    );
  }
}

class _ActivationPaywallView extends StatefulWidget {
  const _ActivationPaywallView();

  @override
  State<_ActivationPaywallView> createState() =>
      _ActivationPaywallViewState();
}

class _ActivationPaywallViewState extends State<_ActivationPaywallView>
    with SingleTickerProviderStateMixin {
  late final AnimationController _animController;
  late final Animation<double> _fadeAnim;
  late final Animation<Offset> _slideAnim;

  @override
  void initState() {
    super.initState();

    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _fadeAnim = CurvedAnimation(
      parent: _animController,
      curve: const Interval(0.0, 0.8, curve: Curves.easeOutCubic),
    );
    _slideAnim = Tween<Offset>(
      begin: const Offset(0, 0.06),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _animController,
      curve: Curves.easeOutCubic,
    ));
    _animController.forward();
  }

  @override
  void dispose() {
    _animController.dispose();
    super.dispose();
  }

  // ── Pay flow ────────────────────────────────────────────────────

  void _onActivateTap() {
    final cubit = context.read<ActivationCubit>();
    final state = cubit.state;
    // Defensive: only dispatch when the cubit is in Ready or Error.
    // ActivationVerifying / ActivationSuccess / ActivationInitial /
    // ActivationLoading should not trigger a buy attempt — the
    // button is already disabled in those states, but the gate
    // keeps a stale-state tap from racing the disable.
    if (state is! ActivationReady && state is! ActivationError) {
      return;
    }
    HapticFeedback.mediumImpact();
    cubit.activate();
  }

  // ── Sign-out escape hatch ───────────────────────────────────────

  Future<void> _signOutAndLeave() async {
    // Full repo sign-out so the FCM token gets pulled off priests/{uid}
    // and Google's cached account is dropped. The previous direct
    // FirebaseAuth.signOut() left both stuck on the device.
    clearCachedRole();
    await sl<AuthRepository>().signOut();
    if (!mounted) return;
    context.go('/select-role');
  }

  // ── Build ───────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<ActivationCubit, ActivationState>(
      listener: (ctx, state) {
        if (state is ActivationSuccess) {
          ctx.go('/priest/activation-success');
          return;
        }
        if (state is ActivationError) {
          // Every error is genuinely retryable under Play Billing
          // (no capture-before-verify race), so a single snackbar
          // is sufficient — the paywall stays interactive behind
          // it and the priest can tap Activate again.
          AppSnackBar.error(ctx, state.message);
        }
      },
      builder: (ctx, state) {
        final fee = switch (state) {
          ActivationReady s => s.fee,
          ActivationVerifying s => s.fee,
          ActivationError s => s.fee,
          _ => 500,
        };

        final isVerifying = state is ActivationVerifying;

        Widget body;
        if (state is ActivationLoading || state is ActivationInitial) {
          body = const _PaywallSkeleton();
        } else {
          body = _PaywallContent(
            fee: fee,
            isProcessing: isVerifying,
            isDisabled: isVerifying,
            onPay: _onActivateTap,
            onSignOut: _signOutAndLeave,
          );
        }

        return Scaffold(
          backgroundColor: AppColors.background,
          body: Stack(
            children: [
              SafeArea(
                child: FadeTransition(
                  opacity: _fadeAnim,
                  child: SlideTransition(
                    position: _slideAnim,
                    child: body,
                  ),
                ),
              ),
              if (isVerifying) const _VerificationOverlay(),
            ],
          ),
        );
      },
    );
  }
}

// ─── Main content ───────────────────────────────────────────────

class _PaywallContent extends StatelessWidget {
  final int fee;
  final bool isProcessing;
  final bool isDisabled;
  final VoidCallback onPay;
  final VoidCallback onSignOut;

  const _PaywallContent({
    required this.fee,
    required this.isProcessing,
    required this.isDisabled,
    required this.onPay,
    required this.onSignOut,
  });

  @override
  Widget build(BuildContext context) {
    final bottomPad = MediaQuery.of(context).padding.bottom;

    // Generous outer padding + big vertical gaps between sections.
    // The earlier iteration tried to sell with a benefits card, a
    // dark pricing hero, mini-props and an explanation banner. All
    // of that made the screen feel like a pitch; the priest already
    // knows what they're paying for. Whitespace + three lines + one
    // price feels more trustworthy than five cards.
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(28, 56, 28, bottomPad + 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Center(child: _ApprovedBadge()),
          const SizedBox(height: 36),

          Text(
            'One last step.',
            textAlign: TextAlign.center,
            style: GoogleFonts.inter(
              fontSize: 30,
              fontWeight: FontWeight.w800,
              color: AppColors.deepDarkBrown,
              letterSpacing: -0.6,
              height: 1.1,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'Activate to begin counseling\nand earning on Gospel Vox.',
            textAlign: TextAlign.center,
            style: GoogleFonts.inter(
              fontSize: 14,
              fontWeight: FontWeight.w400,
              color: AppColors.muted,
              height: 1.55,
            ),
          ),

          const SizedBox(height: 52),

          // Hero price with count-up animation.
          _PriceDisplay(fee: fee),

          const SizedBox(height: 48),

          // Three minimal benefit lines — no card, no subtitle noise.
          // Priests just read these in 2 seconds and move on.
          const _QuickBenefit(
            icon: AppIcons.chatOutline,
            label: 'Accept chat and voice sessions',
          ),
          const SizedBox(height: 18),
          const _QuickBenefit(
            icon: AppIcons.bible,
            label: 'Host Bible study groups',
          ),
          const SizedBox(height: 18),
          const _QuickBenefit(
            icon: AppIcons.wallet,
            label: 'Earn for every minute you serve',
          ),

          const SizedBox(height: 52),

          _PayButton(
            fee: fee,
            processing: isProcessing,
            disabled: isDisabled,
            onTap: onPay,
          ),

          const SizedBox(height: 16),
          const _SecureFooter(),

          const SizedBox(height: 24),
          Center(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onSignOut,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 10,
                ),
                child: Text(
                  'Not now',
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: AppColors.muted,
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

// ─── Small widgets ──────────────────────────────────────────────

class _ApprovedBadge extends StatelessWidget {
  const _ApprovedBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
      decoration: BoxDecoration(
        color: _kSuccessGreen.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: _kSuccessGreen.withValues(alpha: 0.15),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const AppIcon(
            AppIcons.checkCircle,
            size: 16,
            color: _kSuccessGreen,
          ),
          const SizedBox(width: 8),
          Text(
            'Application Approved',
            style: GoogleFonts.inter(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: _kSuccessGreen,
            ),
          ),
        ],
      ),
    );
  }
}

// Hero price. Count-up from 0 → fee gives the screen a single
// small moment of motion that draws attention to the number without
// pitching anything. No dark card, no gold accents, no mini-props —
// the typography itself does the heavy lifting.
class _PriceDisplay extends StatelessWidget {
  final int fee;
  const _PriceDisplay({required this.fee});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          'ONE-TIME ACTIVATION',
          style: GoogleFonts.inter(
            fontSize: 10,
            fontWeight: FontWeight.w600,
            color: AppColors.muted,
            letterSpacing: 1.8,
          ),
        ),
        const SizedBox(height: 14),
        TweenAnimationBuilder<int>(
          tween: IntTween(begin: 0, end: fee),
          duration: const Duration(milliseconds: 900),
          curve: Curves.easeOutCubic,
          builder: (_, value, _) {
            return RichText(
              textAlign: TextAlign.center,
              text: TextSpan(
                style: GoogleFonts.inter(
                  color: AppColors.deepDarkBrown,
                ),
                children: [
                  TextSpan(
                    text: '₹',
                    style: GoogleFonts.inter(
                      fontSize: 26,
                      fontWeight: FontWeight.w500,
                      color: AppColors.primaryBrown
                          .withValues(alpha: 0.65),
                    ),
                  ),
                  TextSpan(
                    text: value.toString(),
                    style: GoogleFonts.inter(
                      fontSize: 56,
                      fontWeight: FontWeight.w800,
                      color: AppColors.deepDarkBrown,
                      height: 1.0,
                      letterSpacing: -1.2,
                    ),
                  ),
                ],
              ),
            );
          },
        ),
        const SizedBox(height: 10),
        Text(
          'Lifetime access. No renewals.',
          textAlign: TextAlign.center,
          style: GoogleFonts.inter(
            fontSize: 12,
            fontWeight: FontWeight.w400,
            color: AppColors.muted,
          ),
        ),
      ],
    );
  }
}

// Minimal benefit row — no card, no subtitle. Just a warm brown
// icon chip and a single readable line. Three of these stacked
// read in about two seconds, which is all the "sell" this screen
// needs.
class _QuickBenefit extends StatelessWidget {
  final IconData icon;
  final String label;

  const _QuickBenefit({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: AppColors.primaryBrown.withValues(alpha: 0.07),
          ),
          child: AppIcon(
            icon,
            size: 18,
            color: AppColors.primaryBrown.withValues(alpha: 0.75),
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Text(
            label,
            style: GoogleFonts.inter(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: AppColors.deepDarkBrown,
              height: 1.3,
            ),
          ),
        ),
      ],
    );
  }
}

class _PayButton extends StatefulWidget {
  final int fee;
  final bool processing;
  final bool disabled;
  final VoidCallback onTap;

  const _PayButton({
    required this.fee,
    required this.processing,
    required this.disabled,
    required this.onTap,
  });

  @override
  State<_PayButton> createState() => _PayButtonState();
}

class _PayButtonState extends State<_PayButton>
    with SingleTickerProviderStateMixin {
  // Breathing pulse: scales the button by a max of ~1.5% over 2.4s
  // in/out. Slow enough that it reads as "alive" rather than
  // "urgent" — meant to feel like a warm, confident invitation,
  // not a flashing Buy Now banner. Pauses while the user is
  // pressing or while the button is disabled/processing.
  late final AnimationController _breath;
  bool _pressed = false;

  @override
  void initState() {
    super.initState();
    _breath = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _breath.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final enabled = !widget.disabled;

    return GestureDetector(
      onTapDown: enabled ? (_) => setState(() => _pressed = true) : null,
      onTapUp: enabled ? (_) => setState(() => _pressed = false) : null,
      onTapCancel:
          enabled ? () => setState(() => _pressed = false) : null,
      onTap: enabled ? widget.onTap : null,
      child: AnimatedBuilder(
        animation: _breath,
        builder: (_, child) {
          // Press beats breath — a mid-pulse tap should still feel
          // responsive rather than mushy.
          final breathT =
              Curves.easeInOutSine.transform(_breath.value);
          final breathScale = enabled && !widget.processing
              ? 1.0 + (0.014 * breathT)
              : 1.0;
          final pressScale = _pressed ? 0.97 : 1.0;
          return Transform.scale(
            scale: pressScale * breathScale,
            child: child,
          );
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          width: double.infinity,
          height: 56,
          decoration: BoxDecoration(
            color: enabled
                ? AppColors.primaryBrown
                : AppColors.muted.withValues(alpha: 0.25),
            borderRadius: BorderRadius.circular(16),
            boxShadow: enabled
                ? [
                    BoxShadow(
                      color: AppColors.primaryBrown
                          .withValues(alpha: 0.25),
                      blurRadius: 20,
                      offset: const Offset(0, 8),
                    ),
                  ]
                : const [],
          ),
          alignment: Alignment.center,
          child: widget.processing
              ? const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(
                    color: Colors.white,
                    strokeWidth: 2.5,
                  ),
                )
              : Text(
                  'Activate for ₹${widget.fee}',
                  style: GoogleFonts.inter(
                    fontSize: 16,
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

// Combined trust + refund line in one tiny footer. Keeps everything
// the priest needs to see (payment is secure + fee is non-refundable)
// without a separate scary banner earlier in the page.
class _SecureFooter extends StatelessWidget {
  const _SecureFooter();

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        AppIcon(
          AppIcons.lock,
          size: 12,
          color: AppColors.muted.withValues(alpha: 0.55),
        ),
        const SizedBox(width: 6),
        Text(
          'Secured by Google Play · Non-refundable',
          style: GoogleFonts.inter(
            fontSize: 11,
            fontWeight: FontWeight.w400,
            color: AppColors.muted.withValues(alpha: 0.65),
          ),
        ),
      ],
    );
  }
}

// Loading state — no shimmer (the real body is only ~300ms to load
// since we just read one Firestore doc). A centered brand-coloured
// spinner is more honest than animating fake content.
class _PaywallSkeleton extends StatelessWidget {
  const _PaywallSkeleton();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: SizedBox(
        width: 32,
        height: 32,
        child: CircularProgressIndicator(
          color: AppColors.primaryBrown,
          strokeWidth: 2.5,
        ),
      ),
    );
  }
}

// Full-screen block while the Play sheet is open / the CF verifies
// the purchase. Absorbs all pointer events so the priest can't
// accidentally back out mid-verify (which would leave the CF to
// finish in the background and the priest on a stale screen).
class _VerificationOverlay extends StatelessWidget {
  const _VerificationOverlay();

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: AbsorbPointer(
        child: Container(
          color: Colors.black.withValues(alpha: 0.4),
          child: Center(
            child: Container(
              width: 280,
              padding: const EdgeInsets.symmetric(
                horizontal: 28,
                vertical: 36,
              ),
              decoration: BoxDecoration(
                color: AppColors.surfaceWhite,
                borderRadius: BorderRadius.circular(24),
                boxShadow: [
                  BoxShadow(
                    blurRadius: 24,
                    offset: const Offset(0, 8),
                    color: Colors.black.withValues(alpha: 0.1),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(
                    width: 48,
                    height: 48,
                    child: CircularProgressIndicator(
                      color: AppColors.primaryBrown,
                      strokeWidth: 3.5,
                      strokeCap: StrokeCap.round,
                    ),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    'Activating your account...',
                    textAlign: TextAlign.center,
                    style: GoogleFonts.inter(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: AppColors.deepDarkBrown,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    "This will only take a moment.\nPlease don't close the app.",
                    textAlign: TextAlign.center,
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
          ),
        ),
      ),
    );
  }
}
