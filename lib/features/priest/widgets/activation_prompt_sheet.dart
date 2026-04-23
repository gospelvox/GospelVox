// Shared bottom sheet that nudges an unactivated priest to pay the
// one-time activation fee. Shown anywhere an unactivated action is
// attempted — currently the incoming-request Accept button, but
// designed to be reusable for any future gated action (going online,
// accepting a bible-session booking, etc.).

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:gospel_vox/core/theme/app_colors.dart';

class ActivationPromptSheet extends StatelessWidget {
  const ActivationPromptSheet({super.key});

  // Convenience so callers don't need to know which constructor
  // options modalBottomSheet takes. The returned future resolves
  // when the sheet is dismissed; navigation to /priest/activation
  // has already happened via the CTA if the priest tapped it.
  static Future<void> show(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surfaceWhite,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => const ActivationPromptSheet(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
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
                  color: AppColors.muted.withValues(alpha: 0.25),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 24),

            // Icon + title row
            Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: AppColors.amberGold.withValues(alpha: 0.2),
                  ),
                  child: Icon(
                    Icons.lock_open_rounded,
                    size: 22,
                    color: AppColors.amberGold,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Activate Your Account',
                    style: GoogleFonts.inter(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: AppColors.deepDarkBrown,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),

            Text(
              'Pay a one-time ₹500 activation fee to accept sessions '
              'and appear in the user feed. Until you activate, your '
              'account stays private.',
              style: GoogleFonts.inter(
                fontSize: 13,
                fontWeight: FontWeight.w400,
                height: 1.6,
                color: AppColors.deepDarkBrown.withValues(alpha: 0.8),
              ),
            ),
            const SizedBox(height: 20),

            // Bullet benefits
            _Benefit(text: 'Start accepting chat and voice sessions'),
            const SizedBox(height: 10),
            _Benefit(text: 'Appear in the Available Now feed'),
            const SizedBox(height: 10),
            _Benefit(text: 'Earn coins for every minute you speak'),
            const SizedBox(height: 28),

            Row(
              children: [
                Expanded(
                  child: _SheetButton(
                    label: 'Not Now',
                    filled: false,
                    onTap: () => Navigator.of(context).pop(),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _SheetButton(
                    label: 'Activate for ₹500',
                    filled: true,
                    onTap: () {
                      Navigator.of(context).pop();
                      context.push('/priest/activation');
                    },
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Benefit extends StatelessWidget {
  final String text;
  const _Benefit({required this.text});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          margin: const EdgeInsets.only(top: 6),
          width: 6,
          height: 6,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: AppColors.amberGold,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            text,
            style: GoogleFonts.inter(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: AppColors.deepDarkBrown.withValues(alpha: 0.85),
            ),
          ),
        ),
      ],
    );
  }
}

class _SheetButton extends StatefulWidget {
  final String label;
  final bool filled;
  final VoidCallback onTap;

  const _SheetButton({
    required this.label,
    required this.filled,
    required this.onTap,
  });

  @override
  State<_SheetButton> createState() => _SheetButtonState();
}

class _SheetButtonState extends State<_SheetButton> {
  double _scale = 1.0;

  @override
  Widget build(BuildContext context) {
    final filled = widget.filled;
    final bg = filled ? AppColors.primaryBrown : Colors.transparent;
    final fg = filled ? Colors.white : AppColors.muted;
    final border = filled
        ? null
        : Border.all(
            color: AppColors.muted.withValues(alpha: 0.3),
            width: 1.5,
          );

    return Listener(
      onPointerDown: (_) => setState(() => _scale = 0.97),
      onPointerUp: (_) => setState(() => _scale = 1.0),
      onPointerCancel: (_) => setState(() => _scale = 1.0),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _scale,
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
          child: Container(
            height: 50,
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(14),
              border: border,
              boxShadow: filled
                  ? [
                      BoxShadow(
                        color:
                            AppColors.primaryBrown.withValues(alpha: 0.2),
                        blurRadius: 10,
                        offset: const Offset(0, 3),
                      ),
                    ]
                  : null,
            ),
            child: Center(
              child: Text(
                widget.label,
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: fg,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
