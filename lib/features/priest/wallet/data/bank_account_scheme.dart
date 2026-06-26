// Country-aware schema for the priest bank-details form.
//
// The withdrawal rebuild collects each priest's OWN-country bank
// details. A US priest has a routing number, not an IFSC; a UK priest
// has a sort code; Europe + GCC use IBAN + SWIFT. Rather than branch
// the form on country with a pile of if/else, this file describes —
// as plain data — exactly which fields each country needs, how to
// label/validate/format each one, and which currency the payout is in.
// The form (next step) just renders whatever `resolveBankScheme`
// hands it, so adding a country later is a data change, not a UI
// rewrite.
//
// Storage-key compatibility (important):
//   The universal fields keep the SAME Firestore keys the app already
//   writes — bankAccountName / bankAccountNumber / bankIfscCode /
//   bankName / bankAccountType — so an India record saved through this
//   schema is identical to one saved by the old form, and the existing
//   requestWithdrawal Cloud Function keeps working untouched. New
//   countries only ADD keys (bankRoutingNumber, bankSortCode,
//   bankIban, bankSwiftBic); they never rename or drop the old ones.
//
// Validation:
//   Every text field points at a validator from bank_field_validators
//   (the checksum-backed, unit-tested logic from step 1). This file
//   only adds thin glue — per-country length bounds and the few
//   "required non-empty" / choice checks that have no standard.
library;

import 'package:gospel_vox/features/priest/wallet/data/bank_field_validators.dart';

// ─── Field building blocks ─────────────────────────────────────

// Whether a field is free text or a fixed choice (account type).
enum BankFieldKind { text, choice }

// Drives the keyboard the form shows. `number` for digit-only fields
// (account / routing / sort code), `text` for everything else.
enum BankKeyboard { text, number }

// One selectable option for a `choice` field (e.g. Savings / Current).
class BankFieldOption {
  final String value; // stored token, lower-case
  final String label; // shown to the priest
  const BankFieldOption(this.value, this.label);
}

// A single field in a country's bank form.
class BankFieldSpec {
  // Firestore key this field is saved under. Aligned with the keys the
  // app already uses for the universal fields (see file header).
  final String key;
  final BankFieldKind kind;
  final String label;
  final String hint;
  final BankKeyboard keyboard;
  // Upper-case as the priest types — IFSC / IBAN / SWIFT are always
  // upper-case, and forcing it avoids a validation failure on an
  // otherwise-correct lower-case paste.
  final bool uppercase;
  // Hard input cap (keystroke + paste). Null = no cap.
  final int? maxLength;
  // Choice options — empty unless kind == choice.
  final List<BankFieldOption> options;
  // Returns null when valid, else a short message. For choice fields
  // this checks the value is one of `options`.
  final String? Function(String) validate;

  const BankFieldSpec({
    required this.key,
    required this.label,
    required this.hint,
    required this.validate,
    this.kind = BankFieldKind.text,
    this.keyboard = BankKeyboard.text,
    this.uppercase = false,
    this.maxLength,
    this.options = const [],
  });
}

// The full form for one country: which currency the payout is in, and
// the ordered list of fields to collect.
class BankAccountScheme {
  final String countryIso; // 'IN', 'US', …  (normalised upper-case)
  final String currency; // 'INR', 'USD', …  ('' when unknown)
  final List<BankFieldSpec> fields;
  const BankAccountScheme({
    required this.countryIso,
    required this.currency,
    required this.fields,
  });
}

// ─── Resolution ────────────────────────────────────────────────

// Maps a country ISO (alpha-2) to its bank form. Unknown countries
// fall back to a universal SWIFT-based international form, which works
// for any country on earth — so a priest is never blocked, even from a
// market we haven't special-cased.
BankAccountScheme resolveBankScheme(String isoCode) {
  final iso = isoCode.trim().toUpperCase();
  switch (iso) {
    case 'IN':
      return _indiaScheme;
    case 'US':
      return _usaScheme;
    case 'GB':
      return _ukScheme;
    default:
      if (_ibanCountries.contains(iso)) {
        return _ibanScheme(iso, _currencyFor(iso));
      }
      return _internationalScheme(iso, _currencyFor(iso));
  }
}

// ─── Shared field validators (glue with no banking standard) ───

String? _validateRequiredBankName(String v) =>
    v.trim().isEmpty ? 'Bank name is required' : null;

// Branch name (India). Auto-filled from the IFSC lookup, but the priest
// can correct it — so we only require it to be non-empty, not match any
// directory value.
String? _validateRequiredBranchName(String v) =>
    v.trim().isEmpty ? 'Branch name is required' : null;

// Generic international account/IBAN identifier — alphanumeric, 4-34,
// because a non-IBAN foreign account number can contain letters and we
// can't assume a checksum. Kept here (not in bank_field_validators)
// because it's a fallback convenience, not a real standard.
String? _validateGenericAccount(String input) {
  final v = input.replaceAll(RegExp(r'\s'), '');
  if (v.isEmpty) return 'Account number is required';
  if (!RegExp(r'^[A-Za-z0-9]{4,34}$').hasMatch(v)) {
    return 'Enter a valid account number';
  }
  return null;
}

// Builds a choice validator bound to its option set.
String? Function(String) _choiceValidator(
  List<BankFieldOption> options,
  String message,
) {
  return (v) => options.any((o) => o.value == v) ? null : message;
}

// ─── Reusable field specs ──────────────────────────────────────

const _holderNameField = BankFieldSpec(
  key: 'bankAccountName',
  label: 'Account Holder Name',
  hint: 'Exactly as printed on your bank account',
  validate: validateAccountHolderName,
);

const _bankNameField = BankFieldSpec(
  key: 'bankName',
  label: 'Bank Name',
  hint: 'e.g. State Bank of India',
  validate: _validateRequiredBankName,
);

// Account-type option sets — declared once and referenced by BOTH the
// field's `options` (what the priest picks from) and its choice
// validator, so the two can never drift apart.
const List<BankFieldOption> _indiaAccountTypes = [
  BankFieldOption('savings', 'Savings'),
  BankFieldOption('current', 'Current'),
];
const List<BankFieldOption> _usAccountTypes = [
  BankFieldOption('checking', 'Checking'),
  BankFieldOption('savings', 'Savings'),
];

// ─── Country schemes ───────────────────────────────────────────

final _indiaScheme = BankAccountScheme(
  countryIso: 'IN',
  currency: 'INR',
  fields: [
    _holderNameField,
    BankFieldSpec(
      key: 'bankAccountNumber',
      label: 'Account Number',
      hint: 'Enter account number',
      keyboard: BankKeyboard.number,
      maxLength: 18,
      validate: (v) => validateAccountDigits(v, min: 9, max: 18),
    ),
    const BankFieldSpec(
      key: 'bankIfscCode',
      label: 'IFSC Code',
      hint: 'e.g. SBIN0001234',
      uppercase: true,
      maxLength: 11,
      validate: validateIfsc,
    ),
    _bankNameField,
    BankFieldSpec(
      key: 'bankBranchName',
      label: 'Branch Name',
      hint: 'e.g. M.G. Road, Bengaluru',
      maxLength: 60,
      validate: _validateRequiredBranchName,
    ),
    BankFieldSpec(
      key: 'bankAccountType',
      kind: BankFieldKind.choice,
      label: 'Account Type',
      hint: 'Select account type',
      options: _indiaAccountTypes,
      validate: _choiceValidator(
        _indiaAccountTypes,
        'Select an account type',
      ),
    ),
  ],
);

final _usaScheme = BankAccountScheme(
  countryIso: 'US',
  currency: 'USD',
  fields: [
    _holderNameField,
    BankFieldSpec(
      key: 'bankAccountNumber',
      label: 'Account Number',
      hint: 'Enter account number',
      keyboard: BankKeyboard.number,
      maxLength: 17,
      validate: (v) => validateAccountDigits(v, min: 4, max: 17),
    ),
    const BankFieldSpec(
      key: 'bankRoutingNumber',
      label: 'Routing Number (ABA)',
      hint: '9-digit routing number',
      keyboard: BankKeyboard.number,
      maxLength: 9,
      validate: validateUsRoutingNumber,
    ),
    _bankNameField,
    BankFieldSpec(
      key: 'bankAccountType',
      kind: BankFieldKind.choice,
      label: 'Account Type',
      hint: 'Select account type',
      options: _usAccountTypes,
      validate: _choiceValidator(
        _usAccountTypes,
        'Select an account type',
      ),
    ),
  ],
);

final _ukScheme = BankAccountScheme(
  countryIso: 'GB',
  currency: 'GBP',
  fields: [
    _holderNameField,
    BankFieldSpec(
      key: 'bankAccountNumber',
      label: 'Account Number',
      hint: '8-digit account number',
      keyboard: BankKeyboard.number,
      maxLength: 8,
      validate: (v) => validateAccountDigits(v, min: 8, max: 8),
    ),
    const BankFieldSpec(
      key: 'bankSortCode',
      label: 'Sort Code',
      hint: 'e.g. 12-34-56',
      keyboard: BankKeyboard.number,
      maxLength: 8, // 6 digits + 2 dashes if the priest types them
      validate: validateUkSortCode,
    ),
    _bankNameField,
  ],
);

// Europe + GCC: the IBAN is the account identifier (no separate
// account number), SWIFT/BIC routes the wire.
BankAccountScheme _ibanScheme(String iso, String currency) {
  return BankAccountScheme(
    countryIso: iso,
    currency: currency,
    fields: [
      _holderNameField,
      const BankFieldSpec(
        key: 'bankIban',
        label: 'IBAN',
        hint: 'Your full IBAN',
        uppercase: true,
        maxLength: 34,
        validate: validateIban,
      ),
      const BankFieldSpec(
        key: 'bankSwiftBic',
        label: 'SWIFT / BIC',
        hint: '8 or 11 characters',
        uppercase: true,
        maxLength: 11,
        validate: validateSwiftBic,
      ),
      _bankNameField,
    ],
  );
}

// Any other country: account number + SWIFT + bank name is enough for
// the admin to forward an international transfer to their bank. The
// country itself is already captured on the scheme, so the admin
// always knows the destination.
BankAccountScheme _internationalScheme(String iso, String currency) {
  return BankAccountScheme(
    countryIso: iso,
    currency: currency,
    fields: [
      _holderNameField,
      BankFieldSpec(
        key: 'bankAccountNumber',
        label: 'Account Number / IBAN',
        hint: 'Your account number or IBAN',
        uppercase: true,
        maxLength: 34,
        validate: _validateGenericAccount,
      ),
      const BankFieldSpec(
        key: 'bankSwiftBic',
        label: 'SWIFT / BIC',
        hint: '8 or 11 characters',
        uppercase: true,
        maxLength: 11,
        validate: validateSwiftBic,
      ),
      _bankNameField,
    ],
  );
}

// ─── Country reference data ────────────────────────────────────

// Countries routed to the IBAN form. GCC (the rollout markets) plus
// the common Eurozone/European IBAN countries. Anything not listed
// still works via the international SWIFT form, so this list only
// needs to be "good enough", never exhaustive.
const Set<String> _ibanCountries = {
  // GCC
  'AE', 'SA', 'QA', 'KW', 'OM', 'BH',
  // Eurozone / Europe (common)
  'DE', 'FR', 'ES', 'IT', 'NL', 'BE', 'IE', 'PT', 'AT', 'FI',
  'GR', 'LU', 'CY', 'MT', 'SK', 'SI', 'EE', 'LV', 'LT', 'CH',
  'NO', 'SE', 'DK', 'PL',
};

// Payout currency per country. Covers the live + rollout markets; an
// unlisted country resolves to '' (currency simply not shown until we
// add it — never blocks the priest).
const Map<String, String> _currencyByIso = {
  'IN': 'INR', 'US': 'USD', 'GB': 'GBP',
  'AE': 'AED', 'SA': 'SAR', 'QA': 'QAR', 'KW': 'KWD',
  'OM': 'OMR', 'BH': 'BHD',
  'CA': 'CAD', 'AU': 'AUD',
  'DE': 'EUR', 'FR': 'EUR', 'ES': 'EUR', 'IT': 'EUR', 'NL': 'EUR',
  'BE': 'EUR', 'IE': 'EUR', 'PT': 'EUR', 'AT': 'EUR', 'FI': 'EUR',
  'GR': 'EUR', 'LU': 'EUR', 'CY': 'EUR', 'MT': 'EUR', 'SK': 'EUR',
  'SI': 'EUR', 'EE': 'EUR', 'LV': 'EUR', 'LT': 'EUR',
  'CH': 'CHF', 'NO': 'NOK', 'SE': 'SEK', 'DK': 'DKK', 'PL': 'PLN',
};

String _currencyFor(String iso) => _currencyByIso[iso] ?? '';
