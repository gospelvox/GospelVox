// Priest wallet — hero balance card, quick stats, transaction
// history, and the withdrawal flow.
//
// Composition:
//   • PriestWalletPage — the route widget. Streams the cubit and
//     swaps body content based on state.
//   • _WithdrawalSheet — modal bottom sheet for entering amount.
//     Lives in this file because it shares cubit state with the
//     page and isn't reused elsewhere.
//   • _SuccessSheet — confirmation after the CF returns.
//   • Visual leaves (_QuickStat, _TransactionCard, _EmptyTransactions,
//     _Shimmer*, _PressableScale) — local because they're tightly
//     coupled to this page's brand language.

import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shimmer/shimmer.dart';

import 'package:gospel_vox/core/theme/app_colors.dart';
import 'package:gospel_vox/core/widgets/app_snackbar.dart';
import 'package:gospel_vox/features/priest/wallet/bloc/priest_wallet_cubit.dart';
import 'package:gospel_vox/features/priest/wallet/bloc/priest_wallet_state.dart';
import 'package:gospel_vox/features/priest/wallet/data/wallet_models.dart';

const Color _kSuccessGreen = Color(0xFF2E7D4F);

class PriestWalletPage extends StatefulWidget {
  const PriestWalletPage({super.key});

  @override
  State<PriestWalletPage> createState() => _PriestWalletPageState();
}

class _PriestWalletPageState extends State<PriestWalletPage> {
  String? _uid;

  @override
  void initState() {
    super.initState();
    _uid = FirebaseAuth.instance.currentUser?.uid;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: _buildAppBar(),
      body: BlocConsumer<PriestWalletCubit, PriestWalletState>(
        listener: (context, state) {
          if (state is PriestWalletError) {
            AppSnackBar.error(context, state.message);
          }
        },
        builder: (context, state) {
          return switch (state) {
            PriestWalletInitial() ||
            PriestWalletLoading() => const _LoadingBody(),
            PriestWalletLoaded() => _LoadedBody(
                state: state,
                uid: _uid,
                onWithdraw: () => _showWithdrawSheet(context, state),
                onAddBank: () => _navigateToBankDetails(context, null),
              ),
            PriestWalletError() => _ErrorBody(
                message: state.message,
                onRetry: () {
                  final uid = _uid;
                  if (uid != null) {
                    context.read<PriestWalletCubit>().loadWallet(uid);
                  }
                },
              ),
          };
        },
      ),
    );
  }

  PreferredSizeWidget _buildAppBar() {
    return AppBar(
      backgroundColor: AppColors.background,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
      automaticallyImplyLeading: false,
      titleSpacing: 16,
      leading: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => context.pop(),
          child: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.surfaceWhite,
              boxShadow: [
                BoxShadow(
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                  color: Colors.black.withValues(alpha: 0.04),
                ),
              ],
            ),
            child: const Icon(
              Icons.arrow_back_ios_new_rounded,
              size: 16,
              color: AppColors.deepDarkBrown,
            ),
          ),
        ),
      ),
      title: Text(
        "My Wallet",
        style: GoogleFonts.inter(
          fontSize: 18,
          fontWeight: FontWeight.w600,
          color: AppColors.deepDarkBrown,
        ),
      ),
      centerTitle: false,
      bottom: PreferredSize(
        preferredSize: const Size.fromHeight(1),
        child: Container(
          height: 1,
          color: AppColors.muted.withValues(alpha: 0.08),
        ),
      ),
    );
  }

  void _showWithdrawSheet(BuildContext context, PriestWalletLoaded state) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => _WithdrawalSheet(
        balance: state.balance,
        minAmount: state.minWithdrawalAmount,
        bankDetails: state.bankDetails!,
        onEditBank: () {
          Navigator.pop(sheetContext);
          _navigateToBankDetails(context, state.bankDetails);
        },
        // First-step confirm only opens the second-step sheet — it
        // does NOT debit. Money movement happens only after the
        // priest taps "Yes, Withdraw" on the confirmation sheet.
        onConfirm: (amount) {
          Navigator.pop(sheetContext);
          if (!context.mounted) return;
          _showConfirmationSheet(context, state.bankDetails!, amount);
        },
      ),
    );
  }

  // Second-step confirmation — the actual money-moving tap. Shown
  // as a separate sheet so the priest sees a clear, irreversible
  // "Are you sure?" before any balance change. Mature money apps
  // universally have this checkpoint; a single-tap withdrawal is
  // the kind of UX that produces accidental debits and angry
  // support tickets.
  void _showConfirmationSheet(
    BuildContext context,
    BankDetails bankDetails,
    int amount,
  ) {
    final cubit = context.read<PriestWalletCubit>();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => _ConfirmWithdrawalSheet(
        amount: amount,
        bankDetails: bankDetails,
        onCancel: () => Navigator.pop(sheetContext),
        onConfirm: () async {
          Navigator.pop(sheetContext);
          // Light tap when the priest commits — a tactile receipt
          // that the action registered, before the network round-
          // trip resolves.
          unawaited(HapticFeedback.lightImpact());
          final uid = _uid;
          if (uid == null) return;
          try {
            await cubit.requestWithdrawal(amount, uid);
            if (!context.mounted) return;
            _showSuccessSheet(context, amount);
          } on TimeoutException {
            if (!context.mounted) return;
            AppSnackBar.error(
              context,
              "Request timed out. Check your connection.",
            );
          } on WithdrawalException catch (e) {
            if (!context.mounted) return;
            AppSnackBar.error(context, _friendlyError(e));
          } catch (_) {
            if (!context.mounted) return;
            AppSnackBar.error(
              context,
              "Withdrawal failed. Please try again.",
            );
          }
        },
      ),
    );
  }

  // Maps the CF's structured `reason` token to a user-facing
  // message. Lives on the page so localisation later becomes a
  // one-place edit. Anything we don't recognise falls through to
  // a safe generic — the CF can add new reasons without breaking
  // older clients silently.
  String _friendlyError(WithdrawalException e) {
    switch (e.reason) {
      case 'insufficient_balance':
        return "Insufficient balance.";
      case 'below_minimum':
        final min = (e.details['minAmount'] as num?)?.toInt();
        return min != null
            ? "Minimum withdrawal is ₹$min."
            : "Amount below minimum withdrawal.";
      case 'no_bank_details':
        return "Add bank details before withdrawing.";
      case 'account_inactive':
        return "Account is not active.";
      case 'invalid_amount':
        return "Enter a valid amount.";
      case 'request_id_conflict':
      case 'invalid_request_id':
        return "Couldn't process the request. Please try again.";
      default:
        return "Withdrawal failed. Please try again.";
    }
  }

  void _showSuccessSheet(BuildContext context, int amount) {
    showModalBottomSheet(
      context: context,
      isDismissible: false,
      enableDrag: false,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => _SuccessSheet(amount: amount),
    );
  }

  Future<void> _navigateToBankDetails(
    BuildContext context,
    BankDetails? existing,
  ) async {
    final cubit = context.read<PriestWalletCubit>();
    final result = await context.push<Object?>(
      '/priest/bank-details',
      extra: existing,
    );
    if (!mounted) return;
    if (result is BankDetails) {
      // Surface the freshly-saved details to the cubit so the hero
      // CTA flips from "Add Bank Details" to "Withdraw to Bank"
      // without needing a manual refresh.
      cubit.updateBankDetails(result);
    }
  }
}

// ─── Loaded body ───────────────────────────────────────────────

class _LoadedBody extends StatelessWidget {
  final PriestWalletLoaded state;
  final String? uid;
  final VoidCallback onWithdraw;
  final VoidCallback onAddBank;

  const _LoadedBody({
    required this.state,
    required this.uid,
    required this.onWithdraw,
    required this.onAddBank,
  });

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      color: AppColors.primaryBrown,
      backgroundColor: AppColors.surfaceWhite,
      onRefresh: () async {
        final id = uid;
        if (id != null) {
          await context.read<PriestWalletCubit>().refreshTransactions(id);
        }
      },
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(
          parent: BouncingScrollPhysics(),
        ),
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _BalanceCard(
              state: state,
              onWithdraw: onWithdraw,
              onAddBank: onAddBank,
            ),
            if (state.needsBankDetails) ...[
              const SizedBox(height: 12),
              const _InfoTip(
                "Add your bank account details to enable withdrawals. "
                "Your earnings are safe and will be available whenever "
                "you're ready to withdraw.",
              ),
            ] else if (state.balance > 0 &&
                state.balance < state.minWithdrawalAmount) ...[
              const SizedBox(height: 12),
              _InfoTip(
                "Minimum withdrawal amount is "
                "₹${state.minWithdrawalAmount}. Keep accepting "
                "sessions to reach this threshold.",
              ),
            ],
            const SizedBox(height: 28),
            Row(
              children: [
                Expanded(
                  child: _QuickStat(
                    label: "Total Earned",
                    // Sourced from priests/{uid}.totalEarnings, not
                    // computed from the 50-record transaction
                    // window — the latter would silently break
                    // once a priest crosses that history depth.
                    value: "₹${state.totalEarnings.toStringAsFixed(0)}",
                    icon: Icons.trending_up_rounded,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _QuickStat(
                    label: "Withdrawn",
                    value:
                        "₹${state.totalWithdrawn.toStringAsFixed(0)}",
                    icon: Icons.account_balance_outlined,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 28),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  "Transaction History",
                  style: GoogleFonts.inter(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: AppColors.deepDarkBrown,
                  ),
                ),
                if (state.transactions.isNotEmpty)
                  Text(
                    "${state.transactions.length} entries",
                    style: GoogleFonts.inter(
                      fontSize: 12,
                      fontWeight: FontWeight.w400,
                      color: AppColors.muted,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 14),
            if (state.transactions.isEmpty)
              const _EmptyTransactions()
            else
              // Direct Column children rather than a nested ListView —
              // we're already inside a SingleChildScrollView and don't
              // want a viewport-on-viewport that wastes scroll physics.
              ...state.transactions.map(
                (tx) => Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _TransactionCard(transaction: tx),
                ),
              ),
          ],
        ),
      ),
    );
  }

}

// ─── Hero balance card ─────────────────────────────────────────

class _BalanceCard extends StatelessWidget {
  final PriestWalletLoaded state;
  final VoidCallback onWithdraw;
  final VoidCallback onAddBank;

  const _BalanceCard({
    required this.state,
    required this.onWithdraw,
    required this.onAddBank,
  });

  @override
  Widget build(BuildContext context) {
    final canWithdraw = state.canWithdraw;
    final ctaLabel = state.needsBankDetails
        ? "Add Bank Details to Withdraw"
        : state.balance < state.minWithdrawalAmount
            ? "Min ₹${state.minWithdrawalAmount} to Withdraw"
            : "Withdraw to Bank";

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF2C1810), Color(0xFF3D1F0F)],
        ),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF2C1810).withValues(alpha: 0.3),
            blurRadius: 20,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            "Available Balance",
            style: GoogleFonts.inter(
              fontSize: 13,
              fontWeight: FontWeight.w400,
              color: Colors.white.withValues(alpha: 0.5),
            ),
          ),
          const SizedBox(height: 8),
          // FittedBox shrinks the balance text to fit the card width
          // when either the amount has many digits (lakh+) or the
          // user is on a large system text scale. Without this the
          // 36px display overflows the card on small screens once
          // the balance crosses ~5 digits.
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              state.formattedBalance,
              maxLines: 1,
              style: GoogleFonts.inter(
                fontSize: 36,
                fontWeight: FontWeight.w800,
                color: Colors.white,
                letterSpacing: -1,
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            "₹1 = 1 coin earned from sessions",
            style: GoogleFonts.inter(
              fontSize: 11,
              fontWeight: FontWeight.w400,
              color: const Color(0xFFC8902A).withValues(alpha: 0.6),
            ),
          ),
          const SizedBox(height: 20),
          _PressableScale(
            onTap: () {
              if (state.needsBankDetails) {
                onAddBank();
              } else if (canWithdraw) {
                onWithdraw();
              }
            },
            child: Container(
              width: double.infinity,
              height: 48,
              decoration: BoxDecoration(
                color: canWithdraw
                    ? const Color(0xFFC8902A)
                    : Colors.white.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Center(
                child: Text(
                  ctaLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: canWithdraw
                        ? Colors.white
                        : Colors.white.withValues(alpha: 0.3),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Quick stat tiles ──────────────────────────────────────────

class _QuickStat extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;

  const _QuickStat({
    required this.label,
    required this.value,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surfaceWhite,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: AppColors.muted.withValues(alpha: 0.08),
        ),
        boxShadow: [
          BoxShadow(
            blurRadius: 8,
            offset: const Offset(0, 2),
            color: Colors.black.withValues(alpha: 0.03),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            icon,
            size: 20,
            color: AppColors.primaryBrown.withValues(alpha: 0.5),
          ),
          const SizedBox(height: 10),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: GoogleFonts.inter(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: AppColors.deepDarkBrown,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: GoogleFonts.inter(
              fontSize: 11,
              fontWeight: FontWeight.w400,
              color: AppColors.muted,
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Transaction list row ──────────────────────────────────────

class _TransactionCard extends StatelessWidget {
  final WalletTransaction transaction;

  const _TransactionCard({required this.transaction});

  @override
  Widget build(BuildContext context) {
    final tx = transaction;
    final earning = tx.isEarning;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: AppColors.surfaceWhite,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: AppColors.muted.withValues(alpha: 0.06),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: earning
                  ? _kSuccessGreen.withValues(alpha: 0.08)
                  : AppColors.muted.withValues(alpha: 0.06),
            ),
            child: Icon(
              tx.icon,
              size: 18,
              color: earning ? _kSuccessGreen : AppColors.muted,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  tx.description.isEmpty ? _fallbackLabel(tx) : tx.description,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: AppColors.deepDarkBrown,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  tx.formattedDate,
                  style: GoogleFonts.inter(
                    fontSize: 11,
                    fontWeight: FontWeight.w400,
                    color: AppColors.muted,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            "${earning ? '+' : '-'}₹${tx.coins.abs()}",
            style: GoogleFonts.inter(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: earning ? _kSuccessGreen : AppColors.deepDarkBrown,
            ),
          ),
        ],
      ),
    );
  }

  // Fallback for old records that pre-date the description field —
  // keeps the list readable instead of showing an empty row.
  String _fallbackLabel(WalletTransaction tx) {
    switch (tx.type) {
      case 'session_charge':
        return 'Session earnings';
      case 'activation_fee':
        return 'Activation fee';
      case 'withdrawal':
        return 'Withdrawal to bank';
      case 'refund':
        return 'Refund';
      default:
        return 'Transaction';
    }
  }
}

// ─── Empty + info widgets ──────────────────────────────────────

class _EmptyTransactions extends StatelessWidget {
  const _EmptyTransactions();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.receipt_long_outlined,
            size: 48,
            color: AppColors.muted.withValues(alpha: 0.2),
          ),
          const SizedBox(height: 16),
          Text(
            "No transactions yet",
            style: GoogleFonts.inter(
              fontSize: 15,
              fontWeight: FontWeight.w500,
              color: AppColors.muted,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            "Your session earnings will appear here",
            style: GoogleFonts.inter(
              fontSize: 13,
              fontWeight: FontWeight.w400,
              color: AppColors.muted.withValues(alpha: 0.6),
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoTip extends StatelessWidget {
  final String text;

  const _InfoTip(this.text);

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.primaryBrown.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: AppColors.primaryBrown.withValues(alpha: 0.1),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.info_outline_rounded,
            size: 16,
            color: AppColors.primaryBrown.withValues(alpha: 0.7),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: GoogleFonts.inter(
                fontSize: 12,
                fontWeight: FontWeight.w400,
                height: 1.5,
                color: AppColors.primaryBrown.withValues(alpha: 0.85),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Loading + error bodies ────────────────────────────────────

class _LoadingBody extends StatelessWidget {
  const _LoadingBody();

  @override
  Widget build(BuildContext context) {
    final base = AppColors.muted.withValues(alpha: 0.14);
    final highlight = AppColors.warmBeige;

    return SingleChildScrollView(
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Shimmer.fromColors(
            baseColor: base,
            highlightColor: highlight,
            child: Container(
              height: 188,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(20),
              ),
            ),
          ),
          const SizedBox(height: 28),
          Row(
            children: [
              Expanded(
                child: Shimmer.fromColors(
                  baseColor: base,
                  highlightColor: highlight,
                  child: Container(
                    height: 92,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Shimmer.fromColors(
                  baseColor: base,
                  highlightColor: highlight,
                  child: Container(
                    height: 92,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 28),
          for (int i = 0; i < 4; i++) ...[
            Shimmer.fromColors(
              baseColor: base,
              highlightColor: highlight,
              child: Container(
                height: 68,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
            const SizedBox(height: 8),
          ],
        ],
      ),
    );
  }
}

class _ErrorBody extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _ErrorBody({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.error_outline_rounded,
              size: 44,
              color: AppColors.errorRed,
            ),
            const SizedBox(height: 14),
            Text(
              message,
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: AppColors.muted,
              ),
            ),
            const SizedBox(height: 20),
            _PressableScale(
              onTap: onRetry,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 28,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: AppColors.primaryBrown,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  "Retry",
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Withdrawal sheet ──────────────────────────────────────────

class _WithdrawalSheet extends StatefulWidget {
  final double balance;
  final int minAmount;
  final BankDetails bankDetails;
  final ValueChanged<int> onConfirm;
  final VoidCallback onEditBank;

  const _WithdrawalSheet({
    required this.balance,
    required this.minAmount,
    required this.bankDetails,
    required this.onConfirm,
    required this.onEditBank,
  });

  @override
  State<_WithdrawalSheet> createState() => _WithdrawalSheetState();
}

class _WithdrawalSheetState extends State<_WithdrawalSheet> {
  late final TextEditingController _amountController;
  String? _amountError;

  @override
  void initState() {
    super.initState();
    // Pre-fill with the full available balance — most priests
    // withdraw the lot, and pre-filling avoids a tap for the common
    // case while still being editable.
    _amountController = TextEditingController(
      text: widget.balance.toStringAsFixed(0),
    );
  }

  @override
  void dispose() {
    _amountController.dispose();
    super.dispose();
  }

  void _validateAmount() {
    final text = _amountController.text.trim();
    if (text.isEmpty) {
      setState(() => _amountError = null);
      return;
    }
    final amount = int.tryParse(text);
    if (amount == null) {
      setState(() => _amountError = "Enter a valid amount");
    } else if (amount < widget.minAmount) {
      setState(
        () => _amountError = "Minimum withdrawal is ₹${widget.minAmount}",
      );
    } else if (amount > widget.balance) {
      setState(() => _amountError = "Exceeds available balance");
    } else {
      setState(() => _amountError = null);
    }
  }

  bool get _isValid {
    final amount = int.tryParse(_amountController.text.trim());
    return amount != null &&
        amount >= widget.minAmount &&
        amount <= widget.balance;
  }

  int get _amount => int.parse(_amountController.text.trim());

  void _setAmount(int amount) {
    if (amount > widget.balance) return;
    _amountController.text = amount.toString();
    _amountController.selection = TextSelection.collapsed(
      offset: _amountController.text.length,
    );
    _validateAmount();
  }

  String _lastFour(String accountNumber) {
    if (accountNumber.length < 4) return accountNumber;
    return accountNumber.substring(accountNumber.length - 4);
  }

  @override
  Widget build(BuildContext context) {
    final viewInsets = MediaQuery.of(context).viewInsets.bottom;
    final paddingBottom = MediaQuery.of(context).padding.bottom;

    return Container(
      decoration: const BoxDecoration(
        color: AppColors.surfaceWhite,
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(24),
          topRight: Radius.circular(24),
        ),
      ),
      padding: EdgeInsets.fromLTRB(24, 12, 24, viewInsets),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.muted.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              "Withdraw to Bank",
              style: GoogleFonts.inter(
                fontSize: 20,
                fontWeight: FontWeight.w700,
                color: AppColors.deepDarkBrown,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              "Available: ₹${widget.balance.toStringAsFixed(0)}",
              style: GoogleFonts.inter(
                fontSize: 13,
                fontWeight: FontWeight.w400,
                color: AppColors.muted,
              ),
            ),
            const SizedBox(height: 24),
            Text(
              "Amount (₹)",
              style: GoogleFonts.inter(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: AppColors.deepDarkBrown,
              ),
            ),
            const SizedBox(height: 8),
            Container(
              decoration: BoxDecoration(
                color: const Color(0xFFF7F5F2),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: _amountError != null
                      ? AppColors.errorRed
                      : AppColors.muted.withValues(alpha: 0.12),
                ),
              ),
              child: TextField(
                controller: _amountController,
                keyboardType: TextInputType.number,
                style: GoogleFonts.inter(
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                  color: AppColors.deepDarkBrown,
                ),
                decoration: InputDecoration(
                  prefixText: "₹ ",
                  prefixStyle: GoogleFonts.inter(
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                    color: AppColors.muted,
                  ),
                  hintText: widget.balance.toStringAsFixed(0),
                  hintStyle: GoogleFonts.inter(
                    fontSize: 20,
                    fontWeight: FontWeight.w400,
                    color: AppColors.muted.withValues(alpha: 0.3),
                  ),
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 14,
                  ),
                ),
                onChanged: (_) => _validateAmount(),
              ),
            ),
            if (_amountError != null) ...[
              const SizedBox(height: 6),
              Text(
                _amountError!,
                style: GoogleFonts.inter(
                  fontSize: 12,
                  fontWeight: FontWeight.w400,
                  color: AppColors.errorRed,
                ),
              ),
            ],
            const SizedBox(height: 14),
            Row(
              children: [
                _AmountChip(
                  label: "₹500",
                  amount: 500,
                  available: widget.balance,
                  onTap: () => _setAmount(500),
                ),
                const SizedBox(width: 8),
                _AmountChip(
                  label: "₹1,000",
                  amount: 1000,
                  available: widget.balance,
                  onTap: () => _setAmount(1000),
                ),
                const SizedBox(width: 8),
                _AmountChip(
                  label: "Full",
                  amount: widget.balance.toInt(),
                  available: widget.balance,
                  onTap: () => _setAmount(widget.balance.toInt()),
                ),
              ],
            ),
            const SizedBox(height: 20),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xFFF7F5F2),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.account_balance_outlined,
                    size: 18,
                    color: AppColors.muted,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.bankDetails.bankName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: GoogleFonts.inter(
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                            color: AppColors.deepDarkBrown,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          "A/c: ••••${_lastFour(widget.bankDetails.accountNumber)}",
                          style: GoogleFonts.inter(
                            fontSize: 12,
                            fontWeight: FontWeight.w400,
                            color: AppColors.muted,
                          ),
                        ),
                      ],
                    ),
                  ),
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: widget.onEditBank,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 4,
                      ),
                      child: Text(
                        "Edit",
                        style: GoogleFonts.inter(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: AppColors.primaryBrown,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            _PressableScale(
              onTap: _isValid
                  ? () => widget.onConfirm(_amount)
                  : null,
              child: Container(
                width: double.infinity,
                height: 52,
                decoration: BoxDecoration(
                  color: _isValid
                      ? AppColors.primaryBrown
                      : AppColors.muted.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(14),
                  boxShadow: _isValid
                      ? [
                          BoxShadow(
                            color: AppColors.primaryBrown
                                .withValues(alpha: 0.2),
                            blurRadius: 12,
                            offset: const Offset(0, 4),
                          ),
                        ]
                      : const [],
                ),
                child: Center(
                  child: Text(
                    "Confirm Withdrawal",
                    style: GoogleFonts.inter(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Center(
              child: Text(
                "Withdrawal is processed immediately. No fees.",
                style: GoogleFonts.inter(
                  fontSize: 11,
                  fontWeight: FontWeight.w400,
                  color: AppColors.muted,
                ),
              ),
            ),
            SizedBox(height: paddingBottom + 20),
          ],
        ),
      ),
    );
  }
}

class _AmountChip extends StatelessWidget {
  final String label;
  final int amount;
  final double available;
  final VoidCallback onTap;

  const _AmountChip({
    required this.label,
    required this.amount,
    required this.available,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = amount <= available && amount > 0;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: enabled ? onTap : null,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: enabled
              ? AppColors.primaryBrown.withValues(alpha: 0.06)
              : AppColors.muted.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: enabled
                ? AppColors.primaryBrown.withValues(alpha: 0.15)
                : AppColors.muted.withValues(alpha: 0.1),
          ),
        ),
        child: Text(
          label,
          style: GoogleFonts.inter(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: enabled
                ? AppColors.primaryBrown
                : AppColors.muted.withValues(alpha: 0.4),
          ),
        ),
      ),
    );
  }
}

// ─── Confirmation sheet ────────────────────────────────────────

// Second-step money-movement gate. The wallet page first opens
// _WithdrawalSheet (amount entry); on Confirm there, this sheet
// opens to show the priest exactly what's about to happen and
// requires one more tap. No CF call has been made yet.
class _ConfirmWithdrawalSheet extends StatelessWidget {
  final int amount;
  final BankDetails bankDetails;
  final VoidCallback onCancel;
  final VoidCallback onConfirm;

  const _ConfirmWithdrawalSheet({
    required this.amount,
    required this.bankDetails,
    required this.onCancel,
    required this.onConfirm,
  });

  String _lastFour(String n) =>
      n.length < 4 ? n : n.substring(n.length - 4);

  @override
  Widget build(BuildContext context) {
    final paddingBottom = MediaQuery.of(context).padding.bottom;

    return Container(
      decoration: const BoxDecoration(
        color: AppColors.surfaceWhite,
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(24),
          topRight: Radius.circular(24),
        ),
      ),
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.muted.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 20),
          Center(
            child: Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.amberGold.withValues(alpha: 0.12),
              ),
              child: Icon(
                Icons.account_balance_outlined,
                size: 28,
                color: AppColors.amberGold,
              ),
            ),
          ),
          const SizedBox(height: 16),
          // The headline echoes the bank info verbatim — last-4
          // digits and bank name are exactly what the priest sees
          // on their bank statement, so the visual match is the
          // strongest sanity check before committing.
          Text(
            "Withdraw ₹$amount to ${bankDetails.bankName}\n"
            "A/c ••••${_lastFour(bankDetails.accountNumber)}?",
            textAlign: TextAlign.center,
            style: GoogleFonts.inter(
              fontSize: 17,
              fontWeight: FontWeight.w700,
              height: 1.4,
              color: AppColors.deepDarkBrown,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            "This action cannot be undone. "
            "The amount will be processed within 1-3 business days.",
            textAlign: TextAlign.center,
            style: GoogleFonts.inter(
              fontSize: 12,
              fontWeight: FontWeight.w400,
              height: 1.5,
              color: AppColors.muted,
            ),
          ),
          const SizedBox(height: 24),
          Row(
            children: [
              Expanded(
                child: _PressableScale(
                  onTap: onCancel,
                  child: Container(
                    height: 52,
                    decoration: BoxDecoration(
                      color: AppColors.muted.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Center(
                      child: Text(
                        "Cancel",
                        style: GoogleFonts.inter(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: AppColors.deepDarkBrown,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _PressableScale(
                  onTap: onConfirm,
                  child: Container(
                    height: 52,
                    decoration: BoxDecoration(
                      color: AppColors.primaryBrown,
                      borderRadius: BorderRadius.circular(14),
                      boxShadow: [
                        BoxShadow(
                          color: AppColors.primaryBrown
                              .withValues(alpha: 0.2),
                          blurRadius: 12,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Center(
                      child: Text(
                        "Yes, Withdraw",
                        style: GoogleFonts.inter(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
          SizedBox(height: paddingBottom + 20),
        ],
      ),
    );
  }
}

// ─── Success sheet ─────────────────────────────────────────────

// Stateful so we can fire the confirmation haptic in initState.
// Doing it in the parent's `then` callback would race with the
// sheet's animation and feel disconnected from the visual.
class _SuccessSheet extends StatefulWidget {
  final int amount;

  const _SuccessSheet({required this.amount});

  @override
  State<_SuccessSheet> createState() => _SuccessSheetState();
}

class _SuccessSheetState extends State<_SuccessSheet> {
  @override
  void initState() {
    super.initState();
    // Medium impact (heavier than the commit-tap haptic) marks the
    // moment the request is confirmed — celebratory by intent,
    // matching the visual checkmark animation.
    unawaited(HapticFeedback.mediumImpact());
  }

  @override
  Widget build(BuildContext context) {
    final paddingBottom = MediaQuery.of(context).padding.bottom;

    return Container(
      decoration: const BoxDecoration(
        color: AppColors.surfaceWhite,
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(24),
          topRight: Radius.circular(24),
        ),
      ),
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 8),
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _kSuccessGreen.withValues(alpha: 0.1),
            ),
            child: const Icon(
              Icons.check_rounded,
              size: 32,
              color: _kSuccessGreen,
            ),
          ),
          const SizedBox(height: 20),
          // Honest copy: the request is queued, not "successful".
          // The bank transfer happens out-of-band when the admin
          // payout dashboard processes the pending withdrawal.
          Text(
            "Withdrawal Requested",
            style: GoogleFonts.inter(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: AppColors.deepDarkBrown,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            "₹${widget.amount} withdrawal is being processed. "
            "You'll be notified when it's sent to your bank.",
            textAlign: TextAlign.center,
            style: GoogleFonts.inter(
              fontSize: 13,
              fontWeight: FontWeight.w400,
              height: 1.5,
              color: AppColors.muted,
            ),
          ),
          const SizedBox(height: 24),
          _PressableScale(
            onTap: () => Navigator.pop(context),
            child: Container(
              width: double.infinity,
              height: 48,
              decoration: BoxDecoration(
                color: AppColors.primaryBrown,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Center(
                child: Text(
                  "Done",
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
          ),
          SizedBox(height: paddingBottom + 12),
        ],
      ),
    );
  }
}

// ─── Pressable scale wrapper ──────────────────────────────────

// GestureDetector + AnimatedScale press feedback. Lifted from the
// dashboard's _QuickAction for consistency with the rest of the
// priest-side UI.
class _PressableScale extends StatefulWidget {
  final VoidCallback? onTap;
  final Widget child;

  const _PressableScale({required this.onTap, required this.child});

  @override
  State<_PressableScale> createState() => _PressableScaleState();
}

class _PressableScaleState extends State<_PressableScale> {
  double _scale = 1.0;

  void _down() {
    if (widget.onTap == null) return;
    setState(() => _scale = 0.97);
  }

  void _up() {
    if (_scale == 1.0) return;
    setState(() => _scale = 1.0);
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (_) => _down(),
      onPointerUp: (_) => _up(),
      onPointerCancel: (_) => _up(),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _scale,
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
          child: widget.child,
        ),
      ),
    );
  }
}
