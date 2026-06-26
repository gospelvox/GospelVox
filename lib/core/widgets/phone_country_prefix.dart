// Country-code selector used as the prefix of the priest phone fields
// (registration + profile editing). Replaces the old hardcoded "+91"
// text so priests outside India (US / UK / GCC) can enter their real
// number — the phone is a contact field only (never used for auth/OTP),
// so this is purely a UX upgrade.
//
// Backed by country_picker, which is PURE DART (bundles its own country
// data + flag emojis) — no native code, no manifest/Gradle changes, so
// it can't affect the native build.
//
// Storage contract (see helpers below): the phone is saved as
// "+<dialCode> <nationalNumber>", e.g. "+1 4155551234". Existing legacy
// records hold a bare 10-digit Indian number with no "+"; the display +
// parse helpers fall back to +91 for those so nothing needs migrating.

import 'package:country_picker/country_picker.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:phone_numbers_parser/phone_numbers_parser.dart';

import 'package:gospel_vox/core/theme/app_colors.dart';

const String _kDefaultIso = 'IN';
const String _kDefaultDialCode = '91';

// Markets surfaced at the top of the picker (India-first, then the
// rollout markets). Everything else is still reachable via search.
const List<String> _kFavoriteCountries = [
  'IN', 'US', 'GB', 'AE', 'SA', 'QA', 'KW', 'OM', 'BH', 'CA', 'AU',
];

final CountryService _countryService = CountryService();

// The default country a brand-new field starts on.
Country defaultPhoneCountry() =>
    _countryService.findByCode(_kDefaultIso) ?? Country.parse(_kDefaultIso);

// Resolve the Country to pre-select when re-opening an existing phone.
// Parses the dial code out of a stored "+<code> <number>" string and
// finds the first country with that dial code (exact for unique codes
// like +91; first-match for shared codes like +1 — the dial code itself
// is always correct, only the flag is best-effort). Legacy bare-digit
// records fall back to India.
Country phoneCountryFromStored(String? stored) {
  final s = stored?.trim() ?? '';
  if (!s.startsWith('+')) return defaultPhoneCountry();
  final dialCode = s.substring(1).split(' ').first.trim();
  if (dialCode.isEmpty) return defaultPhoneCountry();
  for (final c in _countryService.getAll()) {
    if (c.phoneCode == dialCode) return c;
  }
  return defaultPhoneCountry();
}

// Extract just the national number (digits the user typed) from a stored
// value, for pre-filling the number text field on edit.
String phoneNumberFromStored(String? stored) {
  final s = stored?.trim() ?? '';
  if (s.isEmpty) return '';
  if (!s.startsWith('+')) return s; // legacy: whole value is the number
  final parts = s.substring(1).split(' ');
  return parts.length > 1 ? parts.sublist(1).join(' ').trim() : '';
}

// Country-aware phone validation. Returns null when the typed national
// number is a valid phone number for the selected country, otherwise a
// short error message. Backed by phone_numbers_parser (libphonenumber
// metadata) so each country's real length/format rules apply — India 10
// digits, UAE/Saudi 9, Qatar/Kuwait 8, etc. — instead of a one-size
// length check. We accept fixed-line OR mobile (a priest may list a
// landline as their contact).
String? validatePhoneForCountry(Country country, String number) {
  final raw = number.trim();
  if (raw.isEmpty) return 'Phone number is required';
  try {
    final iso = IsoCode.values.byName(country.countryCode.toUpperCase());
    final parsed = PhoneNumber.parse(raw, callerCountry: iso);
    if (!parsed.isValid()) {
      return 'Enter a valid ${country.name} phone number';
    }
    return null;
  } catch (_) {
    // Country missing from the parser's metadata (rare) — fall back to a
    // loose length check so a legitimate number is never hard-blocked.
    final digits = raw.replaceAll(RegExp(r'\D'), '');
    return (digits.length >= 4 && digits.length <= 15)
        ? null
        : 'Enter a valid phone number';
  }
}

// Build the value to persist from a chosen country + typed number.
String composePhone(Country country, String number) {
  final n = number.trim();
  if (n.isEmpty) return '';
  return '+${country.phoneCode} $n';
}

// Human-readable phone for display surfaces (review step, admin panel,
// profile view). New records already carry their "+code"; legacy
// India-only records get a +91 prefix so they still read correctly.
String phoneForDisplay(String? stored) {
  final s = stored?.trim() ?? '';
  if (s.isEmpty) return '—';
  if (s.startsWith('+')) return s;
  return '+$_kDefaultDialCode $s';
}

// The tappable flag + dial-code chip. Drops into any field that exposes a
// `prefix` slot, or stands alone. Opens a searchable country sheet.
class PhoneCountryPrefix extends StatelessWidget {
  final Country country;
  final ValueChanged<Country> onSelected;
  final bool enabled;

  const PhoneCountryPrefix({
    super.key,
    required this.country,
    required this.onSelected,
    this.enabled = true,
  });

  void _open(BuildContext context) {
    showCountryPicker(
      context: context,
      showPhoneCode: true,
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
      onSelect: onSelected,
    );
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: enabled ? () => _open(context) : null,
      child: Padding(
        padding: const EdgeInsets.only(right: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              country.flagEmoji,
              style: const TextStyle(fontSize: 18),
            ),
            const SizedBox(width: 5),
            Text(
              '+${country.phoneCode}',
              style: GoogleFonts.inter(
                fontSize: 15,
                fontWeight: FontWeight.w500,
                color: AppColors.deepDarkBrown,
              ),
            ),
            Icon(
              Icons.arrow_drop_down,
              size: 18,
              color: AppColors.muted.withValues(alpha: 0.7),
            ),
          ],
        ),
      ),
    );
  }
}
