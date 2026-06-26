// Pure, offline validators for the bank fields collected on the
// priest withdrawal form.
//
// Why this file exists:
//   The withdrawal model is being rebuilt to collect each priest's
//   own-country bank details (India IFSC, US routing, UK sort code,
//   IBAN/SWIFT for Europe + GCC). Before any of that data is sent to
//   the admin for a manual bank transfer, we want to catch the
//   obvious mistake — a mistyped or impossible number — at the form
//   itself. Wrong-but-valid-looking data is the single biggest cause
//   of failed/misrouted manual payouts.
//
// What these checks DO and DON'T do:
//   • DO  — prove a value is well-formed: correct length, correct
//           character shape, and (where the standard defines one) a
//           correct checksum. IBAN and US routing numbers both carry
//           a checksum, so a single mistyped digit is caught with
//           near-certainty. IFSC / SWIFT are pattern-only.
//   • DON'T — prove the account actually exists or belongs to the
//           priest. Only a real transfer (or a penny-drop, which
//           needs a payout provider we deliberately do NOT use) can
//           confirm that. The form copy must stay honest about this.
//
// Contract: every validator returns `null` when the value is valid,
// or a short user-facing error string otherwise — the same shape as
// `validatePhoneForCountry` in phone_country_prefix.dart, so the
// form layer treats bank + phone validation identically.
//
// All validators are tolerant of the way people actually paste these
// values: surrounding whitespace, internal spaces (IBAN / SWIFT are
// routinely written in groups), and lower-case are normalised away
// before the check, so a correct value is never rejected on cosmetics.
library;

// ─── India: IFSC ───────────────────────────────────────────────
//
// 11 characters: 4-letter bank code, a mandatory '0' in the 5th
// position (reserved by RBI for future use), then a 6-char
// alphanumeric branch code. This is the same regex the existing
// bank-details form and the IFSC autofill already use — kept here so
// every IFSC check in the app shares one definition.
String? validateIfsc(String input) {
  final v = input.trim().toUpperCase();
  if (v.isEmpty) return 'IFSC code is required';
  if (!RegExp(r'^[A-Z]{4}0[A-Z0-9]{6}$').hasMatch(v)) {
    return 'Enter a valid IFSC code';
  }
  return null;
}

// ─── USA: ABA routing number ───────────────────────────────────
//
// 9 digits with a weighted checksum (the ABA routing transit number
// check digit). The weights repeat 3-7-1 across the nine digits and
// the weighted sum must be a multiple of 10. This catches a single
// mistyped digit, which a plain length check would miss.
String? validateUsRoutingNumber(String input) {
  final d = input.replaceAll(RegExp(r'\D'), '');
  if (d.isEmpty) return 'Routing number is required';
  if (d.length != 9) return 'Routing number must be 9 digits';
  final n = d.codeUnits.map((u) => u - 0x30).toList(growable: false);
  final sum = 3 * (n[0] + n[3] + n[6]) +
      7 * (n[1] + n[4] + n[7]) +
      1 * (n[2] + n[5] + n[8]);
  if (sum % 10 != 0) return 'Enter a valid routing number';
  return null;
}

// ─── UK: sort code ─────────────────────────────────────────────
//
// 6 digits, commonly written "12-34-56". No public checksum (the
// modulus check needs the bank's weight table, which isn't bundled),
// so this is a length/shape check only.
String? validateUkSortCode(String input) {
  final d = input.replaceAll(RegExp(r'\D'), '');
  if (d.isEmpty) return 'Sort code is required';
  if (d.length != 6) return 'Sort code must be 6 digits';
  return null;
}

// ─── Europe + GCC: IBAN ────────────────────────────────────────
//
// International Bank Account Number (ISO 13616). Structure: 2-letter
// country code, 2 check digits, then up to 30 country-specific
// chars (total 15-34). The check digits are an ISO 7064 MOD-97-10
// checksum over the whole number, so a mistyped character is caught
// with ~99% certainty — the strongest offline check we have.
//
// Algorithm:
//   1. strip spaces, upper-case;
//   2. move the first 4 chars (country + check digits) to the end;
//   3. replace each letter with two digits (A=10 … Z=35);
//   4. the resulting integer mod 97 must equal 1.
// We compute the mod iteratively digit-by-digit so we never need a
// big-integer type for the (up to ~38-digit) expanded value.
String? validateIban(String input) {
  final v = input.replaceAll(RegExp(r'\s'), '').toUpperCase();
  if (v.isEmpty) return 'IBAN is required';
  if (v.length < 15 || v.length > 34) return 'Enter a valid IBAN';
  if (!RegExp(r'^[A-Z]{2}[0-9]{2}[A-Z0-9]+$').hasMatch(v)) {
    return 'Enter a valid IBAN';
  }
  final numeric = _ibanToNumericString(v);
  if (numeric == null || _iso7064Mod97(numeric) != 1) {
    return 'Enter a valid IBAN';
  }
  return null;
}

// ─── International: SWIFT / BIC ─────────────────────────────────
//
// Bank Identifier Code (ISO 9362): 4-letter bank code, 2-letter
// country code, 2-char location code, and an optional 3-char branch
// code — so 8 or 11 characters total. Pattern-only (no checksum in
// the standard).
String? validateSwiftBic(String input) {
  final v = input.replaceAll(RegExp(r'\s'), '').toUpperCase();
  if (v.isEmpty) return 'SWIFT / BIC code is required';
  if (!RegExp(r'^[A-Z]{6}[A-Z0-9]{2}([A-Z0-9]{3})?$').hasMatch(v)) {
    return 'Enter a valid SWIFT / BIC code';
  }
  return null;
}

// ─── Generic account number (digits, length-bounded) ───────────
//
// Used for India (9-18) and US (4-17) account numbers, where there's
// no bundled checksum. `min`/`max` let one function serve every
// country's digit-length rule. Internal spaces are stripped so a
// pasted "1234 5678 9012" passes.
String? validateAccountDigits(
  String input, {
  required int min,
  required int max,
}) {
  final d = input.replaceAll(RegExp(r'\s'), '');
  if (d.isEmpty) return 'Account number is required';
  if (!RegExp(r'^\d+$').hasMatch(d)) {
    return 'Account number must be digits only';
  }
  if (d.length < min || d.length > max) {
    return 'Enter a valid account number ($min-$max digits)';
  }
  return null;
}

// ─── Account holder name ───────────────────────────────────────
//
// At least one letter to start, then letters / spaces / . ' - — the
// punctuation real bank names carry (initials "S. R. Joseph",
// "D'Souza", "Mary-Anne"). Unicode letters are allowed so a foreign
// priest's romanised-with-accents name (e.g. "José") isn't blocked.
String? validateAccountHolderName(String input) {
  final v = input.trim();
  if (v.isEmpty) return 'Account holder name is required';
  if (v.length < 3) return 'Name must be at least 3 characters';
  if (!RegExp(r"^[\p{L}][\p{L}\s.'\-]*$", unicode: true).hasMatch(v)) {
    return "Use letters, spaces, . ' - only";
  }
  return null;
}

// ─── internals ─────────────────────────────────────────────────

// Rearranges an IBAN (first 4 chars to the end) and expands every
// letter to its two-digit value (A=10 … Z=35), yielding the numeric
// string the MOD-97 checksum runs over. Returns null on any char
// outside [0-9A-Z] — the caller has already shape-checked, so this
// is just defensive.
String? _ibanToNumericString(String iban) {
  final rearranged = '${iban.substring(4)}${iban.substring(0, 4)}';
  final buf = StringBuffer();
  for (final unit in rearranged.codeUnits) {
    if (unit >= 0x30 && unit <= 0x39) {
      buf.writeCharCode(unit); // 0-9
    } else if (unit >= 0x41 && unit <= 0x5A) {
      buf.write((unit - 55).toString()); // A(65)->10 … Z(90)->35
    } else {
      return null;
    }
  }
  return buf.toString();
}

// ISO 7064 MOD-97-10 over a (possibly very long) numeric string,
// computed iteratively so no big-integer type is needed.
int _iso7064Mod97(String numeric) {
  int remainder = 0;
  for (final unit in numeric.codeUnits) {
    remainder = (remainder * 10 + (unit - 0x30)) % 97;
  }
  return remainder;
}
