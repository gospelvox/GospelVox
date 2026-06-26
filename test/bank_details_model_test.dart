// Guards the country-aware BankDetails model. The most important case
// is legacy compatibility: a record saved before cross-border existed
// (no `bankCountry`) must read back as India and keep the EXACT old
// completeness rule, so no existing approved priest is ever flipped to
// "needs bank details" by this change.
import 'package:flutter_test/flutter_test.dart';
import 'package:gospel_vox/features/priest/wallet/data/wallet_models.dart';

void main() {
  group('legacy India record (no bankCountry)', () {
    final legacy = BankDetails.fromFirestore(const {
      'bankAccountName': 'John Mathew',
      'bankAccountNumber': '123456789012',
      'bankIfscCode': 'SBIN0001234',
      'bankName': 'State Bank of India',
      // note: no bankCountry, no bankAccountType — like an old record
    });

    test('defaults to India', () {
      expect(legacy.countryIso, 'IN');
    });
    test('is complete on holder+account+ifsc+bank (account type NOT required)',
        () {
      expect(legacy.isComplete, isTrue);
    });
    test('becomes incomplete if a routing-critical field is missing', () {
      final noIfsc = BankDetails.fromFirestore(const {
        'bankAccountName': 'John Mathew',
        'bankAccountNumber': '123456789012',
        'bankName': 'State Bank of India',
      });
      expect(noIfsc.isComplete, isFalse);
    });
  });

  group('USA record', () {
    final us = BankDetails.fromFirestore(const {
      'bankAccountName': 'Mary Smith',
      'bankAccountNumber': '1234567',
      'bankRoutingNumber': '021000021',
      'bankName': 'Chase',
      'bankCountry': 'US',
      'bankCurrency': 'USD',
    });
    test('complete with routing present, no IFSC needed', () {
      expect(us.countryIso, 'US');
      expect(us.isComplete, isTrue);
    });
    test('incomplete without routing number', () {
      final noRouting = BankDetails.fromFirestore(const {
        'bankAccountName': 'Mary Smith',
        'bankAccountNumber': '1234567',
        'bankName': 'Chase',
        'bankCountry': 'US',
      });
      expect(noRouting.isComplete, isFalse);
    });
  });

  group('GCC / IBAN record', () {
    test('complete with IBAN + SWIFT, incomplete if SWIFT missing', () {
      final ae = BankDetails.fromFirestore(const {
        'bankAccountName': 'Ahmed Khan',
        'bankIban': 'GB82WEST12345698765432',
        'bankSwiftBic': 'HDFCINBB',
        'bankName': 'Emirates NBD',
        'bankCountry': 'AE',
      });
      expect(ae.isComplete, isTrue);

      final noSwift = BankDetails.fromFirestore(const {
        'bankAccountName': 'Ahmed Khan',
        'bankIban': 'GB82WEST12345698765432',
        'bankName': 'Emirates NBD',
        'bankCountry': 'AE',
      });
      expect(noSwift.isComplete, isFalse);
    });
  });

  group('Firestore round-trip', () {
    test('toFirestore -> fromFirestore preserves all fields', () {
      const original = BankDetails(
        accountHolderName: 'Mary Smith',
        accountNumber: '1234567',
        ifscCode: '',
        bankName: 'Chase',
        accountType: 'checking',
        countryIso: 'US',
        currency: 'USD',
        routingNumber: '021000021',
      );
      final restored = BankDetails.fromFirestore(original.toFirestore());
      expect(restored.countryIso, 'US');
      expect(restored.currency, 'USD');
      expect(restored.routingNumber, '021000021');
      expect(restored.accountHolderName, 'Mary Smith');
      expect(restored.accountType, 'checking');
      expect(restored.isComplete, isTrue);
    });

    test('writes the cross-border keys', () {
      const d = BankDetails(
        accountHolderName: 'A',
        accountNumber: '',
        ifscCode: '',
        bankName: 'B',
        countryIso: 'AE',
        currency: 'AED',
        iban: 'GB82WEST12345698765432',
        swiftBic: 'HDFCINBB',
      );
      final map = d.toFirestore();
      expect(map['bankCountry'], 'AE');
      expect(map['bankCurrency'], 'AED');
      expect(map['bankIban'], 'GB82WEST12345698765432');
      expect(map['bankSwiftBic'], 'HDFCINBB');
    });
  });

  group('contact (phone + email)', () {
    test('reads bank-contact fields when present', () {
      final d = BankDetails.fromFirestore(const {
        'bankAccountName': 'John',
        'bankContactPhone': '+91 9876543210',
        'bankContactEmail': 'john@mail.com',
        'phone': '+91 0000000000',
        'email': 'old@mail.com',
      });
      expect(d.phone, '+91 9876543210');
      expect(d.email, 'john@mail.com');
    });

    test('falls back to registration phone/email when bank-contact empty',
        () {
      final d = BankDetails.fromFirestore(const {
        'bankAccountName': 'John',
        'phone': '+91 9876543210',
        'email': 'john@mail.com',
      });
      expect(d.phone, '+91 9876543210');
      expect(d.email, 'john@mail.com');
    });

    test('round-trips through toFirestore', () {
      const d = BankDetails(
        accountHolderName: 'John',
        accountNumber: '1',
        ifscCode: 'SBIN0001234',
        bankName: 'SBI',
        phone: '+91 9876543210',
        email: 'john@mail.com',
      );
      final r = BankDetails.fromFirestore(d.toFirestore());
      expect(r.phone, '+91 9876543210');
      expect(r.email, 'john@mail.com');
    });

    test('contact is NOT required for isComplete (legacy safety)', () {
      // India record complete on bank fields but no phone/email must
      // still be withdrawal-eligible.
      final d = BankDetails.fromFirestore(const {
        'bankAccountName': 'John',
        'bankAccountNumber': '123456789012',
        'bankIfscCode': 'SBIN0001234',
        'bankName': 'SBI',
      });
      expect(d.phone, '');
      expect(d.isComplete, isTrue);
    });
  });

  test('valueForKey maps schema keys to stored values', () {
    const d = BankDetails(
      accountHolderName: 'John',
      accountNumber: '111',
      ifscCode: 'SBIN0001234',
      bankName: 'SBI',
      routingNumber: '021000021',
    );
    expect(d.valueForKey('bankAccountName'), 'John');
    expect(d.valueForKey('bankIfscCode'), 'SBIN0001234');
    expect(d.valueForKey('bankRoutingNumber'), '021000021');
    expect(d.valueForKey('nonexistent'), '');
  });
}
