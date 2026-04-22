// The one serious warning the priest sees in the whole wizard.
//
// Professional UX rule of thumb: confirmation fatigue is real. Instead
// of nagging at every step, we concentrate all the "are you sure"
// gravity at the single commitment moment — the final Submit tap.
// This sheet spells out the real-world consequences (admin review,
// rejection, earnings freeze) in plain language so the priest can't
// say they weren't warned, and then offers two clear escape hatches:
// "Yes, I'm sure" and "Let me review again".

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:gospel_vox/core/theme/app_colors.dart';

// Resolves to true when the priest confirms, false when they back
// out. A null return (sheet dismissed via swipe/back) is treated as
// cancellation by callers.
Future<bool> showSubmitConfirmationSheet(BuildContext context) async {
  final result = await showModalBottomSheet<bool>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    // Barrier + swipe-to-dismiss both count as "not confirmed" —
    // we deliberately do NOT isDismissible: false because trapping
    // the user in the sheet feels coercive.
    builder: (_) => const _SubmitConfirmationSheet(),
  );
  return result ?? false;
}

class _SubmitConfirmationSheet extends StatefulWidget {
  const _SubmitConfirmationSheet();

  @override
  State<_SubmitConfirmationSheet> createState() =>
      _SubmitConfirmationSheetState();
}

class _SubmitConfirmationSheetState
    extends State<_SubmitConfirmationSheet> {
  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.surfaceWhite,
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 14, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Drag handle
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
              const SizedBox(height: 24),

              // Warning icon in amber — distinct from the everyday
              // brown so the priest's eye registers this as different.
              Center(
                child: Container(
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color:
                        AppColors.amberGold.withValues(alpha: 0.15),
                  ),
                  child: const Icon(
                    Icons.gpp_maybe_outlined,
                    size: 32,
                    color: AppColors.amberGold,
                  ),
                ),
              ),
              const SizedBox(height: 20),

              Center(
                child: Text(
                  'Ready to submit?',
                  style: GoogleFonts.inter(
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                    color: AppColors.deepDarkBrown,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Center(
                child: Text(
                  'Please read carefully before confirming.',
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    fontWeight: FontWeight.w400,
                    color: AppColors.muted,
                  ),
                ),
              ),
              const SizedBox(height: 24),

              // The three consequences, framed as real-world facts
              // rather than legal boilerplate.
              const _ConsequenceRow(
                icon: Icons.schedule_rounded,
                title: 'Admin review takes 24–48 hours',
                body:
                    'A member of our team will verify your details and '
                    "documents. You'll be notified of the outcome.",
              ),
              const SizedBox(height: 14),
              const _ConsequenceRow(
                icon: Icons.block_rounded,
                title: 'False information will be rejected',
                body:
                    'Applications with inaccurate data are declined '
                    'permanently. You will not be able to re-apply.',
              ),
              const SizedBox(height: 14),
              const _ConsequenceRow(
                icon: Icons.account_balance_wallet_outlined,
                title: 'Earnings can be frozen later',
                body:
                    'If inaccuracies surface after approval, your '
                    'account and withdrawals will be suspended.',
              ),

              const SizedBox(height: 28),

              // Primary: commit.
              _PrimaryButton(
                label: 'Yes, everything is accurate',
                onTap: () => Navigator.of(context).pop(true),
              ),
              const SizedBox(height: 10),
              // Secondary: the "escape hatch" — framed positively
              // (review again) rather than "Cancel" so users don't
              // feel they're aborting.
              _SecondaryButton(
                label: 'Let me review once more',
                onTap: () => Navigator.of(context).pop(false),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ConsequenceRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String body;

  const _ConsequenceRow({
    required this.icon,
    required this.title,
    required this.body,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: AppColors.primaryBrown.withValues(alpha: 0.06),
          ),
          child: Icon(
            icon,
            size: 18,
            color: AppColors.primaryBrown,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: AppColors.deepDarkBrown,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                body,
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
      ],
    );
  }
}

class _PrimaryButton extends StatefulWidget {
  final String label;
  final VoidCallback onTap;

  const _PrimaryButton({required this.label, required this.onTap});

  @override
  State<_PrimaryButton> createState() => _PrimaryButtonState();
}

class _PrimaryButtonState extends State<_PrimaryButton> {
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
                color: AppColors.primaryBrown.withValues(alpha: 0.2),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Center(
            child: Text(
              widget.label,
              style: GoogleFonts.inter(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: Colors.white,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SecondaryButton extends StatefulWidget {
  final String label;
  final VoidCallback onTap;

  const _SecondaryButton({required this.label, required this.onTap});

  @override
  State<_SecondaryButton> createState() => _SecondaryButtonState();
}

class _SecondaryButtonState extends State<_SecondaryButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _pressed ? 0.98 : 1.0,
        duration: const Duration(milliseconds: 120),
        child: Container(
          width: double.infinity,
          height: 48,
          alignment: Alignment.center,
          child: Text(
            widget.label,
            style: GoogleFonts.inter(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: AppColors.muted,
            ),
          ),
        ),
      ),
    );
  }
}
