// Bank account form for priest withdrawals.
//
// The fields here are saved directly to priests/{uid} via the
// repository — no separate "bank_accounts" collection — because
// the requestWithdrawal CF reads them from the priest doc to know
// where to send money. Keeping them on the same doc avoids an
// extra read inside the CF and means there's nowhere for the two
// to drift apart.

import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:gospel_vox/core/services/injection_container.dart';
import 'package:gospel_vox/core/theme/app_colors.dart';
import 'package:gospel_vox/core/widgets/app_snackbar.dart';
import 'package:gospel_vox/features/priest/wallet/data/priest_wallet_repository.dart';
import 'package:gospel_vox/features/priest/wallet/data/wallet_models.dart';

class BankDetailsPage extends StatefulWidget {
  // Pre-fills the form when the priest is editing existing details.
  // Null means first-time setup — in which case we leave the fields
  // blank and let validation guide them.
  final BankDetails? existingDetails;

  const BankDetailsPage({super.key, this.existingDetails});

  @override
  State<BankDetailsPage> createState() => _BankDetailsPageState();
}

class _BankDetailsPageState extends State<BankDetailsPage> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController;
  late final TextEditingController _accountController;
  late final TextEditingController _confirmAccountController;
  late final TextEditingController _ifscController;
  late final TextEditingController _bankNameController;
  late final TextEditingController _upiController;

  bool _isSaving = false;
  // Account number defaults to obscured — shoulder-surfing on
  // public transit isn't a paranoid concern, it's the actual
  // failure mode this hides against.
  bool _obscureAccount = true;

  @override
  void initState() {
    super.initState();
    final existing = widget.existingDetails;
    _nameController = TextEditingController(
      text: existing?.accountHolderName ?? '',
    );
    _accountController = TextEditingController(
      text: existing?.accountNumber ?? '',
    );
    _confirmAccountController = TextEditingController(
      text: existing?.accountNumber ?? '',
    );
    _ifscController = TextEditingController(
      text: existing?.ifscCode ?? '',
    );
    _bankNameController = TextEditingController(
      text: existing?.bankName ?? '',
    );
    _upiController = TextEditingController(
      text: existing?.upiId ?? '',
    );
  }

  @override
  void dispose() {
    _nameController.dispose();
    _accountController.dispose();
    _confirmAccountController.dispose();
    _ifscController.dispose();
    _bankNameController.dispose();
    _upiController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      AppSnackBar.error(context, "Sign-in required.");
      return;
    }

    setState(() => _isSaving = true);

    final details = BankDetails(
      accountHolderName: _nameController.text.trim(),
      accountNumber: _accountController.text.trim(),
      ifscCode: _ifscController.text.trim().toUpperCase(),
      bankName: _bankNameController.text.trim(),
      upiId: _upiController.text.trim().isEmpty
          ? null
          : _upiController.text.trim(),
    );

    try {
      await sl<PriestWalletRepository>().saveBankDetails(
        uid: uid,
        details: details,
      );
      if (!mounted) return;

      AppSnackBar.success(context, "Bank details saved");
      setState(() => _isSaving = false);
      // Pop with the saved details so the caller (wallet page) can
      // push them into its cubit. GoRouter siblings don't share
      // BlocProviders, so passing back via the pop result is the
      // cleanest cross-route handoff.
      context.pop(details);
    } on TimeoutException {
      if (!mounted) return;
      setState(() => _isSaving = false);
      AppSnackBar.error(context, "Save timed out. Try again.");
    } catch (_) {
      if (!mounted) return;
      setState(() => _isSaving = false);
      AppSnackBar.error(context, "Failed to save. Try again.");
    }
  }

  @override
  Widget build(BuildContext context) {
    final paddingBottom = MediaQuery.of(context).padding.bottom;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: _buildAppBar(),
      body: Form(
        key: _formKey,
        child: SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          padding: EdgeInsets.fromLTRB(20, 16, 20, paddingBottom + 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const _BankDetailsInfoTip(
                text:
                    "Your bank details are used only for sending "
                    "withdrawal payments. They are stored securely "
                    "and never shared.",
              ),
              const SizedBox(height: 24),
              _FormField(
                label: "Account Holder Name",
                hint: "Name as on bank account",
                controller: _nameController,
                textCapitalization: TextCapitalization.words,
                validator: (v) {
                  final trimmed = v?.trim() ?? '';
                  if (trimmed.isEmpty) {
                    return "Account holder name is required";
                  }
                  if (trimmed.length < 3) {
                    return "Name must be at least 3 characters";
                  }
                  if (!RegExp(r'^[a-zA-Z\s]+$').hasMatch(trimmed)) {
                    return "Name can only contain letters";
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),
              _FormField(
                label: "Account Number",
                hint: "Enter account number",
                controller: _accountController,
                keyboardType: TextInputType.number,
                obscureText: _obscureAccount,
                suffixIcon: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => setState(
                    () => _obscureAccount = !_obscureAccount,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Icon(
                      _obscureAccount
                          ? Icons.visibility_off_outlined
                          : Icons.visibility_outlined,
                      size: 20,
                      color: AppColors.muted,
                    ),
                  ),
                ),
                validator: (v) {
                  final trimmed = v?.trim() ?? '';
                  if (trimmed.isEmpty) return "Account number is required";
                  final digits = trimmed.replaceAll(RegExp(r'[^0-9]'), '');
                  if (digits.length < 9 || digits.length > 18) {
                    return "Enter a valid account number (9-18 digits)";
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),
              _FormField(
                label: "Confirm Account Number",
                hint: "Re-enter account number",
                controller: _confirmAccountController,
                keyboardType: TextInputType.number,
                validator: (v) {
                  if ((v ?? '') != _accountController.text) {
                    return "Account numbers do not match";
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),
              _FormField(
                label: "IFSC Code",
                hint: "e.g. SBIN0001234",
                controller: _ifscController,
                textCapitalization: TextCapitalization.characters,
                validator: (v) {
                  final trimmed = (v?.trim() ?? '').toUpperCase();
                  if (trimmed.isEmpty) return "IFSC code is required";
                  if (!RegExp(r'^[A-Z]{4}0[A-Z0-9]{6}$').hasMatch(trimmed)) {
                    return "Enter a valid IFSC code";
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),
              _FormField(
                label: "Bank Name",
                hint: "e.g. State Bank of India",
                controller: _bankNameController,
                textCapitalization: TextCapitalization.words,
                validator: (v) {
                  if ((v?.trim() ?? '').isEmpty) {
                    return "Bank name is required";
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),
              _FormField(
                label: "UPI ID (Optional)",
                hint: "e.g. name@paytm",
                controller: _upiController,
                validator: (v) {
                  final trimmed = v?.trim() ?? '';
                  if (trimmed.isEmpty) return null;
                  if (!trimmed.contains('@')) {
                    return "Enter a valid UPI ID (e.g. name@bank)";
                  }
                  return null;
                },
              ),
              const SizedBox(height: 32),
              _SaveButton(
                isSaving: _isSaving,
                onTap: _isSaving ? null : _save,
              ),
            ],
          ),
        ),
      ),
    );
  }

  PreferredSizeWidget _buildAppBar() {
    return AppBar(
      backgroundColor: AppColors.background,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
      automaticallyImplyLeading: false,
      titleSpacing: 16,
      leading: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => context.pop(),
          child: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.surfaceWhite,
              boxShadow: [
                BoxShadow(
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                  color: Colors.black.withValues(alpha: 0.04),
                ),
              ],
            ),
            child: const Icon(
              Icons.arrow_back_ios_new_rounded,
              size: 16,
              color: AppColors.deepDarkBrown,
            ),
          ),
        ),
      ),
      title: Text(
        "Bank Details",
        style: GoogleFonts.inter(
          fontSize: 18,
          fontWeight: FontWeight.w600,
          color: AppColors.deepDarkBrown,
        ),
      ),
      centerTitle: false,
      bottom: PreferredSize(
        preferredSize: const Size.fromHeight(1),
        child: Container(
          height: 1,
          color: AppColors.muted.withValues(alpha: 0.08),
        ),
      ),
    );
  }
}

// ─── Form leaves ───────────────────────────────────────────────

class _FormField extends StatelessWidget {
  final String label;
  final String hint;
  final TextEditingController controller;
  final TextInputType? keyboardType;
  final TextCapitalization textCapitalization;
  final bool obscureText;
  final Widget? suffixIcon;
  final String? Function(String?)? validator;

  const _FormField({
    required this.label,
    required this.hint,
    required this.controller,
    this.keyboardType,
    this.textCapitalization = TextCapitalization.none,
    this.obscureText = false,
    this.suffixIcon,
    this.validator,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: GoogleFonts.inter(
            fontSize: 13,
            fontWeight: FontWeight.w500,
            color: AppColors.deepDarkBrown,
          ),
        ),
        const SizedBox(height: 8),
        TextFormField(
          controller: controller,
          keyboardType: keyboardType,
          textCapitalization: textCapitalization,
          obscureText: obscureText,
          autovalidateMode: AutovalidateMode.onUserInteraction,
          style: GoogleFonts.inter(
            fontSize: 14,
            fontWeight: FontWeight.w500,
            color: AppColors.deepDarkBrown,
          ),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: GoogleFonts.inter(
              fontSize: 14,
              fontWeight: FontWeight.w400,
              color: AppColors.muted.withValues(alpha: 0.5),
            ),
            filled: true,
            fillColor: AppColors.surfaceWhite,
            suffixIcon: suffixIcon,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 14,
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(
                color: AppColors.muted.withValues(alpha: 0.12),
              ),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(
                color: AppColors.muted.withValues(alpha: 0.12),
              ),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(
                color: AppColors.primaryBrown.withValues(alpha: 0.5),
                width: 1.5,
              ),
            ),
            errorBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: AppColors.errorRed),
            ),
            focusedErrorBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(
                color: AppColors.errorRed,
                width: 1.5,
              ),
            ),
            errorStyle: GoogleFonts.inter(
              fontSize: 12,
              fontWeight: FontWeight.w400,
              color: AppColors.errorRed,
            ),
          ),
          validator: validator,
        ),
      ],
    );
  }
}

class _BankDetailsInfoTip extends StatelessWidget {
  final String text;

  const _BankDetailsInfoTip({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.primaryBrown.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: AppColors.primaryBrown.withValues(alpha: 0.1),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.lock_outline_rounded,
            size: 16,
            color: AppColors.primaryBrown.withValues(alpha: 0.7),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: GoogleFonts.inter(
                fontSize: 12,
                fontWeight: FontWeight.w400,
                height: 1.5,
                color: AppColors.primaryBrown.withValues(alpha: 0.85),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SaveButton extends StatefulWidget {
  final bool isSaving;
  final VoidCallback? onTap;

  const _SaveButton({required this.isSaving, required this.onTap});

  @override
  State<_SaveButton> createState() => _SaveButtonState();
}

class _SaveButtonState extends State<_SaveButton> {
  double _scale = 1.0;

  void _down() {
    if (widget.onTap == null) return;
    setState(() => _scale = 0.97);
  }

  void _up() {
    if (_scale == 1.0) return;
    setState(() => _scale = 1.0);
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (_) => _down(),
      onPointerUp: (_) => _up(),
      onPointerCancel: (_) => _up(),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _scale,
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
          child: Container(
            width: double.infinity,
            height: 54,
            decoration: BoxDecoration(
              color: widget.onTap == null
                  ? AppColors.primaryBrown.withValues(alpha: 0.5)
                  : AppColors.primaryBrown,
              borderRadius: BorderRadius.circular(14),
              boxShadow: widget.onTap == null
                  ? const []
                  : [
                      BoxShadow(
                        color: AppColors.primaryBrown.withValues(alpha: 0.18),
                        blurRadius: 10,
                        offset: const Offset(0, 3),
                      ),
                    ],
            ),
            child: Center(
              child: widget.isSaving
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        color: Colors.white,
                        strokeWidth: 2.5,
                      ),
                    )
                  : Text(
                      "Save Bank Details",
                      style: GoogleFonts.inter(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                    ),
            ),
          ),
        ),
      ),
    );
  }
}
