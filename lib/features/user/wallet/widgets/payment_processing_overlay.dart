// Full-screen overlay shown while the server verifies a completed
// Razorpay payment.
//
// Why a full-screen modal rather than an inline spinner on the Pay
// button: between Razorpay closing and the CF returning with a new
// balance, the user is in the most anxious ~3 seconds of the flow
// — money has left their account but nothing has been credited yet.
// Blocking the whole surface prevents accidental back-taps that
// would navigate away from the in-flight verification, and gives
// them unambiguous feedback that *something* is happening.
//
// The pulsing coin (rather than a generic CircularProgressIndicator)
// keeps the brand language consistent with the rest of the wallet
// page during the one moment the user is most attentive.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:gospel_vox/core/theme/app_colors.dart';
import 'package:gospel_vox/core/widgets/coin_icon.dart';

class PaymentProcessingOverlay extends StatefulWidget {
  const PaymentProcessingOverlay({super.key});

  @override
  State<PaymentProcessingOverlay> createState() =>
      _PaymentProcessingOverlayState();
}

class _PaymentProcessingOverlayState extends State<PaymentProcessingOverlay>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    // Slow, calm pulse — a 2-second cycle reads as "working, take
    // your time" rather than a frantic spinner that implies urgency
    // or trouble. vsync ties the cycle to the display refresh so
    // the animation stays smooth on high-refresh panels.
    _controller = AnimationController(
      duration: const Duration(milliseconds: 2000),
      vsync: this,
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      // 40% black scrim lets the wallet page stay faintly visible so
      // the user remembers which flow they're in — a solid backdrop
      // reads as "the app froze" on slower phones.
      color: Colors.black.withValues(alpha: 0.4),
      child: Center(
        child: Container(
          width: 280,
          padding: const EdgeInsets.symmetric(
            vertical: 40,
            horizontal: 32,
          ),
          decoration: BoxDecoration(
            color: AppColors.surfaceWhite,
            borderRadius: BorderRadius.circular(24),
            boxShadow: [
              BoxShadow(
                color: AppColors.deepDarkBrown.withValues(alpha: 0.12),
                blurRadius: 24,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedBuilder(
                animation: _controller,
                builder: (context, child) {
                  // Sin/cos offset by 90° so scale peaks when opacity
                  // is mid-fade — gives the coin a "breathing" feel
                  // instead of a mechanical pulse.
                  final phase = _controller.value * 2 * math.pi;
                  return Transform.scale(
                    scale: 1.0 + 0.08 * math.sin(phase),
                    child: Opacity(
                      opacity: 0.7 + 0.3 * math.cos(phase),
                      child: child,
                    ),
                  );
                },
                child: Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: AppColors.amberGold.withValues(alpha: 0.12),
                  ),
                  child: const Center(
                    child: CoinIcon(size: 36),
                  ),
                ),
              ),
              const SizedBox(height: 24),
              Text(
                "Verifying your payment...",
                textAlign: TextAlign.center,
                style: GoogleFonts.inter(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: AppColors.deepDarkBrown,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                "This will only take a few seconds.\n"
                "Please don't close the app.",
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
    );
  }
}
