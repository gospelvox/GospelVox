// Proves resolveBankScheme hands the form the right fields, currency,
// and storage keys per country, and that the wired validators (from
// step 1) actually fire through the schema. The storage-key assertions
// are the important guard: they lock in compatibility with the keys
// the live requestWithdrawal function already reads, so a future edit
// that renames a key breaks here instead of in production.
import 'package:flutter_test/flutter_test.dart';
import 'package:gospel_vox/features/priest/wallet/data/bank_account_scheme.dart';

void main() {
  List<String> keys(BankAccountScheme s) =>
      s.fields.map((f) => f.key).toList();

  BankFieldSpec field(BankAccountScheme s, String key) =>
      s.fields.firstWhere((f) => f.key == key);

  group('India', () {
    final s = resolveBankScheme('IN');
    test('currency + ordered keys', () {
      expect(s.currency, 'INR');
      expect(keys(s), [
        'bankAccountName',
        'bankAccountNumber',
        'bankIfscCode',
        'bankName',
        'bankAccountType',
      ]);
    });
    test('IFSC field uses the checksum-style validator', () {
      final f = field(s, 'bankIfscCode');
      expect(f.validate('SBIN0001234'), isNull);
      expect(f.validate('SBIN1001234'), isNotNull); // 5th char not 0
      expect(f.uppercase, isTrue);
    });
    test('account type choice rejects unknown values', () {
      final f = field(s, 'bankAccountType');
      expect(f.kind, BankFieldKind.choice);
      expect(f.validate('savings'), isNull);
      expect(f.validate('current'), isNull);
      expect(f.validate('checking'), isNotNull); // US-only value
    });
  });

  group('USA', () {
    final s = resolveBankScheme('US');
    test('currency + has routing, no IFSC', () {
      expect(s.currency, 'USD');
      expect(keys(s), contains('bankRoutingNumber'));
      expect(keys(s), isNot(contains('bankIfscCode')));
    });
    test('routing field enforces the ABA checksum', () {
      final f = field(s, 'bankRoutingNumber');
      expect(f.validate('021000021'), isNull);
      expect(f.validate('021000020'), isNotNull); // checksum fail
    });
    test('account type uses US values', () {
      final f = field(s, 'bankAccountType');
      expect(f.validate('checking'), isNull);
      expect(f.validate('current'), isNotNull); // India-only value
    });
  });

  group('UK', () {
    final s = resolveBankScheme('GB');
    test('currency + sort code, 8-digit account', () {
      expect(s.currency, 'GBP');
      expect(keys(s), contains('bankSortCode'));
      final acct = field(s, 'bankAccountNumber');
      expect(acct.validate('12345678'), isNull); // exactly 8
      expect(acct.validate('1234567'), isNotNull); // 7 rejected
      expect(acct.validate('123456789'), isNotNull); // 9 rejected
    });
  });

  group('GCC / IBAN country', () {
    final s = resolveBankScheme('AE');
    test('uses IBAN + SWIFT, no plain account number', () {
      expect(s.currency, 'AED');
      expect(keys(s), containsAll(['bankIban', 'bankSwiftBic']));
      expect(keys(s), isNot(contains('bankAccountNumber')));
    });
    test('IBAN field enforces MOD-97', () {
      final f = field(s, 'bankIban');
      expect(f.validate('GB82WEST12345698765432'), isNull);
      expect(f.validate('GB82WEST12345698765433'), isNotNull); // corrupt
    });
  });

  group('unknown country (international fallback)', () {
    final s = resolveBankScheme('BR'); // Brazil — not special-cased
    test('falls back to account + SWIFT, never blocks', () {
      expect(keys(s), [
        'bankAccountName',
        'bankAccountNumber',
        'bankSwiftBic',
        'bankName',
      ]);
      // generic account accepts alphanumeric foreign formats
      final acct = field(s, 'bankAccountNumber');
      expect(acct.validate('BR1500000000'), isNull);
      expect(acct.validate('12'), isNotNull); // too short
    });
  });

  test('ISO code is case-insensitive', () {
    expect(resolveBankScheme('in').countryIso, 'IN');
    expect(resolveBankScheme('us').currency, 'USD');
  });
}
