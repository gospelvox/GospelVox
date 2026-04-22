// Activation paywall — one-time ₹X fee to unlock earning.
//
// Designed to feel like Apple's "Welcome to iCloud+" confirmation, not
// a traditional paywall: approval celebration badge, benefit list,
// clear pricing, single CTA. No up-sells, no urgency tricks, no
// countdown timers.
//
// Razorpay flow matches the wallet pattern exactly:
//   createActivationOrder (CF) → open Razorpay → verifyActivationFee
//     (CF, HMAC-verified) → emit Success → push success page.
//
// The cubit owns state; this page owns the native Razorpay SDK
// lifecycle and the Razorpay callbacks.

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:razorpay_flutter/razorpay_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:gospel_vox/core/router/app_router.dart';
import 'package:gospel_vox/core/services/injection_container.dart';
import 'package:gospel_vox/core/services/razorpay_service.dart';
import 'package:gospel_vox/core/theme/app_colors.dart';
import 'package:gospel_vox/core/widgets/app_snackbar.dart';
import 'package:gospel_vox/features/priest/activation/bloc/activation_cubit.dart';
import 'package:gospel_vox/features/priest/activation/bloc/activation_state.dart';
import 'package:gospel_vox/features/user/wallet/widgets/payment_failure_sheet.dart';

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
  late final RazorpayService _razorpay;
  late final AnimationController _animController;
  late final Animation<double> _fadeAnim;
  late final Animation<Offset> _slideAnim;

  // Razorpay returns the orderId back to us in the success callback,
  // but we also cache it here so a verify-time crash still has it
  // available for the support-reference string.
  String? _pendingOrderId;

  // Guards against a rapid second tap on the Pay button before the
  // cubit's isPaymentInProgress flag has flipped. Synchronous bool,
  // set before the first async call, cleared on failure paths.
  bool _payTapLocked = false;

  // Latest paymentId across callbacks — surfaced in the failure sheet
  // so support can find the attempt in Razorpay's dashboard.
  String? _lastPaymentId;

  @override
  void initState() {
    super.initState();
    _razorpay = RazorpayService();
    _razorpay.init();
    _razorpay.onSuccess = _onPaymentSuccess;
    _razorpay.onFailure = _onPaymentFailure;
    _razorpay.onWallet = _onExternalWallet;

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
    _razorpay.dispose();
    _animController.dispose();
    super.dispose();
  }

  // ── Razorpay callbacks ──────────────────────────────────────────

  void _onPaymentSuccess(PaymentSuccessResponse response) {
    _payTapLocked = false;
    final paymentId = response.paymentId;
    final orderId = response.orderId ?? _pendingOrderId;
    final signature = response.signature;

    if (paymentId == null || orderId == null || signature == null) {
      // Razorpay sent back a malformed response — this shouldn't
      // happen in practice but we'd rather surface a clear error
      // than silently activate.
      if (!mounted) return;
      AppSnackBar.error(
        context,
        'Payment captured but verification data is missing. '
        'Contact support if you were charged.',
      );
      context.read<ActivationCubit>().setPaymentInProgress(false);
      return;
    }

    _lastPaymentId = paymentId;
    context.read<ActivationCubit>().verifyPayment(
          razorpayPaymentId: paymentId,
          razorpayOrderId: orderId,
          razorpaySignature: signature,
        );
  }

  void _onPaymentFailure(PaymentFailureResponse response) {
    _payTapLocked = false;
    _lastPaymentId = null;

    // Reset cubit so the Pay button becomes interactive again.
    context.read<ActivationCubit>().setPaymentInProgress(false);

    // Razorpay code 2 means the user cancelled (closed the sheet,
    // hit back). Not an error — don't show the failure sheet.
    if (response.code == 2) return;

    if (!mounted) return;
    _showPaymentFailure(null);
  }

  void _onExternalWallet(ExternalWalletResponse response) {
    // External-wallet flow isn't wired end-to-end (see RazorpayService
    // for the rationale). Log for debugging.
    debugPrint('[Activation] External wallet: ${response.walletName}');
  }

  Future<void> _showPaymentFailure(String? paymentId) async {
    final retry = await PaymentFailureSheet.show(
      context,
      paymentId: paymentId ?? _lastPaymentId,
    );
    if (retry == true && mounted) {
      context.read<ActivationCubit>().resetForRetry();
      _proceedToPay();
    }
  }

  // ── Pay flow ────────────────────────────────────────────────────

  Future<void> _proceedToPay() async {
    if (_payTapLocked) return;
    _payTapLocked = true;

    final cubit = context.read<ActivationCubit>();
    final state = cubit.state;
    if (state is! ActivationReady || state.isPaymentInProgress) {
      _payTapLocked = false;
      return;
    }

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      _payTapLocked = false;
      AppSnackBar.error(context, 'Please sign in again to continue.');
      return;
    }

    cubit.setPaymentInProgress(true);

    // Force-refresh the Firebase ID token before calling the CF.
    // Prevents Samsung-style aggressive background freezing from
    // sending a stale token that the CF would reject as
    // unauthenticated.
    try {
      await user.getIdToken(true);
    } catch (e) {
      debugPrint('[Activation] Token refresh failed: $e');
      if (!mounted) return;
      _payTapLocked = false;
      cubit.setPaymentInProgress(false);
      AppSnackBar.error(
        context,
        "Couldn't verify your session. Sign out and sign in, then retry.",
      );
      return;
    }

    final order = await cubit.createOrder();
    if (!mounted) return;
    if (order == null) {
      _payTapLocked = false;
      cubit.setPaymentInProgress(false);
      AppSnackBar.error(
        context,
        "Couldn't start payment. Please try again in a moment.",
      );
      return;
    }

    _pendingOrderId = order.orderId;

    _razorpay.openCheckout(
      razorpayOrderId: order.orderId,
      amountInPaise: order.amountPaise,
      description: 'Gospel Vox Speaker Activation',
      userEmail: user.email ?? '',
      userName: user.displayName ?? '',
    );
    // _payTapLocked stays true here until Razorpay fires a callback —
    // that's the point: the sheet is open, no second-tap paths exist.
  }

  // ── Sign-out escape hatch ───────────────────────────────────────

  Future<void> _signOutAndLeave() async {
    await FirebaseAuth.instance.signOut();
    clearCachedRole();
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
          _payTapLocked = false;
          // After-capture errors do NOT get a snackbar or the
          // PaymentFailureSheet — the builder below swaps the whole
          // screen for a dedicated stuck-screen with no pay path.
          // Showing the failure sheet here would offer a Retry
          // button that triggers a SECOND Razorpay charge, since
          // the user's money is already captured in Razorpay but
          // our server-side verification failed.
          //
          // Pre-capture errors (fee load fail, order create fail)
          // still surface as a snackbar and leave the page
          // interactive — those can be genuinely retried without
          // double-charging.
          if (!state.afterCapture) {
            AppSnackBar.error(ctx, state.message);
          }
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
        final isPaymentInProgress =
            state is ActivationReady && state.isPaymentInProgress;

        // After-capture failure is TERMINAL in this session: the
        // priest's ₹500 is captured in Razorpay, the server-side
        // verification failed. We must NOT render anything that
        // could lead to a second Razorpay.open() — so we swap the
        // entire body for a stuck-screen with support-only actions.
        // The original paywall is gone; there is no pay button, no
        // retry, no "just try again" path.
        final isAfterCapture =
            state is ActivationError && state.afterCapture;

        Widget body;
        if (isAfterCapture) {
          body = _PaymentStuckScreen(
            paymentId: state.paymentId,
            message: state.message,
            onSignOut: _signOutAndLeave,
          );
        } else if (state is ActivationLoading ||
            state is ActivationInitial) {
          body = const _PaywallSkeleton();
        } else {
          body = _PaywallContent(
            fee: fee,
            isProcessing: isPaymentInProgress || isVerifying,
            isDisabled: isPaymentInProgress || isVerifying,
            onPay: _proceedToPay,
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
            icon: Icons.chat_bubble_outline_rounded,
            label: 'Accept chat and voice sessions',
          ),
          const SizedBox(height: 18),
          const _QuickBenefit(
            icon: Icons.menu_book_outlined,
            label: 'Host Bible study groups',
          ),
          const SizedBox(height: 18),
          const _QuickBenefit(
            icon: Icons.account_balance_wallet_outlined,
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
          const Icon(
            Icons.check_circle_rounded,
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
          child: Icon(
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
        Icon(
          Icons.lock_outline,
          size: 12,
          color: AppColors.muted.withValues(alpha: 0.55),
        ),
        const SizedBox(width: 6),
        Text(
          'Secured by Razorpay · Non-refundable',
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

// Terminal-state screen shown when Razorpay captured the priest's
// payment but our server-side verification failed.
//
// The entire paywall body is replaced by this — NO pay button, NO
// retry option, NO path back to Razorpay.open() — because the
// priest's ₹500 is already with Razorpay. Any re-pay flow would
// create a duplicate charge.
//
// Tone is calm and reassuring, not scary: amber (not red) icon,
// "Payment Received" headline (not "Payment Failed"), message that
// emphasises the payment is safe and support is involved.
class _PaymentStuckScreen extends StatelessWidget {
  final String? paymentId;
  final String message;
  final VoidCallback onSignOut;

  const _PaymentStuckScreen({
    required this.paymentId,
    required this.message,
    required this.onSignOut,
  });

  // Copying the reference is the single highest-value gesture a
  // stuck priest can make — it's what they'll paste into support.
  // Doing it as a tap on the reference pill (not a separate "Copy"
  // button) keeps the UI minimal.
  Future<void> _copyReference(BuildContext context) async {
    final id = paymentId;
    if (id == null || id.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: id));
    if (!context.mounted) return;
    AppSnackBar.info(context, 'Reference copied to clipboard');
  }

  // Opens the system mail client with the subject, body, and the
  // payment reference pre-filled — priest shouldn't have to retype
  // anything. Fails softly with a snackbar if no mail client is
  // installed (unlikely but possible on some emulators).
  Future<void> _contactSupport(BuildContext context) async {
    final ref = paymentId ?? '(not available)';
    final uri = Uri(
      scheme: 'mailto',
      path: 'support@gospelvox.com',
      queryParameters: {
        'subject': 'Activation payment issue',
        'body': 'Hi,\n\n'
            'My activation payment was captured but activation '
            'did not complete.\n\n'
            'Payment reference: $ref\n',
      },
    );
    try {
      final launched = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
      if (!launched && context.mounted) {
        AppSnackBar.error(
          context,
          'Could not open email. Write to support@gospelvox.com '
          'with reference: $ref',
        );
      }
    } catch (_) {
      if (context.mounted) {
        AppSnackBar.error(
          context,
          'Could not open email. Write to support@gospelvox.com '
          'with reference: $ref',
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomPad = MediaQuery.of(context).padding.bottom;
    final hasRef = paymentId != null && paymentId!.isNotEmpty;

    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(28, 56, 28, bottomPad + 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 88,
              height: 88,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.amberGold.withValues(alpha: 0.12),
              ),
              child: const Icon(
                Icons.mark_email_read_outlined,
                size: 40,
                color: AppColors.amberGold,
              ),
            ),
          ),
          const SizedBox(height: 28),
          Text(
            'Payment Received',
            textAlign: TextAlign.center,
            style: GoogleFonts.inter(
              fontSize: 26,
              fontWeight: FontWeight.w800,
              color: AppColors.deepDarkBrown,
              letterSpacing: -0.4,
              height: 1.1,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            "We've received your payment but couldn't complete "
            "activation automatically. Our team will sort this out "
            "for you within a few hours.",
            textAlign: TextAlign.center,
            style: GoogleFonts.inter(
              fontSize: 14,
              fontWeight: FontWeight.w400,
              color: AppColors.muted,
              height: 1.55,
            ),
          ),
          const SizedBox(height: 36),

          if (hasRef) ...[
            Center(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => _copyReference(context),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 14,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.surfaceWhite,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: AppColors.muted.withValues(alpha: 0.15),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'PAYMENT REFERENCE',
                        style: GoogleFonts.inter(
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                          color: AppColors.muted,
                          letterSpacing: 1.4,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Flexible(
                            child: Text(
                              paymentId!,
                              style: GoogleFonts.inter(
                                fontSize: 14,
                                fontWeight: FontWeight.w500,
                                color: AppColors.deepDarkBrown,
                                letterSpacing: 0.2,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Icon(
                            Icons.copy_outlined,
                            size: 14,
                            color: AppColors.muted
                                .withValues(alpha: 0.7),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Center(
              child: Text(
                'Tap to copy · share with support',
                style: GoogleFonts.inter(
                  fontSize: 11,
                  fontWeight: FontWeight.w400,
                  color: AppColors.muted.withValues(alpha: 0.75),
                ),
              ),
            ),
            const SizedBox(height: 40),
          ] else ...[
            const SizedBox(height: 20),
          ],

          _StuckPrimaryButton(
            label: 'Contact Support',
            onTap: () => _contactSupport(context),
          ),
          const SizedBox(height: 10),
          Center(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onSignOut,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 14,
                ),
                child: Text(
                  'Sign out',
                  style: GoogleFonts.inter(
                    fontSize: 14,
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

class _StuckPrimaryButton extends StatefulWidget {
  final String label;
  final VoidCallback onTap;

  const _StuckPrimaryButton({required this.label, required this.onTap});

  @override
  State<_StuckPrimaryButton> createState() => _StuckPrimaryButtonState();
}

class _StuckPrimaryButtonState extends State<_StuckPrimaryButton> {
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
          height: 54,
          decoration: BoxDecoration(
            color: AppColors.primaryBrown,
            borderRadius: BorderRadius.circular(14),
            boxShadow: [
              BoxShadow(
                color: AppColors.primaryBrown.withValues(alpha: 0.22),
                blurRadius: 16,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          alignment: Alignment.center,
          child: Text(
            widget.label,
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

// Full-screen block while the CF verifies the payment. Absorbs all
// pointer events so the priest can't accidentally back out mid-
// verify (which would leave the CF to finish in the background and
// the priest on a stale screen).
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
