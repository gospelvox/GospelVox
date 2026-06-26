// Verifies the CSV builders escape correctly, keep the amount in INR
// (never relabelled with the destination currency), and that the
// per-priest summary buckets amounts by status.
import 'package:flutter_test/flutter_test.dart';
import 'package:gospel_vox/features/admin/withdrawals/data/admin_withdrawal_model.dart';
import 'package:gospel_vox/features/admin/withdrawals/data/withdrawal_export.dart';

AdminWithdrawalModel mk(
  String id,
  String status,
  int amount, {
  String name = 'John',
  String currency = '',
}) =>
    AdminWithdrawalModel.fromFirestore(id, {
      'priestId': 'p1',
      'amount': amount,
      'status': status,
      'bankAccountName': name,
      'bankAccountNumber': '123456789012',
      'bankIfscCode': 'HDFC0001234',
      'bankName': 'HDFC Bank',
      'currency': currency,
    });

void main() {
  test('list CSV has a header + one row per withdrawal', () {
    final csv = buildWithdrawalsCsv([mk('w1', 'pending', 100)]);
    final lines = csv.trim().split('\n');
    expect(lines.length, 2); // header + 1
    expect(lines.first, contains('Amount (INR)'));
    expect(lines[1], contains('100'));
    expect(lines[1], contains('HDFC0001234'));
  });

  test('rows are grouped by country (so the sheet opens country-wise)', () {
    AdminWithdrawalModel row(String id, String country) =>
        AdminWithdrawalModel.fromFirestore(id, {
          'amount': 100,
          'status': 'pending',
          'bankAccountName': 'P-$id',
          'bankName': 'B',
          'bankCountry': country,
        });
    // Mixed order in → grouped by country out (CA, IN, US alphabetical).
    final csv = buildWithdrawalsCsv([
      row('a', 'US'),
      row('b', 'IN'),
      row('c', 'CA'),
      row('d', 'US'),
    ]);
    final lines = csv.trim().split('\n');
    final countryCol = lines.first.split(',').indexOf('"Country"');
    final order = lines
        .skip(1)
        .map((l) => l.split(',')[countryCol].replaceAll('"', ''))
        .toList();
    // All same-country rows are contiguous, alphabetical by country.
    expect(order, ['CA', 'IN', 'US', 'US']);
  });

  test('amount stays INR even for a foreign-currency account', () {
    final csv = buildWithdrawalsCsv([mk('w1', 'paid', 100, currency: 'USD')]);
    // The USD appears only in the Pay-to Currency column, never glued to
    // the amount as "USD 100".
    expect(csv, isNot(contains('USD 100')));
    expect(csv, contains('USD'));
    expect(csv, contains('100'));
  });

  test('receipt CSV is Field,Value and omits unused routing fields', () {
    final csv = buildReceiptCsv(mk('w1', 'paid', 250));
    expect(csv, contains('Field'));
    expect(csv, contains('Amount (INR)'));
    expect(csv, contains('250'));
    expect(csv, contains('IFSC'));
    // No routing/sort/IBAN for an India row.
    expect(csv, isNot(contains('Routing Number')));
    expect(csv, isNot(contains('Sort Code')));
  });

  test('transaction id flows into both list CSV and receipt', () {
    final w = AdminWithdrawalModel.fromFirestore('w9', {
      'amount': 100,
      'status': 'paid',
      'bankAccountName': 'John',
      'bankName': 'HDFC',
      'bankIfscCode': 'HDFC0001234',
      'paymentReference': 'UTR111',
      'transactionId': 'TXN999',
    });
    expect(w.reference, 'UTR111');
    expect(w.transactionId, 'TXN999');
    expect(buildWithdrawalsCsv([w]), contains('TXN999'));
    final receipt = buildReceiptCsv(w);
    expect(receipt, contains('Transaction ID'));
    expect(receipt, contains('TXN999'));
    expect(receipt, contains('Reference No.'));
  });

  test('CSV escaping doubles quotes in a value', () {
    final csv = buildReceiptCsv(mk('w1', 'paid', 100, name: 'O"Brien'));
    expect(csv, contains('O""Brien'));
  });

  test('summary buckets counts + amounts by status', () {
    final s = PriestWithdrawalSummary.from([
      mk('a', 'pending', 100),
      mk('b', 'pending', 100),
      mk('c', 'paid', 100),
      mk('d', 'blocked', 100),
    ]);
    expect(s.total, 4);
    expect(s.pending, 2);
    expect(s.paid, 1);
    expect(s.blocked, 1);
    expect(s.totalAmount, 400);
    expect(s.paidAmount, 100);
    expect(s.inFlightAmount, 200); // two pending
  });
}
