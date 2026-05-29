// Bank account form for priest withdrawals.
//
// This page is form-only. The "saved bank" view lives on the wallet
// page now (as the inline Linked Bank card under the balance hero),
// so this route's only job is collecting new/edited bank details.
//
// The fields are saved directly to priests/{uid} via the repository
// — no separate "bank_accounts" collection — because the
// requestWithdrawal CF reads them from the priest doc to know where
// to send money. Keeping them on the same doc avoids an extra read
// inside the CF and means there's nowhere for the two to drift apart.
//
// IFSC autofill:
//   The Razorpay public directory (ifsc.razorpay.com) populates
//   Bank Name + Branch the moment the IFSC code reaches 11 chars
//   and matches the valid pattern. Lookup failures (offline,
//   directory miss) leave the fields editable so the priest can
//   always type values manually — autofill is convenience, not gate.
//
// On save:
//   We try the Firestore write with a 30s deadline; if the network
//   ack runs over, we re-read the priest doc and treat a matching
//   server-side record as a successful save (a common pattern under
//   spotty mobile connections where the write commits but the ack
//   doesn't arrive in time). Either path pops back to the wallet
//   page with the new BankDetails — the wallet cubit pushes the
//   result into state so the Linked Bank card refreshes instantly.

import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:gospel_vox/core/services/ifsc_lookup_service.dart';
import 'package:gospel_vox/core/services/injection_container.dart';
import 'package:gospel_vox/core/theme/app_colors.dart';
import 'package:gospel_vox/core/widgets/app_back_button.dart';
import 'package:gospel_vox/core/widgets/app_snackbar.dart';
import 'package:gospel_vox/features/priest/wallet/data/priest_wallet_repository.dart';
import 'package:gospel_vox/features/priest/wallet/data/wallet_models.dart';
import 'package:gospel_vox/core/widgets/app_icons.dart';

// Format an account number for display as `•••• •••• •••• 9012`
// (grouped 4-4-4-…-last4). Pulled out of the widget tree so the
// wallet page's Linked Bank card and the withdrawal sheet can
// format identically.
String formatMaskedAccountNumber(String accountNumber) {
  final digits = accountNumber.replaceAll(RegExp(r'\D'), '');
  if (digits.length <= 4) return digits;
  final last4 = digits.substring(digits.length - 4);
  final hiddenLen = digits.length - 4;
  // Cap the mask groups so very long account numbers don't push
  // the right-hand digits off the row. 3 groups of •••• matches
  // the typical 12-16-digit Indian account number length.
  final groups = (hiddenLen / 4).ceil().clamp(1, 3);
  final mask = List<String>.filled(groups, '••••').join(' ');
  return '$mask $last4';
}

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
  late final TextEditingController _branchNameController;
  late final TextEditingController _upiController;

  // Account type — required dropdown on the form. Two values backed
  // by lowercase tokens for the Cloud Function to switch on.
  String? _accountType;
  static const List<({String value, String label})> _kAccountTypes = [
    (value: 'savings', label: 'Savings'),
    (value: 'current', label: 'Current'),
  ];

  bool _isSaving = false;
  // Account number defaults to obscured — shoulder-surfing on
  // public transit isn't a paranoid concern, it's the actual
  // failure mode this hides against.
  bool _obscureAccount = true;

  // IFSC autofill state.
  bool _ifscLookupInFlight = false;
  // Tracks the last IFSC we successfully looked up so we don't
  // re-hit the directory on every keystroke after the value is
  // stable.
  String? _lastLookedUpIfsc;
  Timer? _ifscDebounce;

  bool get _isEditing => widget.existingDetails != null;

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
    _branchNameController = TextEditingController(
      text: existing?.branchName ?? '',
    );
    _upiController = TextEditingController(
      text: existing?.upiId ?? '',
    );

    final existingType = existing?.accountType ?? '';
    _accountType = _kAccountTypes.any((t) => t.value == existingType)
        ? existingType
        : null;

    _ifscController.addListener(_onIfscChanged);
    _lastLookedUpIfsc = existing?.ifscCode.toUpperCase();
  }

  @override
  void dispose() {
    _ifscController.removeListener(_onIfscChanged);
    _ifscDebounce?.cancel();
    _nameController.dispose();
    _accountController.dispose();
    _confirmAccountController.dispose();
    _ifscController.dispose();
    _bankNameController.dispose();
    _branchNameController.dispose();
    _upiController.dispose();
    super.dispose();
  }

  // Debounced IFSC autofill. We wait 350 ms after the priest stops
  // typing, then try a lookup. Anything <11 chars short-circuits to
  // a no-op so we don't spam the directory on every keystroke from 4
  // to 11. The directory itself is forgiving — we never display its
  // failures, just leave Bank Name / Branch editable so the priest
  // can fall back to manual entry.
  void _onIfscChanged() {
    _ifscDebounce?.cancel();
    _ifscDebounce = Timer(const Duration(milliseconds: 350), () {
      _runIfscLookup();
    });
  }

  Future<void> _runIfscLookup() async {
    final raw = _ifscController.text.trim().toUpperCase();
    if (raw.length != 11) return;
    if (!RegExp(r'^[A-Z]{4}0[A-Z0-9]{6}$').hasMatch(raw)) return;
    if (raw == _lastLookedUpIfsc) return;

    if (!mounted) return;
    setState(() => _ifscLookupInFlight = true);

    final result = await IfscLookupService.lookup(raw);

    if (!mounted) return;
    setState(() => _ifscLookupInFlight = false);

    if (result == null || result.bankName.isEmpty) {
      // Couldn't resolve — leave whatever the priest had in the
      // bank / branch fields. Mark this IFSC as "looked up" so we
      // don't retry on the next keystroke.
      _lastLookedUpIfsc = raw;
      return;
    }

    _lastLookedUpIfsc = raw;
    // Don't overwrite a value the priest has already customised
    // unless the field is empty. Keeps the autofill helpful without
    // ever stomping on the priest's manual edits.
    setState(() {
      if (_bankNameController.text.trim().isEmpty) {
        _bankNameController.text = _properCase(result.bankName);
      }
      if (_branchNameController.text.trim().isEmpty) {
        _branchNameController.text = _properCase(result.branchName);
      }
    });
  }

  // The directory returns BANK / BRANCH in ALL CAPS ("STATE BANK OF
  // INDIA"). Word-cased reads more naturally in the form.
  String _properCase(String input) {
    final words = input.toLowerCase().split(RegExp(r'\s+'));
    return words.map((w) {
      if (w.isEmpty) return w;
      return '${w[0].toUpperCase()}${w.substring(1)}';
    }).join(' ');
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    if (_accountType == null) {
      AppSnackBar.error(context, 'Select an account type.');
      return;
    }

    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      AppSnackBar.error(context, 'Sign-in required.');
      return;
    }

    setState(() => _isSaving = true);

    final details = BankDetails(
      accountHolderName: _nameController.text.trim(),
      accountNumber: _accountController.text.trim(),
      ifscCode: _ifscController.text.trim().toUpperCase(),
      bankName: _bankNameController.text.trim(),
      branchName: _branchNameController.text.trim(),
      accountType: _accountType ?? '',
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

      // Pop straight back to the wallet page — the wallet cubit
      // applies the result and the inline Linked Bank card
      // refreshes immediately. The wallet page surfaces its own
      // success snackbar so the priest gets a clear confirmation
      // anchored to where the change is visible.
      HapticFeedback.lightImpact();
      context.pop<Object?>(details);
    } on TimeoutException {
      // Self-heal: cloud_firestore's update() Future only resolves
      // when the server acks the write, and on slow mobile networks
      // the ack can arrive well after our 30s deadline even though
      // the write is queued / committed. Re-read the priest doc
      // directly and, if the new fields are there, treat this as a
      // successful save. The priest never has to re-enter data that
      // actually landed.
      try {
        final fresh = await sl<PriestWalletRepository>()
            .fetchBankDetailsOnce(uid);
        if (!mounted) return;
        if (fresh != null &&
            fresh.accountNumber == details.accountNumber &&
            fresh.ifscCode == details.ifscCode) {
          HapticFeedback.lightImpact();
          context.pop<Object?>(fresh);
          return;
        }
      } catch (_) {
        // The recovery read itself failed (likely offline). Fall
        // through to the friendly retry message.
      }
      if (!mounted) return;
      setState(() => _isSaving = false);
      AppSnackBar.error(
        context,
        'Network is slow. Check your connection and try again.',
      );
    } catch (_) {
      if (!mounted) return;
      setState(() => _isSaving = false);
      AppSnackBar.error(context, 'Failed to save. Try again.');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: _buildAppBar(),
      body: _buildFormView(),
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
      leading: const Padding(
        padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: AppBackButton(),
      ),
      title: Text(
        // "Edit Bank Details" vs "Add Bank Details" — small thing
        // but tells the priest exactly which intent the route was
        // opened in.
        _isEditing ? 'Edit Bank Details' : 'Add Bank Details',
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

  // ─── Form view ───────────────────────────────────────────────

  Widget _buildFormView() {
    final paddingBottom = MediaQuery.of(context).padding.bottom;

    return Form(
      key: _formKey,
      child: SingleChildScrollView(
        physics: const BouncingScrollPhysics(),
        padding: EdgeInsets.fromLTRB(20, 16, 20, paddingBottom + 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _BankDetailsInfoTip(
              text: 'Your bank details are used only for sending '
                  'withdrawal payments. They are stored securely '
                  'and never shared.',
            ),
            const SizedBox(height: 24),
            // 1. Account Holder Name
            _FormField(
              label: 'Account Holder Name',
              hint: 'Name as on bank account',
              controller: _nameController,
              textCapitalization: TextCapitalization.words,
              // Bank account holder names in India routinely include
              // initials with periods ("S. R. Joseph"), apostrophes
              // ("D'Souza"), and hyphens ("Mary-Anne"). The regex
              // requires at least one letter at the start, then any
              // mix of letters / spaces / . / ' / -.
              validator: (v) {
                final trimmed = v?.trim() ?? '';
                if (trimmed.isEmpty) {
                  return 'Account holder name is required';
                }
                if (trimmed.length < 3) {
                  return 'Name must be at least 3 characters';
                }
                if (!RegExp(r"^[A-Za-z][A-Za-z\s.'\-]*$")
                    .hasMatch(trimmed)) {
                  return "Use letters, spaces, . ' - only";
                }
                return null;
              },
            ),
            const SizedBox(height: 16),
            // 2. Account Number — placed right after the holder name
            // so the priest types the two pieces of identity data
            // back-to-back, before any of the lookup-driven fields.
            _FormField(
              label: 'Account Number',
              hint: 'Enter account number',
              controller: _accountController,
              keyboardType: TextInputType.number,
              obscureText: _obscureAccount,
              // Digits-only at the input layer. This is the single
              // source of truth for the saved value's shape — paste
              // ('1234 5678 9012') gets stripped to '123456789012'
              // before it ever reaches the controller, so the value
              // we hand to the CF and store in Firestore is always
              // a clean string of digits.
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(18),
              ],
              suffixIcon: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => setState(
                  () => _obscureAccount = !_obscureAccount,
                ),
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: AppIcon(
                    _obscureAccount ? AppIcons.eyeOff : AppIcons.eye,
                    size: 20,
                    color: AppColors.muted,
                  ),
                ),
              ),
              validator: (v) {
                final trimmed = v?.trim() ?? '';
                if (trimmed.isEmpty) return 'Account number is required';
                if (trimmed.length < 9 || trimmed.length > 18) {
                  return 'Enter a valid account number (9-18 digits)';
                }
                return null;
              },
            ),
            const SizedBox(height: 16),
            // 3. Confirm Account Number — kept directly beneath
            // Account Number so the typo-check is visually inline.
            _FormField(
              label: 'Confirm Account Number',
              hint: 'Re-enter account number',
              controller: _confirmAccountController,
              keyboardType: TextInputType.number,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(18),
              ],
              // Trim both sides — autocomplete keyboards sometimes
              // append a trailing space which would otherwise cause
              // a false mismatch even when the digits agree.
              validator: (v) {
                if ((v ?? '').trim() !=
                    _accountController.text.trim()) {
                  return 'Account numbers do not match';
                }
                return null;
              },
            ),
            const SizedBox(height: 16),
            // 4. IFSC Code — triggers the directory lookup that
            // auto-fills Bank Name + Branch Name below.
            _FormField(
              label: 'IFSC Code',
              hint: 'e.g. SBIN0001234',
              controller: _ifscController,
              textCapitalization: TextCapitalization.characters,
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9]')),
                LengthLimitingTextInputFormatter(11),
                _UpperCaseTextFormatter(),
              ],
              // Subtle right-side hint that tells the priest the
              // bank lookup is happening so they don't think the
              // app froze on the slow last keystroke.
              suffixIcon: _ifscLookupInFlight
                  ? const Padding(
                      padding: EdgeInsets.all(14),
                      child: SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: AppColors.primaryBrown,
                        ),
                      ),
                    )
                  : null,
              validator: (v) {
                final trimmed = (v?.trim() ?? '').toUpperCase();
                if (trimmed.isEmpty) return 'IFSC code is required';
                if (!RegExp(r'^[A-Z]{4}0[A-Z0-9]{6}$').hasMatch(trimmed)) {
                  return 'Enter a valid IFSC code';
                }
                return null;
              },
            ),
            const SizedBox(height: 16),
            // 5. Bank Name — auto-filled, still editable.
            _FormField(
              label: 'Bank Name',
              hint: 'Auto-fills from IFSC — editable if needed',
              controller: _bankNameController,
              textCapitalization: TextCapitalization.words,
              validator: (v) {
                if ((v?.trim() ?? '').isEmpty) {
                  return 'Bank name is required';
                }
                return null;
              },
            ),
            const SizedBox(height: 16),
            // 6. Branch Name — auto-filled, still editable.
            _FormField(
              label: 'Branch Name',
              hint: 'Auto-fills from IFSC — editable if needed',
              controller: _branchNameController,
              textCapitalization: TextCapitalization.words,
              validator: (v) {
                if ((v?.trim() ?? '').isEmpty) {
                  return 'Branch name is required';
                }
                return null;
              },
            ),
            const SizedBox(height: 16),
            // 7. Account Type.
            _AccountTypeDropdown(
              value: _accountType,
              onChanged: (v) => setState(() => _accountType = v),
              types: _kAccountTypes,
            ),
            const SizedBox(height: 16),
            // 8. UPI ID (optional).
            _FormField(
              label: 'UPI ID (Optional)',
              hint: 'e.g. name@paytm',
              controller: _upiController,
              validator: (v) {
                final trimmed = v?.trim() ?? '';
                if (trimmed.isEmpty) return null;
                if (!trimmed.contains('@')) {
                  return 'Enter a valid UPI ID (e.g. name@bank)';
                }
                return null;
              },
            ),
            const SizedBox(height: 32),
            _SaveButton(
              isSaving: _isSaving,
              onTap: _isSaving ? null : _save,
              label: _isEditing ? 'Update Bank Details' : 'Save Bank Details',
            ),
          ],
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
  // Optional input filters — used by the account-number / IFSC
  // fields to enforce per-field input shape at the keystroke level
  // (paste included), so the value saved to Firestore is always
  // clean.
  final List<TextInputFormatter>? inputFormatters;

  const _FormField({
    required this.label,
    required this.hint,
    required this.controller,
    this.keyboardType,
    this.textCapitalization = TextCapitalization.none,
    this.obscureText = false,
    this.suffixIcon,
    this.validator,
    this.inputFormatters,
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
          inputFormatters: inputFormatters,
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

// ─── Account type dropdown ─────────────────────────────────────

class _AccountTypeDropdown extends StatelessWidget {
  final String? value;
  final ValueChanged<String?> onChanged;
  final List<({String value, String label})> types;

  const _AccountTypeDropdown({
    required this.value,
    required this.onChanged,
    required this.types,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Account Type',
          style: GoogleFonts.inter(
            fontSize: 13,
            fontWeight: FontWeight.w500,
            color: AppColors.deepDarkBrown,
          ),
        ),
        const SizedBox(height: 8),
        Container(
          decoration: BoxDecoration(
            color: AppColors.surfaceWhite,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: AppColors.muted.withValues(alpha: 0.12),
            ),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: value,
              isExpanded: true,
              hint: Text(
                'Select account type',
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.w400,
                  color: AppColors.muted.withValues(alpha: 0.5),
                ),
              ),
              icon: AppIcon(
                AppIcons.chevronDown,
                size: 18,
                color: AppColors.muted,
              ),
              borderRadius: BorderRadius.circular(12),
              style: GoogleFonts.inter(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: AppColors.deepDarkBrown,
              ),
              items: types
                  .map((t) => DropdownMenuItem<String>(
                        value: t.value,
                        child: Text(t.label),
                      ))
                  .toList(),
              onChanged: onChanged,
            ),
          ),
        ),
      ],
    );
  }
}

// ─── Misc bits ─────────────────────────────────────────────────

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
          AppIcon(
            AppIcons.lock,
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
  final String label;

  const _SaveButton({
    required this.isSaving,
    required this.onTap,
    required this.label,
  });

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
      ),
    );
  }
}

// Force-uppercase IFSC input as the priest types so the visible
// value matches the validation regex without an extra setState
// round-trip. Plays nice with the alphanumeric filter ahead of it.
class _UpperCaseTextFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    return TextEditingValue(
      text: newValue.text.toUpperCase(),
      selection: newValue.selection,
    );
  }
}
