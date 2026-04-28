// Shape of a withdrawals/{id} doc as the admin payout dashboard
// surfaces it. Field names mirror the requestWithdrawal CF
// (bankAccountName, bankAccountNumber, bankIfscCode, …) so that
// when the admin needs to cross-reference a payout against the
// priest's saved bank details the names line up exactly.

import 'package:cloud_firestore/cloud_firestore.dart';

class AdminWithdrawalModel {
  final String id;
  final String priestId;
  final int amount;
  // 'pending' | 'paid' | 'blocked'
  final String status;
  final String bankAccountName;
  final String bankAccountNumber;
  final String bankIfscCode;
  final String bankName;
  final String? upiId;
  final DateTime? createdAt;
  final DateTime? paidAt;
  final DateTime? blockedAt;

  const AdminWithdrawalModel({
    required this.id,
    required this.priestId,
    required this.amount,
    required this.status,
    required this.bankAccountName,
    required this.bankAccountNumber,
    required this.bankIfscCode,
    required this.bankName,
    this.upiId,
    this.createdAt,
    this.paidAt,
    this.blockedAt,
  });

  factory AdminWithdrawalModel.fromFirestore(
    String docId,
    Map<String, dynamic> data,
  ) {
    DateTime? ts(dynamic v) =>
        v is Timestamp ? v.toDate() : null;

    return AdminWithdrawalModel(
      id: docId,
      priestId: data['priestId'] as String? ?? '',
      amount: (data['amount'] as num?)?.toInt() ?? 0,
      status: data['status'] as String? ?? 'pending',
      bankAccountName: data['bankAccountName'] as String? ?? '',
      bankAccountNumber: data['bankAccountNumber'] as String? ?? '',
      bankIfscCode: data['bankIfscCode'] as String? ?? '',
      bankName: data['bankName'] as String? ?? '',
      upiId: data['upiId'] as String?,
      createdAt: ts(data['createdAt']),
      paidAt: ts(data['paidAt']),
      blockedAt: ts(data['blockedAt']),
    );
  }

  // Last four digits for display in the masked account string —
  // gracefully degrades when the number is shorter than four chars
  // (e.g. older test data) so the UI never throws RangeError.
  String get lastFourAccount {
    if (bankAccountNumber.length < 4) return bankAccountNumber;
    return bankAccountNumber.substring(bankAccountNumber.length - 4);
  }

  bool get isPending => status == 'pending';
  bool get isPaid => status == 'paid';
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
  String get formattedPaidAt => _fmt(paidAt);
  String get formattedBlockedAt => _fmt(blockedAt);
}
