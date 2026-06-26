// Country-aware bank account form for priest withdrawals.
//
// The form is driven entirely by `resolveBankScheme(countryIso)` — it
// renders whatever fields that country needs (India IFSC, US routing,
// UK sort code, Europe/GCC IBAN+SWIFT, or the international fallback),
// validates each with the checksum-backed validators, and saves
// through the country-aware BankDetails model. Adding a country later
// is a schema change, not a change to this file.
//
// What lives here vs. the schema:
//   • The schema owns: which fields, labels, hints, keyboard, max
//     length, upper-casing, and per-field validation.
//   • This file owns: the country selector, the "confirm account
//     number" typo guard, India's IFSC->bank autofill, a review sheet
//     before committing, and the Firestore save (with the same
//     slow-network self-heal the old form used).
//
// Storage: fields are written to priests/{uid} under the same keys the
// requestWithdrawal CF already reads (bankAccountName / Number / Ifsc /
// bankName), plus the new cross-border keys — see BankDetails. On save
// we only read the CURRENT country's fields, so switching country and
// back never leaks a stale value (e.g. an India IFSC) onto a US record.

import 'dart:async';

import 'package:country_picker/country_picker.dart';
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
import 'package:gospel_vox/core/widgets/phone_country_prefix.dart';
import 'package:gospel_vox/features/priest/wallet/data/bank_account_scheme.dart';
import 'package:gospel_vox/features/priest/wallet/data/priest_wallet_repository.dart';
import 'package:gospel_vox/features/priest/wallet/data/wallet_models.dart';
import 'package:gospel_vox/core/widgets/app_icons.dart';
import 'package:gospel_vox/core/widgets/app_loading_widget.dart';

// Markets surfaced at the top of the country picker (India-first, then
// the rollout markets), mirroring the phone field's favourites.
const List<String> _kFavoriteCountries = [
  'IN', 'US', 'GB', 'AE', 'SA', 'QA', 'KW', 'OM', 'BH', 'CA', 'AU',
];

// Format an account number for display as `•••• •••• •••• 9012`
// (grouped 4-4-4-…-last4). Kept exported so the wallet page's Linked
// Bank card and the withdrawal sheet format identically.
String formatMaskedAccountNumber(String accountNumber) {
  final digits = accountNumber.replaceAll(RegExp(r'\D'), '');
  if (digits.length <= 4) return digits;
  final last4 = digits.substring(digits.length - 4);
  final hiddenLen = digits.length - 4;
  final groups = (hiddenLen / 4).ceil().clamp(1, 3);
  final mask = List<String>.filled(groups, '••••').join(' ');
  return '$mask $last4';
}

// Mask any account identifier (IBAN included, which is alphanumeric)
// to "••••<last4>" for the review sheet — last four is enough for the
// priest to recognise their account without re-displaying the whole
// number in plain text.
String _maskIdentifier(String value) {
  final v = value.replaceAll(RegExp(r'\s'), '');
  if (v.length <= 4) return v;
  return '••••${v.substring(v.length - 4)}';
}

class BankDetailsPage extends StatefulWidget {
  // Pre-fills the form when editing. Null = first-time setup.
  final BankDetails? existingDetails;

  const BankDetailsPage({super.key, this.existingDetails});

  @override
  State<BankDetailsPage> createState() => _BankDetailsPageState();
}

class _BankDetailsPageState extends State<BankDetailsPage> {
  final _formKey = GlobalKey<FormState>();

  // Selected bank country. Drives which fields the form shows.
  late Country _country;

  // Persistent value store keyed by schema field key. Survives country
  // switches so toggling country and back restores what was typed; only
  // the CURRENT country's keys are read on save.
  final Map<String, String> _values = {};

  // Live text controllers for the CURRENT country's text fields only,
  // rebuilt whenever the country changes.
  final Map<String, TextEditingController> _controllers = {};

  // Confirm-account typo guard. Re-entry of the primary account
  // identifier (account number, or IBAN for IBAN countries).
  final TextEditingController _confirmController = TextEditingController();

  // Inline errors for choice fields (account type) — text fields use
  // the Form's own validator path instead.
  final Map<String, String?> _choiceErrors = {};

  bool _isSaving = false;
  // Primary digit account numbers default to obscured (shoulder-surf
  // defence). IBANs are not obscured — they're alphanumeric and long,
  // and hiding them while also asking for re-entry helps no one.
  bool _obscureAccount = true;

  // IFSC autofill state (India only).
  bool _ifscLookupInFlight = false;
  String? _lastLookedUpIfsc;
  Timer? _ifscDebounce;

  // Contact fields (mandatory). The phone dial code follows the bank
  // country selection (India bank -> +91) but stays tappable to
  // override. The number lives in _phoneController; combined into
  // "+<code> <number>" on save via composePhone.
  late Country _phoneCountry;
  late final TextEditingController _phoneController;
  late final TextEditingController _emailController;

  bool get _isEditing => widget.existingDetails != null;

  BankAccountScheme get _scheme => resolveBankScheme(_country.countryCode);

  // The account identifier that gets a "confirm" field. IBAN countries
  // confirm the IBAN; everyone else confirms the account number.
  String? get _primaryAccountKey {
    final keys = _scheme.fields.map((f) => f.key).toSet();
    if (keys.contains('bankIban')) return 'bankIban';
    if (keys.contains('bankAccountNumber')) return 'bankAccountNumber';
    return null;
  }

  @override
  void initState() {
    super.initState();
    final existing = widget.existingDetails;

    // Seed the value store from the existing record (by schema key).
    if (existing != null) {
      for (final key in const [
        'bankAccountName', 'bankAccountNumber', 'bankIfscCode', 'bankName',
        'bankBranchName', 'bankAccountType', 'bankRoutingNumber',
        'bankSortCode', 'bankIban', 'bankSwiftBic',
      ]) {
        _values[key] = existing.valueForKey(key);
      }
    }

    final initialIso =
        (existing?.countryIso.trim().isNotEmpty ?? false)
            ? existing!.countryIso
            : 'IN';
    _country = CountryService().findByCode(initialIso) ??
        CountryService().findByCode('IN') ??
        Country.parse('IN');

    _lastLookedUpIfsc = (_values['bankIfscCode'] ?? '').toUpperCase();

    // Contact: pre-fill from the existing record (which itself falls
    // back to the priest's registration phone/email). The phone country
    // comes from the stored "+code" if present, else the bank country.
    final existingPhone = existing?.phone ?? '';
    _phoneCountry = existingPhone.isNotEmpty
        ? phoneCountryFromStored(existingPhone)
        : _country;
    _phoneController =
        TextEditingController(text: phoneNumberFromStored(existingPhone));
    _emailController = TextEditingController(text: existing?.email ?? '');

    _rebuildControllers();
  }

  @override
  void dispose() {
    _ifscDebounce?.cancel();
    _disposeControllers();
    _confirmController.dispose();
    _phoneController.dispose();
    _emailController.dispose();
    super.dispose();
  }

  void _disposeControllers() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    _controllers.clear();
  }

  // (Re)create controllers for the current scheme's text fields,
  // pre-filled from the persistent value store. Called on init and on
  // every country change.
  void _rebuildControllers() {
    _disposeControllers();
    for (final field in _scheme.fields) {
      if (field.kind == BankFieldKind.choice) continue;
      _controllers[field.key] =
          TextEditingController(text: _values[field.key] ?? '');
    }
    // Pre-fill the confirm field on edit so the saved account doesn't
    // read as a mismatch the moment the form opens.
    final primary = _primaryAccountKey;
    _confirmController.text = primary == null ? '' : (_values[primary] ?? '');
  }

  void _onCountrySelected(Country country) {
    // Capture what's currently typed before swapping controllers.
    _captureControllerValues();
    // Kill any in-flight IFSC autofill so a debounce scheduled while on
    // India can't land on the newly-selected country's form.
    _ifscDebounce?.cancel();
    setState(() {
      _country = country;
      // Phone dial code follows the chosen bank country (India bank ->
      // +91). The priest can still tap the prefix to override after.
      _phoneCountry = country;
      _choiceErrors.clear();
      _obscureAccount = true;
      // Drop any choice value that isn't valid for the new country
      // (e.g. a US "checking" left over when switching to India, whose
      // options are savings/current) so the dropdown never holds a
      // value outside its item set.
      for (final field
          in _scheme.fields.where((f) => f.kind == BankFieldKind.choice)) {
        final current = _values[field.key];
        if (!field.options.any((o) => o.value == current)) {
          _values[field.key] = '';
        }
      }
      _rebuildControllers();
    });
  }

  void _captureControllerValues() {
    _controllers.forEach((key, controller) {
      _values[key] = controller.text;
    });
  }

  void _onFieldChanged(BankFieldSpec field, String value) {
    _values[field.key] = value;
    if (field.key == 'bankIfscCode') {
      _scheduleIfscLookup();
    }
    // Rebuild so the per-field green check + confirm match recompute.
    setState(() {});
  }

  // ─── IFSC autofill (India) ───────────────────────────────────

  void _scheduleIfscLookup() {
    _ifscDebounce?.cancel();
    _ifscDebounce =
        Timer(const Duration(milliseconds: 350), _runIfscLookup);
  }

  Future<void> _runIfscLookup() async {
    // Only India collects an IFSC. Guards against a debounced call that
    // outlived a country switch.
    if (_country.countryCode.toUpperCase() != 'IN') return;
    final raw = (_values['bankIfscCode'] ?? '').trim().toUpperCase();
    if (raw.length != 11) return;
    if (!RegExp(r'^[A-Z]{4}0[A-Z0-9]{6}$').hasMatch(raw)) return;
    if (raw == _lastLookedUpIfsc) return;

    if (!mounted) return;
    setState(() => _ifscLookupInFlight = true);
    final result = await IfscLookupService.lookup(raw);
    if (!mounted) return;
    setState(() => _ifscLookupInFlight = false);

    _lastLookedUpIfsc = raw;
    // Re-check the country after the network round-trip — the priest
    // may have switched away while the lookup was in flight.
    if (_country.countryCode.toUpperCase() != 'IN') return;
    if (result == null) return;

    var changed = false;

    // Only fill the bank name if the priest hasn't typed their own.
    final bankController = _controllers['bankName'];
    if (result.bankName.isNotEmpty &&
        bankController != null &&
        bankController.text.trim().isEmpty) {
      final filled = _properCase(result.bankName);
      bankController.text = filled;
      _values['bankName'] = filled;
      changed = true;
    }

    // Same for branch — auto-fill only when the priest hasn't typed it,
    // so a correction they made is never clobbered by the lookup.
    final branchController = _controllers['bankBranchName'];
    if (result.branchName.isNotEmpty &&
        branchController != null &&
        branchController.text.trim().isEmpty) {
      final filled = _properCase(result.branchName);
      branchController.text = filled;
      _values['bankBranchName'] = filled;
      changed = true;
    }

    if (changed) setState(() {});
  }

  String _properCase(String input) {
    final words = input.toLowerCase().split(RegExp(r'\s+'));
    return words.map((w) {
      if (w.isEmpty) return w;
      return '${w[0].toUpperCase()}${w.substring(1)}';
    }).join(' ');
  }

  // ─── Save ────────────────────────────────────────────────────

  // Build a BankDetails from ONLY the current country's fields, so a
  // value left over from a previous country selection is never saved.
  BankDetails _buildDetails() {
    _captureControllerValues();
    final currentKeys = _scheme.fields.map((f) => f.key).toSet();
    String v(String key) =>
        currentKeys.contains(key) ? (_values[key] ?? '').trim() : '';
    return BankDetails(
      accountHolderName: v('bankAccountName'),
      accountNumber: v('bankAccountNumber'),
      ifscCode: v('bankIfscCode'),
      bankName: v('bankName'),
      branchName: v('bankBranchName'),
      accountType: v('bankAccountType'),
      countryIso: _scheme.countryIso,
      currency: _scheme.currency,
      routingNumber: v('bankRoutingNumber'),
      sortCode: v('bankSortCode'),
      iban: v('bankIban'),
      swiftBic: v('bankSwiftBic'),
      phone: composePhone(_phoneCountry, _phoneController.text),
      email: _emailController.text.trim(),
    );
  }

  Future<void> _onSavePressed() async {
    _captureControllerValues();

    // Text fields (and the confirm guard) validate through the Form.
    final textOk = _formKey.currentState?.validate() ?? false;

    // Choice fields validate manually since they aren't TextFormFields.
    var choiceOk = true;
    for (final field
        in _scheme.fields.where((f) => f.kind == BankFieldKind.choice)) {
      final err = field.validate(_values[field.key] ?? '');
      _choiceErrors[field.key] = err;
      if (err != null) choiceOk = false;
    }
    setState(() {});

    if (!textOk || !choiceOk) return;

    final details = _buildDetails();
    if (!mounted) return;

    // Review step — last chance to catch a wrong digit before it goes
    // to the admin for a manual transfer that can't be reversed.
    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _ReviewSheet(details: details, scheme: _scheme),
    );
    if (confirmed != true || !mounted) return;

    await _persist(details);
  }

  Future<void> _persist(BankDetails details) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      AppSnackBar.error(context, 'Sign-in required.');
      return;
    }
    setState(() => _isSaving = true);

    final primary = _primaryAccountKey ?? 'bankAccountNumber';
    try {
      await sl<PriestWalletRepository>()
          .saveBankDetails(uid: uid, details: details);
      if (!mounted) return;
      HapticFeedback.lightImpact();
      context.pop<Object?>(details);
    } on TimeoutException {
      // Slow-network self-heal: the write may have committed even
      // though the ack ran past our deadline. Re-read and accept it if
      // the saved record matches on country + primary identifier.
      try {
        final fresh =
            await sl<PriestWalletRepository>().fetchBankDetailsOnce(uid);
        if (!mounted) return;
        if (fresh != null &&
            fresh.countryIso == details.countryIso &&
            fresh.valueForKey(primary) == details.valueForKey(primary) &&
            fresh.valueForKey(primary).isNotEmpty) {
          HapticFeedback.lightImpact();
          context.pop<Object?>(fresh);
          return;
        }
      } catch (_) {
        // Recovery read failed (likely offline) — fall through.
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

  // ─── Build ───────────────────────────────────────────────────

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

  Widget _buildFormView() {
    final paddingBottom = MediaQuery.of(context).padding.bottom;
    final primaryKey = _primaryAccountKey;

    return Form(
      key: _formKey,
      child: SingleChildScrollView(
        physics: const BouncingScrollPhysics(),
        padding: EdgeInsets.fromLTRB(20, 16, 20, paddingBottom + 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _BankDetailsInfoTip(
              text: 'We check the FORMAT of your details, but please '
                  'make sure they exactly match your bank. Money sent '
                  'to a wrong account cannot be recovered.',
            ),
            const SizedBox(height: 24),
            _CountrySelector(
              country: _country,
              onSelected: _onCountrySelected,
              onTap: _openCountryPicker,
            ),
            if (_scheme.currency.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                'Payouts to this account are in ${_scheme.currency}.',
                style: GoogleFonts.inter(
                  fontSize: 12,
                  fontWeight: FontWeight.w400,
                  color: AppColors.muted,
                ),
              ),
            ],
            const SizedBox(height: 20),
            // Dynamic fields from the schema. The confirm-account field
            // is injected directly beneath the primary account field.
            for (final field in _scheme.fields) ...[
              _buildField(field),
              if (field.key == primaryKey) ...[
                const SizedBox(height: 16),
                _buildConfirmField(field),
              ],
              const SizedBox(height: 16),
            ],
            // ── Contact (mandatory) ──
            _buildPhoneField(),
            const SizedBox(height: 16),
            _FormField(
              label: 'Email',
              hint: 'your@email.com',
              controller: _emailController,
              keyboardType: TextInputType.emailAddress,
              validator: (v) {
                final t = (v ?? '').trim();
                if (t.isEmpty) return 'Email is required';
                if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(t)) {
                  return 'Enter a valid email';
                }
                return null;
              },
            ),
            const SizedBox(height: 16),
            _SaveButton(
              isSaving: _isSaving,
              onTap: _isSaving ? null : _onSavePressed,
              label: _isEditing ? 'Review & Update' : 'Review & Save',
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildField(BankFieldSpec field) {
    if (field.kind == BankFieldKind.choice) {
      // Only pass a value the dropdown actually has an item for —
      // otherwise DropdownButton asserts. Stale cross-country values
      // are already cleared on switch; this is the belt-and-braces.
      final stored = _values[field.key] ?? '';
      final value =
          field.options.any((o) => o.value == stored) ? stored : null;
      return _ChoiceField(
        label: field.label,
        hint: field.hint,
        options: field.options,
        value: value,
        errorText: _choiceErrors[field.key],
        onChanged: (v) {
          setState(() {
            _values[field.key] = v ?? '';
            _choiceErrors[field.key] = null;
          });
        },
      );
    }

    final controller = _controllers[field.key]!;
    final value = controller.text;
    final isValid = value.trim().isNotEmpty && field.validate(value) == null;
    final isIfsc = field.key == 'bankIfscCode';
    final isPrimaryDigitAccount =
        field.key == 'bankAccountNumber' && field.keyboard == BankKeyboard.number;

    return _FormField(
      label: field.label,
      hint: field.hint,
      controller: controller,
      keyboardType: field.keyboard == BankKeyboard.number
          ? const TextInputType.numberWithOptions(decimal: false)
          : TextInputType.text,
      textCapitalization: field.uppercase
          ? TextCapitalization.characters
          : TextCapitalization.words,
      obscureText: isPrimaryDigitAccount && _obscureAccount,
      inputFormatters: _formattersFor(field),
      suffixIcon: _suffixFor(
        field: field,
        isValid: isValid,
        isIfsc: isIfsc,
        isPrimaryDigitAccount: isPrimaryDigitAccount,
      ),
      validator: (v) => field.validate(v ?? ''),
      onChanged: (v) => _onFieldChanged(field, v),
    );
  }

  Widget _buildConfirmField(BankFieldSpec primary) {
    return _FormField(
      label: 'Confirm ${primary.label}',
      hint: 'Re-enter ${primary.label.toLowerCase()}',
      controller: _confirmController,
      keyboardType: primary.keyboard == BankKeyboard.number
          ? const TextInputType.numberWithOptions(decimal: false)
          : TextInputType.text,
      textCapitalization: primary.uppercase
          ? TextCapitalization.characters
          : TextCapitalization.none,
      inputFormatters: _formattersFor(primary),
      validator: (v) {
        final a = (v ?? '').replaceAll(RegExp(r'\s'), '').toUpperCase();
        final b = (_values[primary.key] ?? '')
            .replaceAll(RegExp(r'\s'), '')
            .toUpperCase();
        if (a != b) return '${primary.label}s do not match';
        return null;
      },
      onChanged: (_) => setState(() {}),
    );
  }

  // Phone field with the country-code prefix (follows the bank country,
  // tappable to override). Validated against the selected country's real
  // length/format rules.
  Widget _buildPhoneField() {
    return _FormField(
      label: 'Phone Number',
      hint: '99999 99999',
      controller: _phoneController,
      keyboardType: TextInputType.phone,
      inputFormatters: [
        FilteringTextInputFormatter.digitsOnly,
        LengthLimitingTextInputFormatter(15),
      ],
      prefix: PhoneCountryPrefix(
        country: _phoneCountry,
        onSelected: (c) => setState(() => _phoneCountry = c),
      ),
      validator: (v) => validatePhoneForCountry(_phoneCountry, v ?? ''),
      onChanged: (_) {},
    );
  }

  List<TextInputFormatter> _formattersFor(BankFieldSpec field) {
    final list = <TextInputFormatter>[];
    if (field.keyboard == BankKeyboard.number && field.key != 'bankSortCode') {
      list.add(FilteringTextInputFormatter.digitsOnly);
    } else if (field.key == 'bankSortCode') {
      // Sort code: allow digits and the dashes people type ("12-34-56").
      list.add(FilteringTextInputFormatter.allow(RegExp(r'[0-9\-]')));
    }
    if (field.maxLength != null) {
      list.add(LengthLimitingTextInputFormatter(field.maxLength));
    }
    if (field.uppercase) {
      list.add(_UpperCaseTextFormatter());
    }
    return list;
  }

  Widget? _suffixFor({
    required BankFieldSpec field,
    required bool isValid,
    required bool isIfsc,
    required bool isPrimaryDigitAccount,
  }) {
    if (isIfsc && _ifscLookupInFlight) {
      return const Padding(
        padding: EdgeInsets.all(14),
        child: SizedBox(
          width: 26,
          height: 26,
          child: AppLoader(),
        ),
      );
    }
    if (isPrimaryDigitAccount) {
      // Eye toggle takes priority over the check on the account field.
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => setState(() => _obscureAccount = !_obscureAccount),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: AppIcon(
            _obscureAccount ? AppIcons.eyeOff : AppIcons.eye,
            size: 20,
            color: AppColors.muted,
          ),
        ),
      );
    }
    if (isValid) {
      return const Padding(
        padding: EdgeInsets.all(12),
        child: AppIcon(AppIcons.check, size: 18, color: AppColors.successGreen),
      );
    }
    return null;
  }

  void _openCountryPicker() {
    showCountryPicker(
      context: context,
      favorite: _kFavoriteCountries,
      useSafeArea: true,
      countryListTheme: CountryListThemeData(
        backgroundColor: AppColors.surfaceWhite,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        flagSize: 22,
        textStyle: GoogleFonts.inter(
          fontSize: 15,
          color: AppColors.deepDarkBrown,
        ),
        searchTextStyle: GoogleFonts.inter(
          fontSize: 15,
          color: AppColors.deepDarkBrown,
        ),
        inputDecoration: InputDecoration(
          hintText: 'Search country',
          hintStyle: GoogleFonts.inter(
            fontSize: 14,
            color: AppColors.muted.withValues(alpha: 0.6),
          ),
          prefixIcon: const Icon(Icons.search, size: 20),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(
              color: AppColors.muted.withValues(alpha: 0.2),
            ),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: AppColors.primaryBrown),
          ),
        ),
      ),
      onSelect: _onCountrySelected,
    );
  }
}

// ─── Country selector ──────────────────────────────────────────

class _CountrySelector extends StatelessWidget {
  final Country country;
  final ValueChanged<Country> onSelected;
  final VoidCallback onTap;

  const _CountrySelector({
    required this.country,
    required this.onSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Bank Account Country',
          style: GoogleFonts.inter(
            fontSize: 13,
            fontWeight: FontWeight.w500,
            color: AppColors.deepDarkBrown,
          ),
        ),
        const SizedBox(height: 8),
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              color: AppColors.surfaceWhite,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: AppColors.muted.withValues(alpha: 0.12),
              ),
            ),
            child: Row(
              children: [
                Text(country.flagEmoji,
                    style: const TextStyle(fontSize: 20)),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    country.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.inter(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: AppColors.deepDarkBrown,
                    ),
                  ),
                ),
                AppIcon(AppIcons.chevronDown,
                    size: 18, color: AppColors.muted),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

// ─── Review sheet ──────────────────────────────────────────────

// Last-chance confirmation before the details are saved and sent to
// the admin. Shows the destination country + currency and every field,
// with the account identifier masked to last-4.
class _ReviewSheet extends StatelessWidget {
  final BankDetails details;
  final BankAccountScheme scheme;

  const _ReviewSheet({required this.details, required this.scheme});

  @override
  Widget build(BuildContext context) {
    final paddingBottom = MediaQuery.of(context).padding.bottom;
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.surfaceWhite,
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(24),
          topRight: Radius.circular(24),
        ),
      ),
      padding: EdgeInsets.fromLTRB(24, 12, 24, paddingBottom + 20),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
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
            const SizedBox(height: 18),
            Text(
              'Confirm Bank Details',
              style: GoogleFonts.inter(
                fontSize: 19,
                fontWeight: FontWeight.w700,
                color: AppColors.deepDarkBrown,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Please check these are exactly right.',
              style: GoogleFonts.inter(
                fontSize: 13,
                fontWeight: FontWeight.w400,
                color: AppColors.muted,
              ),
            ),
            const SizedBox(height: 16),
            Container(
              decoration: BoxDecoration(
                color: AppColors.surfaceCream,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: AppColors.muted.withValues(alpha: 0.10),
                ),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Column(children: _rows()),
            ),
            const SizedBox(height: 22),
            _PressableScaleButton(
              label: 'Confirm & Save',
              onTap: () => Navigator.of(context).pop(true),
            ),
            const SizedBox(height: 6),
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => Navigator.of(context).pop(false),
              child: Container(
                height: 48,
                alignment: Alignment.center,
                child: Text(
                  'Go Back & Edit',
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: AppColors.muted,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _rows() {
    final rows = <Widget>[
      _ReviewRow('Country', '${scheme.countryIso}'
          '${scheme.currency.isEmpty ? '' : ' · ${scheme.currency}'}'),
    ];
    for (final field in scheme.fields) {
      final raw = details.valueForKey(field.key);
      if (raw.isEmpty) continue;
      String display;
      if (field.key == 'bankAccountNumber' || field.key == 'bankIban') {
        display = _maskIdentifier(raw);
      } else if (field.kind == BankFieldKind.choice) {
        // Show the human label ("Savings"), not the stored token.
        display = field.options
            .firstWhere(
              (o) => o.value == raw,
              orElse: () => BankFieldOption(raw, raw),
            )
            .label;
      } else {
        display = raw;
      }
      rows.add(_ReviewRow(field.label, display));
    }
    if (details.phone.isNotEmpty) {
      rows.add(_ReviewRow('Phone', phoneForDisplay(details.phone)));
    }
    if (details.email.isNotEmpty) {
      rows.add(_ReviewRow('Email', details.email));
    }
    return rows;
  }
}

class _ReviewRow extends StatelessWidget {
  final String label;
  final String value;
  const _ReviewRow(this.label, this.value);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 11),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(
              label,
              style: GoogleFonts.inter(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: AppColors.muted,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: GoogleFonts.inter(
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
                color: AppColors.deepDarkBrown,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PressableScaleButton extends StatefulWidget {
  final String label;
  final VoidCallback onTap;
  const _PressableScaleButton({required this.label, required this.onTap});

  @override
  State<_PressableScaleButton> createState() => _PressableScaleButtonState();
}

class _PressableScaleButtonState extends State<_PressableScaleButton> {
  double _scale = 1;
  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (_) => setState(() => _scale = 0.97),
      onPointerUp: (_) => setState(() => _scale = 1),
      onPointerCancel: (_) => setState(() => _scale = 1),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _scale,
          duration: const Duration(milliseconds: 120),
          child: Container(
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
      ),
    );
  }
}

// ─── Form leaves (shared with the old form's look) ─────────────

class _FormField extends StatelessWidget {
  final String label;
  final String hint;
  final TextEditingController controller;
  final TextInputType? keyboardType;
  final TextCapitalization textCapitalization;
  final bool obscureText;
  final Widget? suffixIcon;
  // Inline leading widget (the phone country-code chip). Rendered as the
  // field's prefixIcon, with unconstrained sizing so the chip isn't
  // squeezed into a square.
  final Widget? prefix;
  final String? Function(String?)? validator;
  final List<TextInputFormatter>? inputFormatters;
  final ValueChanged<String>? onChanged;

  const _FormField({
    required this.label,
    required this.hint,
    required this.controller,
    this.keyboardType,
    this.textCapitalization = TextCapitalization.none,
    this.obscureText = false,
    this.suffixIcon,
    this.prefix,
    this.validator,
    this.inputFormatters,
    this.onChanged,
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
          onChanged: onChanged,
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
            prefixIcon: prefix == null
                ? null
                : Padding(
                    padding: const EdgeInsets.only(left: 8, right: 2),
                    child: prefix,
                  ),
            prefixIconConstraints:
                const BoxConstraints(minWidth: 0, minHeight: 0),
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

class _ChoiceField extends StatelessWidget {
  final String label;
  final String hint;
  final List<BankFieldOption> options;
  final String? value;
  final String? errorText;
  final ValueChanged<String?> onChanged;

  const _ChoiceField({
    required this.label,
    required this.hint,
    required this.options,
    required this.value,
    required this.errorText,
    required this.onChanged,
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
        Container(
          decoration: BoxDecoration(
            color: AppColors.surfaceWhite,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: errorText != null
                  ? AppColors.errorRed
                  : AppColors.muted.withValues(alpha: 0.12),
            ),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: value,
              isExpanded: true,
              hint: Text(
                hint,
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.w400,
                  color: AppColors.muted.withValues(alpha: 0.5),
                ),
              ),
              icon: AppIcon(AppIcons.chevronDown,
                  size: 18, color: AppColors.muted),
              borderRadius: BorderRadius.circular(12),
              style: GoogleFonts.inter(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: AppColors.deepDarkBrown,
              ),
              items: options
                  .map((o) => DropdownMenuItem<String>(
                        value: o.value,
                        child: Text(o.label),
                      ))
                  .toList(),
              onChanged: onChanged,
            ),
          ),
        ),
        if (errorText != null) ...[
          const SizedBox(height: 6),
          Text(
            errorText!,
            style: GoogleFonts.inter(
              fontSize: 12,
              fontWeight: FontWeight.w400,
              color: AppColors.errorRed,
            ),
          ),
        ],
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
                      width: 35,
                      height: 35,
                      child: AppLoader(),
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

// Force-uppercase input (IFSC / IBAN / SWIFT) as the priest types so
// the visible value matches the validators without an extra round-trip.
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
