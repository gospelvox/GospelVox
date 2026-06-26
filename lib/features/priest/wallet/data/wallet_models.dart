// Data models for the priest wallet feature. Three concerns live
// here: a unified WalletTransaction (so earnings + withdrawals can
// render in a single chronological list), BankDetails (saved on the
// priest doc, used by the requestWithdrawal CF), and lightweight
// result/record types returned from the CF and the withdrawals
// collection respectively.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:gospel_vox/core/widgets/app_icons.dart';
import 'package:gospel_vox/features/priest/wallet/data/bank_account_scheme.dart';
import 'package:gospel_vox/features/priest/wallet/data/withdrawal_status.dart';

class WalletTransaction {
  final String id;
  // "session_charge", "session_earning", "bible_session_earning",
  // "activation_fee", "withdrawal", "refund". Anything we don't
  // recognise falls back to a generic receipt icon so future
  // server-side types don't crash the list. (The "__platform__"
  // commission rows are never queried by a priest/user, only summed
  // by the admin dashboard, so they never reach this model.)
  final String type;
  // Positive = priest earned, negative = priest paid out. The
  // transactions collection stores both shapes uniformly so we don't
  // need parallel earnings/withdrawals queries.
  final int coins;
  final String description;
  final String? sessionId;
  // For type == "withdrawal" rows: the id of the withdrawals/{id} doc
  // this debit belongs to. Lets the history row look up the payout's
  // live status (Processing / Sent / …) so it isn't shown as if the
  // money already left. Null on non-withdrawal rows / legacy data.
  final String? withdrawalId;
  final DateTime? createdAt;

  const WalletTransaction({
    required this.id,
    required this.type,
    required this.coins,
    required this.description,
    this.sessionId,
    this.withdrawalId,
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
      withdrawalId: data['withdrawalId'] as String?,
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
      case 'session_earning':
        return AppIcons.chatOutline;
      case 'bible_session_earning':
        return AppIcons.bible;
      case 'activation_fee':
        return AppIcons.badge;
      case 'withdrawal':
        return AppIcons.bank;
      case 'refund':
      case 'withdrawal_refund':
        return AppIcons.replay;
      default:
        return AppIcons.receipt;
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
  // Bank branch — auto-filled from the IFSC lookup, but the priest
  // can edit it before saving in case the directory's value is stale.
  // Optional on the model so existing priests (saved before this
  // field existed) still load cleanly; required by the form.
  final String branchName;
  // "savings"/"current" (India) or "checking"/"savings" (US). The
  // valid set is country-specific — see bank_account_scheme. Optional
  // on the model for backwards compatibility; required by the form on
  // new saves.
  final String accountType;
  final String? upiId;

  // ── Cross-border fields (withdrawal rebuild) ──
  // Country of the bank account (ISO alpha-2). Drives which of the
  // fields below are populated and how they're validated. Defaults to
  // 'IN' so every legacy record — saved before this field existed —
  // reads back as an India account, exactly as it always was.
  final String countryIso;
  // Payout currency for this account ('INR', 'USD', …). Display-only;
  // never used for conversion.
  final String currency;
  // Country-specific routing identifiers. Exactly one "family" is
  // filled per account: India uses ifscCode; US uses routingNumber;
  // UK uses sortCode; Europe/GCC use iban + swiftBic; other countries
  // use accountNumber + swiftBic. The unused ones stay ''.
  final String routingNumber;
  final String sortCode;
  final String iban;
  final String swiftBic;

  // ── Contact (mandatory on new saves; for the admin to reach the
  // priest about a payout). Stored as bankContactPhone/bankContactEmail
  // but fall back to the priest's registration phone/email on read so
  // legacy records show something. Deliberately NOT part of isComplete —
  // gating withdrawal eligibility on them would block existing priests
  // who never captured them; the FORM enforces them on new saves.
  // Phone is stored composed as "+<dial> <number>", e.g. "+91 98765…".
  final String phone;
  final String email;

  const BankDetails({
    required this.accountHolderName,
    required this.accountNumber,
    required this.ifscCode,
    required this.bankName,
    this.branchName = '',
    this.accountType = '',
    this.upiId,
    this.countryIso = 'IN',
    this.currency = '',
    this.routingNumber = '',
    this.sortCode = '',
    this.iban = '',
    this.swiftBic = '',
    this.phone = '',
    this.email = '',
  });

  factory BankDetails.fromFirestore(Map<String, dynamic> data) {
    return BankDetails(
      accountHolderName: data['bankAccountName'] as String? ?? '',
      accountNumber: data['bankAccountNumber'] as String? ?? '',
      ifscCode: data['bankIfscCode'] as String? ?? '',
      bankName: data['bankName'] as String? ?? '',
      branchName: data['bankBranchName'] as String? ?? '',
      accountType: data['bankAccountType'] as String? ?? '',
      upiId: data['upiId'] as String?,
      // Legacy records have no bankCountry — treat them as India, which
      // is what they always were, so isComplete keeps its old meaning.
      countryIso: (data['bankCountry'] as String?)?.trim().isNotEmpty == true
          ? (data['bankCountry'] as String)
          : 'IN',
      currency: data['bankCurrency'] as String? ?? '',
      routingNumber: data['bankRoutingNumber'] as String? ?? '',
      sortCode: data['bankSortCode'] as String? ?? '',
      iban: data['bankIban'] as String? ?? '',
      swiftBic: data['bankSwiftBic'] as String? ?? '',
      // Prefer the bank-contact fields; fall back to the priest's
      // registration phone/email so legacy records still surface a
      // contact for the admin.
      phone: _firstNonEmpty(
        data['bankContactPhone'] as String?,
        data['phone'] as String?,
      ),
      email: _firstNonEmpty(
        data['bankContactEmail'] as String?,
        data['email'] as String?,
      ),
    );
  }

  static String _firstNonEmpty(String? a, String? b) {
    if (a != null && a.trim().isNotEmpty) return a;
    if (b != null && b.trim().isNotEmpty) return b;
    return '';
  }

  // The CF writes the same field names; keeping the keys aligned
  // with priests/{uid} means saveBankDetails can write directly
  // without an adapter layer. branchName / accountType are written
  // unconditionally — an empty string is a valid "not set yet"
  // marker on legacy records that the form will force the priest
  // to fill in on next edit.
  Map<String, dynamic> toFirestore() => {
        'bankAccountName': accountHolderName,
        'bankAccountNumber': accountNumber,
        'bankIfscCode': ifscCode,
        'bankName': bankName,
        'bankBranchName': branchName,
        'bankAccountType': accountType,
        'upiId': upiId ?? '',
        // Cross-border fields. Written unconditionally (as '' when not
        // used by this country) so a record never carries a stale value
        // from a previous country selection.
        'bankCountry': countryIso,
        'bankCurrency': currency,
        'bankRoutingNumber': routingNumber,
        'bankSortCode': sortCode,
        'bankIban': iban,
        'bankSwiftBic': swiftBic,
        'bankContactPhone': phone,
        'bankContactEmail': email,
      };

  // Returns the stored value for a schema field key, so completeness
  // (and, later, the form) can address fields generically by key
  // instead of branching on country everywhere. Unknown keys → ''.
  String valueForKey(String key) {
    switch (key) {
      case 'bankAccountName':
        return accountHolderName;
      case 'bankAccountNumber':
        return accountNumber;
      case 'bankIfscCode':
        return ifscCode;
      case 'bankName':
        return bankName;
      case 'bankBranchName':
        return branchName;
      case 'bankAccountType':
        return accountType;
      case 'bankRoutingNumber':
        return routingNumber;
      case 'bankSortCode':
        return sortCode;
      case 'bankIban':
        return iban;
      case 'bankSwiftBic':
        return swiftBic;
      default:
        return '';
    }
  }

  // Withdrawal eligibility — the routing-critical fields for THIS
  // account's country must be present. We derive the required set from
  // the country scheme and check non-empty (not full validity — the
  // form enforces format at entry time; here we only gate the CTA on
  // "is the data there").
  //
  // Choice fields (account type) are intentionally skipped: requiring
  // them would flip legacy India priests — who never stored an account
  // type — to "needs bank details" and block their withdrawals. For
  // India this evaluates to exactly the old rule (holder + account +
  // IFSC + bank name), so existing behaviour is unchanged.
  bool get isComplete {
    for (final field in resolveBankScheme(countryIso).fields) {
      if (field.kind == BankFieldKind.choice) continue;
      // Branch name is collected by the form on new saves but is NOT a
      // routing-critical field — gating completeness on it would flip
      // legacy India priests (who never stored a branch) to "needs bank
      // details" and block their withdrawals. Skip it here, exactly as
      // we skip account type, so India keeps its old rule (holder +
      // account + IFSC + bank name).
      if (field.key == 'bankBranchName') continue;
      if (valueForKey(field.key).trim().isEmpty) return false;
    }
    return true;
  }
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

// One row in the priest's withdrawal history / status feed. Carries
// the full lifecycle so the status screen can draw the Requested →
// Processing → Sent timeline, surface the bank reference once paid,
// and show the reason + a fix prompt when a payout is put on hold.
class WithdrawalRecord {
  final String id;
  final int amount;
  final WithdrawalStatus status;
  // Payout currency captured at request time, for display ('INR',
  // 'USD', …). Empty on legacy records (assumed INR by the UI).
  final String currency;
  // Bank reference number (UTR, wire ref, …) the admin enters when
  // marking the payout sent. Null until then.
  final String? reference;
  // Bank transaction ID — a separate identifier some banks return
  // alongside the reference. Optional; null when not provided.
  final String? transactionId;
  // Why the payout was put on hold (e.g. "account number invalid").
  // Null unless status == onHold.
  final String? onHoldReason;

  // Per-stage timestamps. Each is set when the payout enters that
  // stage; null while it hasn't reached it.
  final DateTime? createdAt;
  final DateTime? processingAt;
  final DateTime? paidAt;
  final DateTime? blockedAt;
  final DateTime? onHoldAt;

  const WithdrawalRecord({
    required this.id,
    required this.amount,
    required this.status,
    this.currency = '',
    this.reference,
    this.transactionId,
    this.onHoldReason,
    this.createdAt,
    this.processingAt,
    this.paidAt,
    this.blockedAt,
    this.onHoldAt,
  });

  factory WithdrawalRecord.fromFirestore(
    String docId,
    Map<String, dynamic> data,
  ) {
    DateTime? ts(dynamic v) => v is Timestamp ? v.toDate() : null;
    String? nonEmpty(dynamic v) {
      final s = (v as String?)?.trim();
      return (s == null || s.isEmpty) ? null : s;
    }

    return WithdrawalRecord(
      id: docId,
      amount: (data['amount'] as num?)?.toInt() ?? 0,
      status: WithdrawalStatus.fromWire(data['status'] as String?),
      currency: data['currency'] as String? ?? '',
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

  // The timestamp that matches the CURRENT status — i.e. "when did it
  // become what it is now" — for the headline date on a status card.
  DateTime? get statusAt {
    switch (status) {
      case WithdrawalStatus.pending:
        return createdAt;
      case WithdrawalStatus.processing:
        return processingAt ?? createdAt;
      case WithdrawalStatus.paid:
        return paidAt;
      case WithdrawalStatus.onHold:
        return onHoldAt;
      case WithdrawalStatus.blocked:
        return blockedAt;
    }
  }
}
