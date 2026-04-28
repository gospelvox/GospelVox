// Data models for the priest wallet feature. Three concerns live
// here: a unified WalletTransaction (so earnings + withdrawals can
// render in a single chronological list), BankDetails (saved on the
// priest doc, used by the requestWithdrawal CF), and lightweight
// result/record types returned from the CF and the withdrawals
// collection respectively.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

class WalletTransaction {
  final String id;
  // "session_charge", "activation_fee", "withdrawal", "refund".
  // Anything we don't recognise falls back to a generic receipt icon
  // so future server-side types don't crash the list.
  final String type;
  // Positive = priest earned, negative = priest paid out. The
  // transactions collection stores both shapes uniformly so we don't
  // need parallel earnings/withdrawals queries.
  final int coins;
  final String description;
  final String? sessionId;
  final DateTime? createdAt;

  const WalletTransaction({
    required this.id,
    required this.type,
    required this.coins,
    required this.description,
    this.sessionId,
    this.createdAt,
  });

  factory WalletTransaction.fromFirestore(
    String docId,
    Map<String, dynamic> data,
  ) {
    return WalletTransaction(
      id: docId,
      type: data['type'] as String? ?? '',
      coins: (data['coins'] as num?)?.toInt() ?? 0,
      description: data['description'] as String? ?? '',
      sessionId: data['sessionId'] as String?,
      createdAt: data['createdAt'] is Timestamp
          ? (data['createdAt'] as Timestamp).toDate()
          : null,
    );
  }

  bool get isEarning => coins > 0;
  bool get isDeduction => coins < 0;

  IconData get icon {
    switch (type) {
      case 'session_charge':
        return Icons.chat_bubble_outline_rounded;
      case 'activation_fee':
        return Icons.verified_outlined;
      case 'withdrawal':
        return Icons.account_balance_outlined;
      case 'refund':
        return Icons.replay_rounded;
      default:
        return Icons.receipt_outlined;
    }
  }

  // "Apr 27, 2:30 PM". Hand-rolled rather than via intl so the
  // format stays consistent with the rest of the app, which already
  // formats dates this way without a locale dependency.
  String get formattedDate {
    final d = createdAt;
    if (d == null) return '';
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    final hour = d.hour > 12 ? d.hour - 12 : (d.hour == 0 ? 12 : d.hour);
    final period = d.hour >= 12 ? 'PM' : 'AM';
    final minute = d.minute.toString().padLeft(2, '0');
    return '${months[d.month - 1]} ${d.day}, $hour:$minute $period';
  }
}

class BankDetails {
  final String accountHolderName;
  final String accountNumber;
  final String ifscCode;
  final String bankName;
  final String? upiId;

  const BankDetails({
    required this.accountHolderName,
    required this.accountNumber,
    required this.ifscCode,
    required this.bankName,
    this.upiId,
  });

  factory BankDetails.fromFirestore(Map<String, dynamic> data) {
    return BankDetails(
      accountHolderName: data['bankAccountName'] as String? ?? '',
      accountNumber: data['bankAccountNumber'] as String? ?? '',
      ifscCode: data['bankIfscCode'] as String? ?? '',
      bankName: data['bankName'] as String? ?? '',
      upiId: data['upiId'] as String?,
    );
  }

  // The CF writes the same field names; keeping the keys aligned
  // with priests/{uid} means saveBankDetails can write directly
  // without an adapter layer.
  Map<String, dynamic> toFirestore() => {
        'bankAccountName': accountHolderName,
        'bankAccountNumber': accountNumber,
        'bankIfscCode': ifscCode,
        'bankName': bankName,
        'upiId': upiId ?? '',
      };

  bool get isComplete =>
      accountHolderName.isNotEmpty &&
      accountNumber.isNotEmpty &&
      ifscCode.isNotEmpty &&
      bankName.isNotEmpty;
}

class WithdrawalResult {
  final String withdrawalId;
  final double newBalance;
  final int amount;
  // True when the CF returned an existing record because it
  // recognised the clientRequestId. The page treats this exactly
  // like a fresh success — the priest's UX is identical — but
  // logging callers can use the flag to spot retries.
  final bool deduplicated;

  const WithdrawalResult({
    required this.withdrawalId,
    required this.newBalance,
    required this.amount,
    this.deduplicated = false,
  });
}

// Live snapshot of the priest doc fields the wallet page cares
// about. Driven by a single Firestore listener so balance, totals,
// and bank details all update together — avoids the "balance
// changed but totalWithdrawn is stale" intermediate state we'd
// hit if these came from separate streams.
class PriestWalletSummary {
  final double balance;
  final double totalEarnings;
  final double totalWithdrawn;
  final BankDetails? bankDetails;

  const PriestWalletSummary({
    required this.balance,
    required this.totalEarnings,
    required this.totalWithdrawn,
    required this.bankDetails,
  });

  factory PriestWalletSummary.fromFirestore(Map<String, dynamic> data) {
    final holder = (data['bankAccountName'] as String?) ?? '';
    return PriestWalletSummary(
      balance: (data['walletBalance'] as num?)?.toDouble() ?? 0,
      totalEarnings: (data['totalEarnings'] as num?)?.toDouble() ?? 0,
      totalWithdrawn: (data['totalWithdrawn'] as num?)?.toDouble() ?? 0,
      bankDetails: holder.isEmpty ? null : BankDetails.fromFirestore(data),
    );
  }
}

// Typed exception for withdrawal failures. The repository converts
// FirebaseFunctionsException into one of these so the page can
// switch on `reason` (a stable token from the CF) instead of doing
// fragile substring matches against human-readable messages.
//
// Reason values mirror the CF — keep them in sync:
//   • invalid_amount, invalid_request_id
//   • request_id_conflict
//   • priest_not_found, account_inactive
//   • no_bank_details
//   • below_minimum (with optional minAmount in details)
//   • insufficient_balance
//   • unknown — fallback for unrecognised codes
class WithdrawalException implements Exception {
  final String reason;
  final String message;
  final Map<String, dynamic> details;

  const WithdrawalException({
    required this.reason,
    required this.message,
    this.details = const {},
  });

  @override
  String toString() => 'WithdrawalException($reason): $message';
}

class WithdrawalRecord {
  final String id;
  final int amount;
  // "completed" or "blocked" — admin can flip to blocked for fraud,
  // but withdrawals are otherwise auto-processed.
  final String status;
  final DateTime? createdAt;

  const WithdrawalRecord({
    required this.id,
    required this.amount,
    required this.status,
    this.createdAt,
  });

  factory WithdrawalRecord.fromFirestore(
    String docId,
    Map<String, dynamic> data,
  ) {
    return WithdrawalRecord(
      id: docId,
      amount: (data['amount'] as num?)?.toInt() ?? 0,
      status: data['status'] as String? ?? 'completed',
      createdAt: data['createdAt'] is Timestamp
          ? (data['createdAt'] as Timestamp).toDate()
          : null,
    );
  }
}
