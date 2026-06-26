// Full-screen overlay shown while the server verifies a completed
// Play Billing purchase.
//
// Why a full-screen modal rather than an inline spinner on the Pay
// button: between the Play sheet closing and the CF returning with a
// new balance, the user is in the most anxious ~3 seconds of the flow
// — money has left their account but nothing has been credited yet.
// Blocking the whole surface (AbsorbPointer + the wallet's PopScope)
// prevents accidental back-taps that would navigate away from the
// in-flight verification, and gives unambiguous "we've got it" feedback.
//
// The visual is a deliberately calm, trust-forward "secure verification"
// card: a slim brand-brown progress ring sweeping around a security
// shield. No coin / no gold accent here — at the money-leaving moment
// the language is security and reassurance, not celebration (that's the
// PaymentSuccessPage's job once coins are credited).

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:gospel_vox/core/theme/app_colors.dart';
import 'package:gospel_vox/core/widgets/app_icons.dart';

class PaymentProcessingOverlay extends StatelessWidget {
  const PaymentProcessingOverlay({super.key});

  @override
  Widget build(BuildContext context) {
    // AbsorbPointer so the scrim actually blocks taps to the wallet
    // beneath it (a bare coloured Container does not) — otherwise the
    // floating Pay button can still be tapped through the dim layer.
    //
    // Material(transparency) is required: this overlay is a sibling of
    // the wallet's Scaffold (not a child), so its Text widgets have no
    // Material ancestor and would otherwise inherit the framework's
    // fallback style — the debug yellow-and-black underline. The
    // transparent Material paints nothing but gives the subtree a clean
    // text context so that underline never shows.
    return AbsorbPointer(
      child: Material(
        type: MaterialType.transparency,
        child: Container(
          // A deeper scrim than a passing dialog uses — this is a money
          // moment, so the dim focuses the eye on the card and reads as a
          // proper modal, not a transient toast. The wallet stays faintly
          // visible so the user keeps their place.
          color: AppColors.deepDarkBrown.withValues(alpha: 0.55),
          child: Center(
            // Gentle pop-in (fade + slight scale) so the card arrives with
            // intent instead of snapping on. Self-driving — no controller
            // to manage.
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: 0.0, end: 1.0),
              duration: const Duration(milliseconds: 260),
              curve: Curves.easeOutCubic,
              builder: (context, t, child) {
                return Opacity(
                  opacity: t.clamp(0.0, 1.0),
                  child: Transform.scale(scale: 0.94 + 0.06 * t, child: child),
                );
              },
              child: _card(),
            ),
          ),
        ),
      ),
    );
  }

  Widget _card() {
    return Container(
      width: 300,
      padding: const EdgeInsets.fromLTRB(28, 34, 28, 28),
      decoration: BoxDecoration(
        color: AppColors.surfaceWhite,
        borderRadius: BorderRadius.circular(26),
        border: Border.all(
          color: AppColors.borderLight.withValues(alpha: 0.8),
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: AppColors.deepDarkBrown.withValues(alpha: 0.20),
            blurRadius: 32,
            offset: const Offset(0, 14),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const _SecureRing(),
          const SizedBox(height: 24),
          Text(
            "Confirming your payment",
            textAlign: TextAlign.center,
            style: GoogleFonts.inter(
              fontSize: 17,
              fontWeight: FontWeight.w700,
              color: AppColors.deepDarkBrown,
              letterSpacing: -0.2,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            "Securely verifying with Google Play.\n"
            "This usually takes just a few seconds.",
            textAlign: TextAlign.center,
            style: GoogleFonts.inter(
              fontSize: 12.5,
              fontWeight: FontWeight.w400,
              color: AppColors.muted,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 20),
          Container(
            height: 1,
            color: AppColors.borderLight.withValues(alpha: 0.7),
          ),
          const SizedBox(height: 14),
          // Calm footer — reassurance, not alarm. A small lock keeps the
          // "secure" thread without a loud warning banner.
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              AppIcon(AppIcons.lock, size: 11, color: AppColors.muted),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  "Please keep this screen open",
                  textAlign: TextAlign.center,
                  style: GoogleFonts.inter(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w500,
                    color: AppColors.muted,
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

// Slim brand-brown progress ring sweeping around a security shield.
// The ring is an indeterminate CircularProgressIndicator (self-animating,
// smooth on every refresh rate) tinted to the brand brown — no gold, no
// coin. The shield in the centre carries the "secure transaction" cue.
class _SecureRing extends StatelessWidget {
  const _SecureRing();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 68,
      height: 68,
      child: Stack(
        alignment: Alignment.center,
        children: [
          SizedBox(
            width: 68,
            height: 68,
            child: CircularProgressIndicator(
              strokeWidth: 3,
              strokeCap: StrokeCap.round,
              valueColor: const AlwaysStoppedAnimation<Color>(
                AppColors.primaryBrown,
              ),
              backgroundColor: AppColors.primaryBrown.withValues(alpha: 0.10),
            ),
          ),
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.warmBeige.withValues(alpha: 0.7),
            ),
            child: Center(
              child: AppIcon(
                AppIcons.shield,
                size: 19,
                color: AppColors.primaryBrown,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
