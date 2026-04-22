// Bottom sheet shown when a payment flow fails.
//
// Why not a SnackBar: users just saw money leave their account (or a
// "declined" banner in Razorpay). A transient top-snack disappearing
// after 3 seconds actively increases anxiety — "did my money vanish?"
// A modal sheet that explicitly reassures about refund timelines and
// surfaces a support-traceable reference lets the user sit with the
// failure for as long as they need.

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:gospel_vox/core/theme/app_colors.dart';

class PaymentFailureSheet {
  PaymentFailureSheet._();

  /// Returns `true` when the user tapped **Retry Payment**, `false`
  /// (or `null`) otherwise — drag-dismiss, Contact Support, system
  /// back. Callers should treat anything other than `true` as
  /// "don't auto-reopen Razorpay".
  static Future<bool?> show(
    BuildContext context, {
    String? paymentId,
  }) {
    return showModalBottomSheet<bool>(
      context: context,
      backgroundColor: Colors.transparent,
      // Scroll-controlled so the sheet sizes itself to content and
      // would correctly lift above the keyboard if we ever add a
      // text input (e.g. a "contact support" note) inside.
      isScrollControlled: true,
      builder: (ctx) => _PaymentFailureBody(paymentId: paymentId),
    );
  }
}

class _PaymentFailureBody extends StatelessWidget {
  final String? paymentId;

  const _PaymentFailureBody({required this.paymentId});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.surfaceWhite,
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(24),
          topRight: Radius.circular(24),
        ),
      ),
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
      child: Column(
        mainAxisSize: MainAxisSize.min,
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
          const SizedBox(height: 28),
          // Concentric circles in the error tone. Nested rings feel
          // more deliberate than a single flat disc and give the icon
          // a small visual cushion, which matches the "we're handling
          // it calmly" tone.
          Center(
            child: Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.errorRed.withValues(alpha: 0.08),
              ),
              child: Center(
                child: Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: AppColors.errorRed.withValues(alpha: 0.12),
                  ),
                  child: const Icon(
                    Icons.close_rounded,
                    size: 28,
                    color: AppColors.errorRed,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 24),
          Center(
            child: Text(
              "Payment Failed",
              style: GoogleFonts.inter(
                fontSize: 20,
                fontWeight: FontWeight.w700,
                color: AppColors.deepDarkBrown,
                letterSpacing: -0.2,
              ),
            ),
          ),
          const SizedBox(height: 10),
          // The refund timing line is intentionally specific ("4-7
          // working days") rather than vague ("soon") — specificity
          // is what turns anxiety into patience.
          Center(
            child: Text(
              "Don't worry! If your amount was debited, it will be "
              "refunded to your original payment method within 4-7 "
              "working days.",
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(
                fontSize: 13,
                fontWeight: FontWeight.w400,
                color: AppColors.muted,
                height: 1.5,
              ),
            ),
          ),
          if (paymentId != null) ...[
            const SizedBox(height: 12),
            Center(
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: AppColors.background,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  "Ref: $paymentId",
                  style: GoogleFonts.inter(
                    fontSize: 11,
                    fontWeight: FontWeight.w400,
                    color: AppColors.muted,
                  ),
                ),
              ),
            ),
          ],
          const SizedBox(height: 28),
          _RetryButton(
            onTap: () => Navigator.pop(context, true),
          ),
          const SizedBox(height: 12),
          _ContactSupportLink(
            onTap: () => Navigator.pop(context, false),
          ),
          // Bottom padding respects the home-indicator / gesture bar
          // so the support link isn't tucked under it on modern phones.
          SizedBox(height: MediaQuery.of(context).padding.bottom + 20),
        ],
      ),
    );
  }
}

class _RetryButton extends StatefulWidget {
  final VoidCallback onTap;

  const _RetryButton({required this.onTap});

  @override
  State<_RetryButton> createState() => _RetryButtonState();
}

class _RetryButtonState extends State<_RetryButton> {
  double _scale = 1.0;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _scale = 0.97),
      onTapUp: (_) => setState(() => _scale = 1.0),
      onTapCancel: () => setState(() => _scale = 1.0),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _scale,
        duration: const Duration(milliseconds: 100),
        child: Container(
          width: double.infinity,
          height: 52,
          decoration: BoxDecoration(
            color: AppColors.primaryBrown,
            borderRadius: BorderRadius.circular(14),
            boxShadow: [
              BoxShadow(
                color: AppColors.primaryBrown.withValues(alpha: 0.2),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Center(
            child: Text(
              "Retry Payment",
              style: GoogleFonts.inter(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: Colors.white,
                letterSpacing: 0.1,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ContactSupportLink extends StatefulWidget {
  final VoidCallback onTap;

  const _ContactSupportLink({required this.onTap});

  @override
  State<_ContactSupportLink> createState() => _ContactSupportLinkState();
}

class _ContactSupportLinkState extends State<_ContactSupportLink> {
  double _scale = 1.0;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _scale = 0.97),
      onTapUp: (_) => setState(() => _scale = 1.0),
      onTapCancel: () => setState(() => _scale = 1.0),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _scale,
        duration: const Duration(milliseconds: 100),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 8,
            ),
            child: Text(
              "Contact Support",
              style: GoogleFonts.inter(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: AppColors.muted,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
