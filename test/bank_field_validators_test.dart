// Proves the offline bank-field validators apply each standard's real
// rules — checksums included — not just length checks. The IBAN and
// US-routing cases use publicly documented valid numbers and a
// single-digit corruption of each, so a broken checksum implementation
// fails loudly here instead of silently passing bad payout data.
import 'package:flutter_test/flutter_test.dart';
import 'package:gospel_vox/features/priest/wallet/data/bank_field_validators.dart';

void main() {
  group('IFSC', () {
    test('accepts well-formed codes', () {
      expect(validateIfsc('SBIN0001234'), isNull);
      expect(validateIfsc('HDFC0001234'), isNull);
      // lower-case + surrounding space must still pass
      expect(validateIfsc('  hdfc0001234  '), isNull);
    });
    test('rejects malformed codes', () {
      expect(validateIfsc(''), isNotNull);
      expect(validateIfsc('SBIN1001234'), isNotNull); // 5th char not 0
      expect(validateIfsc('SBI0001234'), isNotNull); // too short
      expect(validateIfsc('SBIN00012345'), isNotNull); // too long
    });
  });

  group('US routing number (ABA checksum)', () {
    test('accepts real, checksum-valid numbers', () {
      expect(validateUsRoutingNumber('021000021'), isNull); // Chase
      expect(validateUsRoutingNumber('011401533'), isNull); // valid
      expect(validateUsRoutingNumber('021 000 021'), isNull); // spaced
    });
    test('rejects checksum failures and wrong lengths', () {
      expect(validateUsRoutingNumber('021000020'), isNotNull); // bad digit
      expect(validateUsRoutingNumber('12345678'), isNotNull); // 8 digits
      expect(validateUsRoutingNumber(''), isNotNull);
    });
  });

  group('UK sort code', () {
    test('accepts 6 digits in any common form', () {
      expect(validateUkSortCode('123456'), isNull);
      expect(validateUkSortCode('12-34-56'), isNull);
    });
    test('rejects wrong length', () {
      expect(validateUkSortCode('12345'), isNotNull);
      expect(validateUkSortCode('1234567'), isNotNull);
      expect(validateUkSortCode(''), isNotNull);
    });
  });

  group('IBAN (MOD-97 checksum)', () {
    test('accepts documented valid IBANs', () {
      expect(validateIban('GB82WEST12345698765432'), isNull); // UK
      expect(validateIban('DE89370400440532013000'), isNull); // Germany
      expect(validateIban('SA0380000000608010167519'), isNull); // Saudi
      // grouped + lower-case, as people paste it
      expect(validateIban('gb82 west 1234 5698 7654 32'), isNull);
    });
    test('rejects a single-character corruption (checksum catches it)', () {
      expect(validateIban('GB82WEST12345698765433'), isNotNull); // last digit
      expect(validateIban('DE89370400440532013001'), isNotNull);
    });
    test('rejects structurally wrong values', () {
      expect(validateIban(''), isNotNull);
      expect(validateIban('GB82'), isNotNull); // too short
      expect(validateIban('1234WEST12345698765432'), isNotNull); // no country
    });
  });

  group('SWIFT / BIC', () {
    test('accepts 8- and 11-char codes', () {
      expect(validateSwiftBic('HDFCINBB'), isNull);
      expect(validateSwiftBic('HDFCINBBXXX'), isNull);
      expect(validateSwiftBic('deutdeff'), isNull); // lower-case
    });
    test('rejects malformed codes', () {
      expect(validateSwiftBic('HDFCIN'), isNotNull); // too short
      expect(validateSwiftBic('HDFC1NBB'), isNotNull); // digit in country pos
      expect(validateSwiftBic(''), isNotNull);
    });
  });

  group('account number (length-bounded)', () {
    test('honours per-country min/max', () {
      expect(validateAccountDigits('123456789', min: 9, max: 18), isNull);
      expect(validateAccountDigits('1234 5678', min: 4, max: 17), isNull);
    });
    test('rejects empty, non-digit, and out-of-range', () {
      expect(validateAccountDigits('', min: 9, max: 18), isNotNull);
      expect(validateAccountDigits('12AB56789', min: 9, max: 18), isNotNull);
      expect(validateAccountDigits('1234', min: 9, max: 18), isNotNull);
    });
  });

  group('account holder name', () {
    test('accepts real-world name shapes', () {
      expect(validateAccountHolderName('John Mathew'), isNull);
      expect(validateAccountHolderName("S. R. D'Souza"), isNull);
      expect(validateAccountHolderName('José Fernández'), isNull); // accents
    });
    test('rejects empty, too-short, and bad characters', () {
      expect(validateAccountHolderName(''), isNotNull);
      expect(validateAccountHolderName('Jo'), isNotNull);
      expect(validateAccountHolderName('John123'), isNotNull);
    });
  });
}
