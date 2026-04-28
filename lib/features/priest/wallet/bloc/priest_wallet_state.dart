// State machine for the priest wallet page. Sealed so the page can
// switch over the four cases exhaustively without a default branch.

import 'package:gospel_vox/features/priest/wallet/data/wallet_models.dart';

sealed class PriestWalletState {
  const PriestWalletState();
}

class PriestWalletInitial extends PriestWalletState {
  const PriestWalletInitial();
}

class PriestWalletLoading extends PriestWalletState {
  const PriestWalletLoading();
}

class PriestWalletLoaded extends PriestWalletState {
  final double balance;
  // Lifetime earnings, sourced from priests/{uid}.totalEarnings.
  // Maintained by the session-settlement CF, NOT computed locally,
  // so the value stays correct past the 50-record transaction
  // window we render on the page.
  final double totalEarnings;
  // Lifetime withdrawn, sourced from priests/{uid}.totalWithdrawn.
  // Incremented inside requestWithdrawal's atomic batch.
  final double totalWithdrawn;
  final List<WalletTransaction> transactions;
  // Null when the priest hasn't saved bank details yet — the page
  // branches on `needsBankDetails` rather than a separate boolean
  // field so a partially-saved record (missing IFSC, etc.) still
  // routes to the "Add Bank Details" CTA.
  final BankDetails? bankDetails;
  final int minWithdrawalAmount;
  // True between the user tapping the second-confirmation "Yes,
  // Withdraw" button and the CF returning. We use it to block re-
  // entry rather than relying on Navigator state, since the sheet
  // pops before the future settles.
  final bool isWithdrawing;

  const PriestWalletLoaded({
    required this.balance,
    required this.totalEarnings,
    required this.totalWithdrawn,
    required this.transactions,
    required this.bankDetails,
    required this.minWithdrawalAmount,
    this.isWithdrawing = false,
  });

  bool get canWithdraw =>
      balance >= minWithdrawalAmount &&
      bankDetails != null &&
      bankDetails!.isComplete;

  bool get needsBankDetails =>
      bankDetails == null || !bankDetails!.isComplete;

  // Whole-rupee display — coins are always whole numbers in this
  // economy (1 coin = ₹1), and showing decimals would imply a
  // precision the system doesn't carry.
  String get formattedBalance => '₹${balance.toStringAsFixed(0)}';

  PriestWalletLoaded copyWith({
    double? balance,
    double? totalEarnings,
    double? totalWithdrawn,
    List<WalletTransaction>? transactions,
    // copyWith for nullable fields uses a flag because a literal
    // `null` from the caller means "set to null", not "leave alone".
    bool overwriteBankDetails = false,
    BankDetails? bankDetails,
    int? minWithdrawalAmount,
    bool? isWithdrawing,
  }) {
    return PriestWalletLoaded(
      balance: balance ?? this.balance,
      totalEarnings: totalEarnings ?? this.totalEarnings,
      totalWithdrawn: totalWithdrawn ?? this.totalWithdrawn,
      transactions: transactions ?? this.transactions,
      bankDetails: overwriteBankDetails
          ? bankDetails
          : (bankDetails ?? this.bankDetails),
      minWithdrawalAmount: minWithdrawalAmount ?? this.minWithdrawalAmount,
      isWithdrawing: isWithdrawing ?? this.isWithdrawing,
    );
  }
}

class PriestWalletError extends PriestWalletState {
  final String message;
  const PriestWalletError(this.message);
}
