// Guards the admin withdrawal model's parsing of the lifecycle +
// cross-border fields, including the masked-identifier logic that has
// to work for IBAN countries (no plain account number) as well as
// legacy India rows.
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gospel_vox/features/admin/withdrawals/data/admin_withdrawal_model.dart';
import 'package:gospel_vox/features/priest/wallet/data/withdrawal_status.dart';

void main() {
  test('legacy India row still parses (status string + last4)', () {
    final w = AdminWithdrawalModel.fromFirestore('w1', {
      'priestId': 'p1',
      'amount': 1000,
      'status': 'pending',
      'bankAccountName': 'John',
      'bankAccountNumber': '123456789012',
      'bankIfscCode': 'SBIN0001234',
      'bankName': 'SBI',
    });
    expect(w.statusEnum, WithdrawalStatus.pending);
    expect(w.isPending, isTrue);
    expect(w.lastFourAccount, '9012');
    expect(w.primaryAccountIdentifier, '123456789012');
  });

  test('new statuses map through the enum', () {
    AdminWithdrawalModel s(String status) =>
        AdminWithdrawalModel.fromFirestore('x', {
          'amount': 1,
          'status': status,
          'bankAccountName': 'a',
          'bankAccountNumber': '1',
          'bankIfscCode': 'i',
          'bankName': 'b',
        });
    expect(s('processing').isProcessing, isTrue);
    expect(s('processing').statusEnum, WithdrawalStatus.processing);
    expect(s('on_hold').isOnHold, isTrue);
    expect(s('on_hold').statusEnum, WithdrawalStatus.onHold);
  });

  test('IBAN row uses IBAN as the primary identifier + last4', () {
    final w = AdminWithdrawalModel.fromFirestore('w2', {
      'amount': 5000,
      'status': 'pending',
      'bankAccountName': 'Ahmed',
      'bankName': 'Emirates NBD',
      'bankCountry': 'AE',
      'currency': 'AED',
      'bankIban': 'GB82 WEST 1234 5698 7654 32',
      'bankSwiftBic': 'HDFCINBB',
    });
    expect(w.countryIso, 'AE');
    expect(w.currency, 'AED');
    expect(w.iban, 'GB82 WEST 1234 5698 7654 32');
    expect(w.primaryAccountIdentifier, 'GB82 WEST 1234 5698 7654 32');
    // spaces stripped before taking last four
    expect(w.lastFourAccount, '5432');
  });

  test('reference + on-hold reason parse, blanks normalise to null', () {
    final paid = AdminWithdrawalModel.fromFirestore('w3', {
      'amount': 1,
      'status': 'paid',
      'bankAccountName': 'a',
      'bankAccountNumber': '1',
      'bankIfscCode': 'i',
      'bankName': 'b',
      'paymentReference': 'UTR123456',
      'paidAt': Timestamp.fromMillisecondsSinceEpoch(5000),
    });
    expect(paid.reference, 'UTR123456');
    expect(paid.formattedPaidAt, isNotEmpty);

    final blankRef = AdminWithdrawalModel.fromFirestore('w4', {
      'amount': 1,
      'status': 'pending',
      'bankAccountName': 'a',
      'bankAccountNumber': '1',
      'bankIfscCode': 'i',
      'bankName': 'b',
      'paymentReference': '  ',
      'onHoldReason': '',
    });
    expect(blankRef.reference, isNull);
    expect(blankRef.onHoldReason, isNull);
  });

  test('currency falls back from bankCurrency when currency absent', () {
    final w = AdminWithdrawalModel.fromFirestore('w5', {
      'amount': 1,
      'status': 'pending',
      'bankAccountName': 'a',
      'bankAccountNumber': '1',
      'bankIfscCode': 'i',
      'bankName': 'b',
      'bankCurrency': 'USD',
    });
    expect(w.currency, 'USD');
  });
}
