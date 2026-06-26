// Shape of a withdrawals/{id} doc as the admin payout dashboard
// surfaces it. Field names mirror the requestWithdrawal CF
// (bankAccountName, bankAccountNumber, bankIfscCode, …) so that
// when the admin needs to cross-reference a payout against the
// priest's saved bank details the names line up exactly.

import 'package:cloud_firestore/cloud_firestore.dart';

import 'package:gospel_vox/features/priest/wallet/data/withdrawal_status.dart';

class AdminWithdrawalModel {
  final String id;
  final String priestId;
  final int amount;
  // Raw wire status: 'pending' | 'processing' | 'paid' | 'on_hold' |
  // 'blocked'. Kept as a String for backward compatibility with the
  // existing page; `statusEnum` is the typed view.
  final String status;
  final String bankAccountName;
  final String bankAccountNumber;
  final String bankIfscCode;
  final String bankName;
  // "savings"/"current" (India) or "checking"/"savings" (US) — needed
  // for ACH-style payouts.
  final String accountType;
  final String? upiId;
  // ── Cross-border + lifecycle fields (withdrawal rebuild) ──
  // Destination country (ISO) + payout currency, snapshotted onto the
  // withdrawal at request time. Empty on legacy India rows.
  final String countryIso;
  final String currency;
  // Country-specific routing identifiers (one family populated per row,
  // mirroring BankDetails). The admin needs whichever applies to build
  // the bank's payout sheet.
  final String routingNumber;
  final String sortCode;
  final String iban;
  final String swiftBic;
  // Contact captured with the bank details so the admin can reach the
  // priest about a payout. Phone is stored composed ("+91 98765…").
  final String phone;
  final String email;
  // Bank reference number + (optional) transaction ID the admin records
  // when marking the payout sent; the reason captured on hold.
  final String? reference;
  final String? transactionId;
  final String? onHoldReason;
  final DateTime? createdAt;
  final DateTime? processingAt;
  final DateTime? paidAt;
  final DateTime? blockedAt;
  final DateTime? onHoldAt;

  const AdminWithdrawalModel({
    required this.id,
    required this.priestId,
    required this.amount,
    required this.status,
    required this.bankAccountName,
    required this.bankAccountNumber,
    required this.bankIfscCode,
    required this.bankName,
    this.accountType = '',
    this.upiId,
    this.countryIso = '',
    this.currency = '',
    this.routingNumber = '',
    this.sortCode = '',
    this.iban = '',
    this.swiftBic = '',
    this.phone = '',
    this.email = '',
    this.reference,
    this.transactionId,
    this.onHoldReason,
    this.createdAt,
    this.processingAt,
    this.paidAt,
    this.blockedAt,
    this.onHoldAt,
  });

  factory AdminWithdrawalModel.fromFirestore(
    String docId,
    Map<String, dynamic> data,
  ) {
    DateTime? ts(dynamic v) => v is Timestamp ? v.toDate() : null;
    String? nonEmpty(dynamic v) {
      final s = (v as String?)?.trim();
      return (s == null || s.isEmpty) ? null : s;
    }

    return AdminWithdrawalModel(
      id: docId,
      priestId: data['priestId'] as String? ?? '',
      amount: (data['amount'] as num?)?.toInt() ?? 0,
      status: data['status'] as String? ?? 'pending',
      bankAccountName: data['bankAccountName'] as String? ?? '',
      bankAccountNumber: data['bankAccountNumber'] as String? ?? '',
      bankIfscCode: data['bankIfscCode'] as String? ?? '',
      bankName: data['bankName'] as String? ?? '',
      accountType: data['bankAccountType'] as String? ?? '',
      upiId: data['upiId'] as String?,
      countryIso: data['bankCountry'] as String? ?? '',
      currency: data['currency'] as String? ??
          (data['bankCurrency'] as String? ?? ''),
      routingNumber: data['bankRoutingNumber'] as String? ?? '',
      sortCode: data['bankSortCode'] as String? ?? '',
      iban: data['bankIban'] as String? ?? '',
      swiftBic: data['bankSwiftBic'] as String? ?? '',
      phone: (data['bankContactPhone'] as String?)?.trim().isNotEmpty == true
          ? data['bankContactPhone'] as String
          : (data['phone'] as String? ?? ''),
      email: (data['bankContactEmail'] as String?)?.trim().isNotEmpty == true
          ? data['bankContactEmail'] as String
          : (data['email'] as String? ?? ''),
      reference: nonEmpty(data['paymentReference']),
      transactionId: nonEmpty(data['transactionId']),
      onHoldReason: nonEmpty(data['onHoldReason']),
      createdAt: ts(data['createdAt']),
      processingAt: ts(data['processingAt']),
      paidAt: ts(data['paidAt']),
      blockedAt: ts(data['blockedAt']),
      onHoldAt: ts(data['onHoldAt']),
    );
  }

  // Typed view of the status — the shared lifecycle enum.
  WithdrawalStatus get statusEnum => WithdrawalStatus.fromWire(status);

  // The account identifier the admin actually pays into: the IBAN for
  // IBAN countries, otherwise the plain account number.
  String get primaryAccountIdentifier =>
      iban.isNotEmpty ? iban : bankAccountNumber;

  // Last four of the primary identifier for the masked display —
  // gracefully degrades when shorter than four chars so the UI never
  // throws RangeError.
  String get lastFourAccount {
    final id = primaryAccountIdentifier.replaceAll(RegExp(r'\s'), '');
    if (id.length < 4) return id;
    return id.substring(id.length - 4);
  }

  bool get isPending => status == 'pending';
  bool get isProcessing => status == 'processing';
  bool get isPaid => status == 'paid';
  bool get isOnHold => status == 'on_hold';
  bool get isBlocked => status == 'blocked';

  String _fmt(DateTime? d) {
    if (d == null) return '';
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    final hour =
        d.hour > 12 ? d.hour - 12 : (d.hour == 0 ? 12 : d.hour);
    final period = d.hour >= 12 ? 'PM' : 'AM';
    final minute = d.minute.toString().padLeft(2, '0');
    return '${months[d.month - 1]} ${d.day}, $hour:$minute $period';
  }

  String get formattedCreatedAt => _fmt(createdAt);
  String get formattedProcessingAt => _fmt(processingAt);
  String get formattedPaidAt => _fmt(paidAt);
  String get formattedBlockedAt => _fmt(blockedAt);
  String get formattedOnHoldAt => _fmt(onHoldAt);
}
