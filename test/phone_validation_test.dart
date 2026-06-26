// Verifies the country-aware phone validation actually applies each
// country's real rules (length/format), not a one-size length check.
import 'package:country_picker/country_picker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gospel_vox/core/widgets/phone_country_prefix.dart';

void main() {
  Country c(String iso) => CountryService().findByCode(iso)!;

  test('each country accepts its own example number', () {
    for (final iso in ['IN', 'US', 'GB', 'AE', 'SA', 'QA', 'KW', 'AU', 'CA']) {
      final country = c(iso);
      expect(
        validatePhoneForCountry(country, country.example),
        isNull,
        reason: '$iso example "${country.example}" should be valid',
      );
    }
  });

  test('empty number is rejected as required', () {
    expect(validatePhoneForCountry(c('IN'), ''), isNotNull);
  });

  test('too-short numbers are rejected', () {
    expect(validatePhoneForCountry(c('IN'), '123'), isNotNull);
    expect(validatePhoneForCountry(c('AE'), '12'), isNotNull);
  });

  test('length is country-specific (not one-size)', () {
    // Qatar national numbers are 8 digits — a 10-digit India-style number
    // must fail there, proving the rule is per-country, not generic.
    expect(validatePhoneForCountry(c('QA'), '9876543210'), isNotNull);
    // And India must reject an 8-digit number that would be fine in Qatar.
    expect(validatePhoneForCountry(c('IN'), '12345678'), isNotNull);
  });
}
