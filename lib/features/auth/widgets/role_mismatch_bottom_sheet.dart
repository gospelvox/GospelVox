// Shown when the social account a user just signed into is registered
// under a different role than the one they picked on the role-selection
// screen. The user is still authenticated when this opens — tapping
// "Sign in as <ExistingRole>" routes them to the matching shell, while
// "Use a different account" signs out and re-prompts the picker.

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:gospel_vox/core/theme/app_colors.dart';

class RoleMismatchBottomSheet extends StatelessWidget {
  final String email;
  final String existingRole;
  final String selectedRole;
  final VoidCallback onContinueAsExisting;
  final VoidCallback onUseDifferentAccount;

  const RoleMismatchBottomSheet({
    super.key,
    required this.email,
    required this.existingRole,
    required this.selectedRole,
    required this.onContinueAsExisting,
    required this.onUseDifferentAccount,
  });

  static String _label(String role) {
    switch (role) {
      case 'priest':
        return 'Speaker';
      case 'admin':
        return 'Admin';
      default:
        return 'Member';
    }
  }

  @override
  Widget build(BuildContext context) {
    final viewInsets = MediaQuery.of(context).viewInsets.bottom;
    final existingLabel = _label(existingRole);
    final selectedLabel = _label(selectedRole);
    final emailDisplay = email.isEmpty ? 'this Google account' : email;

    return Padding(
      padding: EdgeInsets.only(bottom: viewInsets),
      child: Container(
        decoration: const BoxDecoration(
          color: AppColors.surfaceWhite,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
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
              const SizedBox(height: 20),
              Center(
                child: Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: AppColors.amberGold.withValues(alpha: 0.1),
                  ),
                  child: const Icon(
                    Icons.swap_horiz_rounded,
                    size: 28,
                    color: AppColors.amberGold,
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Text(
                'Account Already Registered',
                textAlign: TextAlign.center,
                style: GoogleFonts.inter(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: AppColors.deepDarkBrown,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'The account $emailDisplay is registered as a '
                '$existingLabel. You selected $selectedLabel.',
                textAlign: TextAlign.center,
                style: GoogleFonts.inter(
                  fontSize: 13,
                  fontWeight: FontWeight.w400,
                  color: AppColors.muted,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 24),
              _PrimaryAction(
                label: 'Sign in as $existingLabel',
                onTap: onContinueAsExisting,
              ),
              const SizedBox(height: 12),
              _SecondaryAction(
                label: 'Use a different account',
                onTap: onUseDifferentAccount,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PrimaryAction extends StatefulWidget {
  final String label;
  final VoidCallback onTap;
  const _PrimaryAction({required this.label, required this.onTap});

  @override
  State<_PrimaryAction> createState() => _PrimaryActionState();
}

class _PrimaryActionState extends State<_PrimaryAction> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      onTap: widget.onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedScale(
        scale: _pressed ? 0.97 : 1.0,
        duration: const Duration(milliseconds: 80),
        child: Container(
          width: double.infinity,
          height: 48,
          decoration: BoxDecoration(
            color: AppColors.primaryBrown,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Center(
            child: Text(
              widget.label,
              style: GoogleFonts.inter(
                fontSize: 14,
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

class _SecondaryAction extends StatefulWidget {
  final String label;
  final VoidCallback onTap;
  const _SecondaryAction({required this.label, required this.onTap});

  @override
  State<_SecondaryAction> createState() => _SecondaryActionState();
}

class _SecondaryActionState extends State<_SecondaryAction> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      onTap: widget.onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedScale(
        scale: _pressed ? 0.97 : 1.0,
        duration: const Duration(milliseconds: 80),
        child: Container(
          width: double.infinity,
          height: 48,
          decoration: BoxDecoration(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: AppColors.muted.withValues(alpha: 0.2),
            ),
          ),
          child: Center(
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
      ),
    );
  }
}
