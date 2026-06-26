// CSV builders for the admin withdrawal exports. Pure string builders
// (no Flutter / no share_plus) so they're trivially testable and shared
// by the list export, the per-priest export, and the single-withdrawal
// receipt. The amount is ALWAYS in ₹ (the platform currency); the
// destination "Pay-to Currency" is a separate column the admin converts
// from — never a relabel of the amount.

import 'package:gospel_vox/features/admin/withdrawals/data/admin_withdrawal_model.dart';

// Quote every cell and double internal quotes — the safe, universal CSV
// escaping that survives commas, quotes and newlines in any field.
String _cell(String value) => '"${value.replaceAll('"', '""')}"';

String _statusLabel(AdminWithdrawalModel w) => w.statusEnum.label;

// Multi-row spreadsheet for the bank / records. One row per withdrawal,
// every routing field present (blank where the country doesn't use it).
String buildWithdrawalsCsv(List<AdminWithdrawalModel> rows) {
  const headers = [
    'Status',
    'Request ID',
    'Priest Name',
    'Country',
    'Pay-to Currency',
    'Amount (INR)',
    'Bank Name',
    'Account Type',
    'Account Number',
    'IBAN',
    'IFSC',
    'Routing Number',
    'Sort Code',
    'SWIFT/BIC',
    'UPI',
    'Phone',
    'Email',
    'Reference No.',
    'Transaction ID',
    'On-hold Reason',
    'Requested At',
    'Processing At',
    'Sent At',
    'Cancelled At',
  ];
  // Group the rows by country so the sheet opens already organised
  // country-wise (India block, then USA, then Canada, …) — the admin
  // processes each country's batch together (India = domestic transfer,
  // others = international wire). Newest-first within each country.
  // Excel's own Sort/Filter on the Country column still works on top.
  final sorted = [...rows]..sort((a, b) {
    final ca = a.countryIso.isEmpty ? 'IN' : a.countryIso;
    final cb = b.countryIso.isEmpty ? 'IN' : b.countryIso;
    final byCountry = ca.compareTo(cb);
    if (byCountry != 0) return byCountry;
    final at = a.createdAt;
    final bt = b.createdAt;
    if (at == null && bt == null) return 0;
    if (at == null) return 1;
    if (bt == null) return -1;
    return bt.compareTo(at);
  });

  final buf = StringBuffer()..writeln(headers.map(_cell).join(','));
  for (final w in sorted) {
    buf.writeln([
      _statusLabel(w),
      w.id,
      w.bankAccountName,
      w.countryIso.isEmpty ? 'IN' : w.countryIso,
      w.currency,
      w.amount.toString(),
      w.bankName,
      w.accountType,
      w.bankAccountNumber,
      w.iban,
      w.bankIfscCode,
      w.routingNumber,
      w.sortCode,
      w.swiftBic,
      w.upiId ?? '',
      w.phone,
      w.email,
      w.reference ?? '',
      w.transactionId ?? '',
      w.onHoldReason ?? '',
      w.formattedCreatedAt,
      w.formattedProcessingAt,
      w.formattedPaidAt,
      w.formattedBlockedAt,
    ].map(_cell).join(','));
  }
  return buf.toString();
}

// Single-withdrawal "receipt" as a two-column Field,Value CSV — opens
// cleanly in Excel and reads top-to-bottom like a receipt. Only the
// routing fields this account actually uses are included.
String buildReceiptCsv(AdminWithdrawalModel w) {
  final rows = <(String, String)>[
    ('Receipt', 'Withdrawal payout'),
    ('Status', _statusLabel(w)),
    ('Request ID', w.id),
    ('Priest Name', w.bankAccountName),
    ('Country', w.countryIso.isEmpty ? 'IN' : w.countryIso),
    ('Pay-to Currency', w.currency.isEmpty ? 'INR' : w.currency),
    ('Amount (INR)', w.amount.toString()),
    ('Bank Name', w.bankName),
    if (w.accountType.isNotEmpty) ('Account Type', w.accountType),
    if (w.bankAccountNumber.isNotEmpty)
      ('Account Number', w.bankAccountNumber),
    if (w.iban.isNotEmpty) ('IBAN', w.iban),
    if (w.bankIfscCode.isNotEmpty) ('IFSC', w.bankIfscCode),
    if (w.routingNumber.isNotEmpty) ('Routing Number', w.routingNumber),
    if (w.sortCode.isNotEmpty) ('Sort Code', w.sortCode),
    if (w.swiftBic.isNotEmpty) ('SWIFT/BIC', w.swiftBic),
    if ((w.upiId ?? '').isNotEmpty) ('UPI', w.upiId!),
    if (w.phone.isNotEmpty) ('Phone', w.phone),
    if (w.email.isNotEmpty) ('Email', w.email),
    if (w.reference != null) ('Reference No.', w.reference!),
    if (w.transactionId != null) ('Transaction ID', w.transactionId!),
    if (w.onHoldReason != null) ('On-hold Reason', w.onHoldReason!),
    if (w.formattedCreatedAt.isNotEmpty)
      ('Requested At', w.formattedCreatedAt),
    if (w.formattedProcessingAt.isNotEmpty)
      ('Processing At', w.formattedProcessingAt),
    if (w.formattedPaidAt.isNotEmpty) ('Sent At', w.formattedPaidAt),
    if (w.formattedBlockedAt.isNotEmpty)
      ('Cancelled At', w.formattedBlockedAt),
  ];
  final buf = StringBuffer()..writeln('${_cell('Field')},${_cell('Value')}');
  for (final r in rows) {
    buf.writeln('${_cell(r.$1)},${_cell(r.$2)}');
  }
  return buf.toString();
}

// Summary of a priest's withdrawals for the per-priest view header.
class PriestWithdrawalSummary {
  final int total;
  final int pending;
  final int processing;
  final int paid;
  final int onHold;
  final int blocked;
  // Sum of amounts (₹) by bucket.
  final int totalAmount;
  final int paidAmount;
  final int inFlightAmount; // pending + processing + on_hold

  const PriestWithdrawalSummary({
    required this.total,
    required this.pending,
    required this.processing,
    required this.paid,
    required this.onHold,
    required this.blocked,
    required this.totalAmount,
    required this.paidAmount,
    required this.inFlightAmount,
  });

  factory PriestWithdrawalSummary.from(List<AdminWithdrawalModel> rows) {
    var pending = 0, processing = 0, paid = 0, onHold = 0, blocked = 0;
    var totalAmount = 0, paidAmount = 0, inFlightAmount = 0;
    for (final w in rows) {
      totalAmount += w.amount;
      if (w.isPending) {
        pending++;
        inFlightAmount += w.amount;
      } else if (w.isProcessing) {
        processing++;
        inFlightAmount += w.amount;
      } else if (w.isPaid) {
        paid++;
        paidAmount += w.amount;
      } else if (w.isOnHold) {
        onHold++;
        inFlightAmount += w.amount;
      } else if (w.isBlocked) {
        blocked++;
      }
    }
    return PriestWithdrawalSummary(
      total: rows.length,
      pending: pending,
      processing: processing,
      paid: paid,
      onHold: onHold,
      blocked: blocked,
      totalAmount: totalAmount,
      paidAmount: paidAmount,
      inFlightAmount: inFlightAmount,
    );
  }
}
