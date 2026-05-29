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

import 'package:gospel_vox/core/services/injection_container.dart';
import 'package:gospel_vox/core/theme/app_colors.dart';
import 'package:gospel_vox/core/widgets/app_back_button.dart';
import 'package:gospel_vox/core/widgets/app_snackbar.dart';
import 'package:gospel_vox/features/priest/wallet/bloc/priest_wallet_cubit.dart';
import 'package:gospel_vox/features/priest/wallet/bloc/priest_wallet_state.dart';
import 'package:gospel_vox/features/priest/wallet/data/priest_wallet_repository.dart';
import 'package:gospel_vox/features/priest/wallet/data/wallet_models.dart';
import 'package:gospel_vox/features/priest/wallet/pages/bank_details_page.dart'
    show formatMaskedAccountNumber;
import 'package:gospel_vox/core/widgets/app_icons.dart';

const Color _kSuccessGreen = Color(0xFF2E7D4F);

class PriestWalletPage extends StatefulWidget {
  const PriestWalletPage({super.key});

  @override
  State<PriestWalletPage> createState() => _PriestWalletPageState();
}

class _PriestWalletPageState extends State<PriestWalletPage> {
  String? _uid;
  // Single scroll controller owned by the page so a tap on the
  // "Wallet History" pill inside the withdraw sheet can close the
  // sheet AND animate the wallet body down to the transactions
  // section, instead of just dumping the priest back on the hero
  // card and making them scroll manually.
  final ScrollController _bodyScrollController = ScrollController();
  // GlobalKey on the transactions header — used to compute its
  // offset inside the scroll view for the scroll-to-history jump.
  final GlobalKey _transactionsAnchorKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _uid = FirebaseAuth.instance.currentUser?.uid;
  }

  @override
  void dispose() {
    _bodyScrollController.dispose();
    super.dispose();
  }

  // Animates the wallet body so the Transaction History header sits
  // near the top of the viewport. Falls back to scrolling to the
  // bottom if the anchor hasn't been laid out yet (shouldn't happen
  // since the withdraw button only exists once we're in Loaded).
  void _scrollToHistory() {
    final ctx = _transactionsAnchorKey.currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 380),
        curve: Curves.easeInOutCubic,
        // 96px from the top leaves the AppBar + a comfortable gap
        // above the header so the section feels intentionally
        // brought into focus rather than scrolled to the edge.
        alignmentPolicy: ScrollPositionAlignmentPolicy.explicit,
        alignment: 0,
      );
      return;
    }
    if (_bodyScrollController.hasClients) {
      _bodyScrollController.animateTo(
        _bodyScrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 380),
        curve: Curves.easeInOutCubic,
      );
    }
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
                scrollController: _bodyScrollController,
                transactionsAnchorKey: _transactionsAnchorKey,
                onWithdraw: () => _showWithdrawSheet(context, state),
                onAddBank: () => _navigateToBankDetails(context, null),
                onEditBank: () => _navigateToBankDetails(
                  context,
                  state.bankDetails,
                ),
                onDeleteBank: _handleDeleteBank,
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
      leading: const Padding(
        padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: AppBackButton(),
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
        // Closes the sheet and animates the wallet body to the
        // Transaction History section. Lets the priest jump from
        // "how much to withdraw" → "what did I last withdraw"
        // without backing out and scrolling manually.
        onHistory: () {
          Navigator.pop(sheetContext);
          // One post-frame tick so the sheet's close animation has
          // started — otherwise ensureVisible can compute the
          // pre-pop offset and the jump feels off.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            _scrollToHistory();
          });
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
    // Guard the param BuildContext directly — `mounted` only tells
    // us about the State, not about whichever BuildContext the
    // caller handed in (which could legitimately be a child route's
    // context that's already gone).
    if (!context.mounted) return;
    if (result is BankDetails) {
      // Surface the freshly-saved details to the cubit so the hero
      // CTA flips from "Add Bank Details" to "Withdraw to Bank"
      // without needing a manual refresh.
      cubit.updateBankDetails(result);
      AppSnackBar.success(context, 'Bank details saved');
    }
  }

  // Delete handler for the Linked Bank card. Runs the pending-
  // withdrawal check first so the priest knows admin payouts will
  // still process against the snapshotted bank fields on those
  // rows. Calls into the repo + cubit so the hero CTA flips back
  // to "Add Bank Details to Withdraw" without waiting on the
  // priest-doc stream to catch up.
  //
  // Uses `this.context` after every `mounted` check — passing a
  // BuildContext through the async gap upsets the analyzer's
  // use-context-across-async-gaps lint and creates real safety
  // issues if a route pops mid-flight.
  Future<void> _handleDeleteBank() async {
    final uid = _uid;
    if (uid == null) return;

    final repo = sl<PriestWalletRepository>();
    // Capture the cubit while context is known-good. Cubit
    // references survive the route popping; BuildContext doesn't.
    final cubit = context.read<PriestWalletCubit>();

    // Pending count guards the confirmation copy. -1 marks the
    // lookup as having failed so the dialog can soften the wording
    // ("we couldn't check…") instead of falsely claiming zero.
    int pending = -1;
    try {
      pending = await repo.getPendingWithdrawalCount(uid);
    } catch (_) {
      pending = -1;
    }

    if (!mounted) return;

    final confirmed = await showDialog<bool>(
      context: context,
      barrierColor: AppColors.deepDarkBrown.withValues(alpha: 0.35),
      builder: (dialogCtx) =>
          _DeleteBankDialog(pendingWithdrawals: pending),
    );

    if (confirmed != true || !mounted) return;

    try {
      await repo.clearBankDetails(uid);
      if (!mounted) return;
      cubit.clearBankDetails();
      HapticFeedback.lightImpact();
      AppSnackBar.success(context, 'Bank details removed');
    } on TimeoutException {
      if (!mounted) return;
      AppSnackBar.error(
        context,
        'Network is slow. Check your connection and try again.',
      );
    } catch (_) {
      if (!mounted) return;
      AppSnackBar.error(context, 'Could not remove. Try again.');
    }
  }
}

// ─── Loaded body ───────────────────────────────────────────────

class _LoadedBody extends StatelessWidget {
  final PriestWalletLoaded state;
  final String? uid;
  // Owned by _PriestWalletPageState so scroll-to-history works from
  // the withdraw sheet without losing the existing scroll position
  // on every rebuild.
  final ScrollController scrollController;
  // Pin used by Scrollable.ensureVisible to locate the Transaction
  // History header inside the scroll view.
  final Key transactionsAnchorKey;
  final VoidCallback onWithdraw;
  final VoidCallback onAddBank;
  // Edit + Delete on the inline Linked Bank card below the hero.
  // Edit reuses the same /priest/bank-details route as Add, just
  // pre-filled. Delete pops up the confirmation dialog with the
  // pending-withdrawal copy.
  final VoidCallback onEditBank;
  final VoidCallback onDeleteBank;

  const _LoadedBody({
    required this.state,
    required this.uid,
    required this.scrollController,
    required this.transactionsAnchorKey,
    required this.onWithdraw,
    required this.onAddBank,
    required this.onEditBank,
    required this.onDeleteBank,
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
        controller: scrollController,
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
            // Linked Bank Card — sits directly below the hero so the
            // priest sees where withdrawals will land at a glance,
            // and can edit or remove the account without leaving the
            // wallet page. Only renders once a complete bank record
            // exists; first-time setup still flows through the hero
            // "Add Bank Details" CTA.
            if (!state.needsBankDetails && state.bankDetails != null) ...[
              const SizedBox(height: 16),
              _LinkedBankCard(
                details: state.bankDetails!,
                onEdit: onEditBank,
                onDelete: onDeleteBank,
              ),
            ],
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
                    icon: AppIcons.trendingUp,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _QuickStat(
                    label: "Withdrawn",
                    value:
                        "₹${state.totalWithdrawn.toStringAsFixed(0)}",
                    icon: AppIcons.bank,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 28),
            Row(
              key: transactionsAnchorKey,
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
          AppIcon(
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
            child: AppIcon(
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
      case 'bible_session_earning':
        return 'Bible Session earning';
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
          AppIcon(
            AppIcons.receipt,
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
          AppIcon(
            AppIcons.info,
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
            const AppIcon(
              AppIcons.error,
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
  // Closes the sheet and scrolls the wallet body to the Transaction
  // History section. Wired up by the wallet page; null-safe so the
  // sheet still works if a future caller doesn't supply it.
  final VoidCallback? onHistory;

  const _WithdrawalSheet({
    required this.balance,
    required this.minAmount,
    required this.bankDetails,
    required this.onConfirm,
    required this.onEditBank,
    this.onHistory,
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
            // Title row + Wallet History pill on the right. Mirrors
            // the reference layout — "available balance" left,
            // quick jump to past transactions on the right.
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
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
                    ],
                  ),
                ),
                if (widget.onHistory != null)
                  _WalletHistoryPill(onTap: widget.onHistory!),
              ],
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
                  const AppIcon(
                    AppIcons.bank,
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
                          "A/c ${formatMaskedAccountNumber(widget.bankDetails.accountNumber)}",
                          style: GoogleFonts.inter(
                            fontSize: 12,
                            fontWeight: FontWeight.w400,
                            color: AppColors.muted,
                            fontFeatures: const [
                              FontFeature.tabularFigures(),
                            ],
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

// ─── Wallet History pill (used on the withdraw amount sheet) ───

class _WalletHistoryPill extends StatelessWidget {
  final VoidCallback onTap;

  const _WalletHistoryPill({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: AppColors.primaryBrown.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: AppColors.primaryBrown.withValues(alpha: 0.16),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppIcon(
              AppIcons.history,
              size: 13,
              color: AppColors.primaryBrown,
            ),
            const SizedBox(width: 6),
            Text(
              'Wallet History',
              style: GoogleFonts.inter(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: AppColors.primaryBrown,
              ),
            ),
          ],
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
//
// Layout mirrors the reference's "Confirm Withdrawal" — a single
// breakdown card (Amount / Processing Fee / You Will Receive), a
// To-Bank-Account card with masked account number, an Important
// Information block setting expectations, and the dual-button
// commit row at the bottom.
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

  @override
  Widget build(BuildContext context) {
    final paddingBottom = MediaQuery.of(context).padding.bottom;
    // Processing fee is 0 in the current economy. Surfaced as a
    // named value so when admin introduces a fee later (Razorpay X
    // payout cost passed through, etc.) it's a one-line change.
    const int processingFee = 0;
    final receiveAmount = amount - processingFee;

    return Container(
      decoration: const BoxDecoration(
        color: AppColors.surfaceWhite,
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(24),
          topRight: Radius.circular(24),
        ),
      ),
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
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
            const SizedBox(height: 18),
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: Text(
                'Confirm Withdrawal',
                style: GoogleFonts.inter(
                  fontSize: 19,
                  fontWeight: FontWeight.w700,
                  color: AppColors.deepDarkBrown,
                ),
              ),
            ),
            const SizedBox(height: 16),

            // ── Amount breakdown card ──
            _AmountBreakdownCard(
              amount: amount,
              processingFee: processingFee,
              receiveAmount: receiveAmount,
            ),
            const SizedBox(height: 18),

            // ── To Bank Account ──
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 8),
              child: Text(
                'To Bank Account',
                style: GoogleFonts.inter(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w500,
                  color: AppColors.muted,
                ),
              ),
            ),
            _ConfirmBankCard(bankDetails: bankDetails),
            const SizedBox(height: 16),

            // ── Important information block ──
            _ImportantInfoBlock(
              points: const [
                'Withdrawals are processed within 1-3 working days.',
                'Ensure your bank details are correct before confirming.',
                'For any queries, please contact support.',
              ],
            ),
            const SizedBox(height: 22),

            // ── Commit buttons ──
            _PressableScale(
              onTap: onConfirm,
              child: Container(
                width: double.infinity,
                height: 54,
                decoration: BoxDecoration(
                  color: AppColors.primaryBrown,
                  borderRadius: BorderRadius.circular(14),
                  boxShadow: [
                    BoxShadow(
                      color: AppColors.primaryBrown.withValues(alpha: 0.22),
                      blurRadius: 14,
                      offset: const Offset(0, 5),
                    ),
                  ],
                ),
                child: Center(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AppIcon(
                        AppIcons.lock,
                        size: 14,
                        color: Colors.white,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'Confirm & Withdraw',
                        style: GoogleFonts.inter(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 6),
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onCancel,
              child: Container(
                width: double.infinity,
                height: 48,
                alignment: Alignment.center,
                child: Text(
                  'Cancel',
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: AppColors.muted,
                  ),
                ),
              ),
            ),
            SizedBox(height: paddingBottom + 8),
          ],
        ),
      ),
    );
  }
}

// Amount / fee / receive breakdown. Cream card with hairline border
// keeps it visually grouped without competing with the bank card
// directly beneath it.
class _AmountBreakdownCard extends StatelessWidget {
  final int amount;
  final int processingFee;
  final int receiveAmount;

  const _AmountBreakdownCard({
    required this.amount,
    required this.processingFee,
    required this.receiveAmount,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
      decoration: BoxDecoration(
        color: AppColors.surfaceCream,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: AppColors.muted.withValues(alpha: 0.10),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _BreakdownRow(
            label: 'Withdraw Amount',
            value: '₹${_formatInr(amount)}',
            emphasised: false,
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: Row(
                  children: [
                    Text(
                      'Processing Fee',
                      style: GoogleFonts.inter(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w500,
                        color: AppColors.muted,
                      ),
                    ),
                    const SizedBox(width: 6),
                    AppIcon(
                      AppIcons.info,
                      size: 12,
                      color: AppColors.muted.withValues(alpha: 0.6),
                    ),
                  ],
                ),
              ),
              Text(
                processingFee == 0 ? '₹0' : '₹${_formatInr(processingFee)}',
                style: GoogleFonts.inter(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                  color: AppColors.deepDarkBrown,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: _DashedDivider(),
          ),
          _BreakdownRow(
            label: 'You Will Receive',
            value: '₹${_formatInr(receiveAmount)}',
            emphasised: true,
          ),
        ],
      ),
    );
  }

  // Indian-style grouping (2,5,000) for readability. The CF takes
  // an integer rupee amount so we never have to worry about paise.
  static String _formatInr(int v) {
    final s = v.toString();
    if (s.length <= 3) return s;
    final last3 = s.substring(s.length - 3);
    final rest = s.substring(0, s.length - 3);
    final buf = StringBuffer();
    for (int i = 0; i < rest.length; i++) {
      // Insert commas every 2 chars from the right, working left.
      if (i > 0 && (rest.length - i) % 2 == 0) buf.write(',');
      buf.write(rest[i]);
    }
    return '${buf.toString()},$last3';
  }
}

class _BreakdownRow extends StatelessWidget {
  final String label;
  final String value;
  final bool emphasised;

  const _BreakdownRow({
    required this.label,
    required this.value,
    required this.emphasised,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: GoogleFonts.inter(
              fontSize: emphasised ? 14 : 13.5,
              fontWeight: emphasised ? FontWeight.w700 : FontWeight.w500,
              color: emphasised
                  ? AppColors.deepDarkBrown
                  : AppColors.muted,
            ),
          ),
        ),
        Text(
          value,
          style: GoogleFonts.inter(
            fontSize: emphasised ? 18 : 13.5,
            fontWeight: emphasised ? FontWeight.w800 : FontWeight.w600,
            letterSpacing: emphasised ? -0.3 : 0,
            color: emphasised
                ? AppColors.primaryBrown
                : AppColors.deepDarkBrown,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}

class _DashedDivider extends StatelessWidget {
  const _DashedDivider();

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        const dashWidth = 4.0;
        const dashGap = 4.0;
        final dashes = (constraints.maxWidth / (dashWidth + dashGap)).floor();
        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: List.generate(dashes, (_) {
            return SizedBox(
              width: dashWidth,
              height: 1,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: AppColors.muted.withValues(alpha: 0.28),
                ),
              ),
            );
          }),
        );
      },
    );
  }
}

// Compact bank account card used on the Confirm Withdrawal sheet.
// Shows the bank icon, bank name, masked account number (4-4-4-4),
// and account holder name. No actions — this is a display surface
// confirming where the money is going.
class _ConfirmBankCard extends StatelessWidget {
  final BankDetails bankDetails;

  const _ConfirmBankCard({required this.bankDetails});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surfaceWhite,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: AppColors.muted.withValues(alpha: 0.12),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.amberGold.withValues(alpha: 0.14),
            ),
            alignment: Alignment.center,
            child: AppIcon(
              AppIcons.bank,
              size: 20,
              color: AppColors.amberGold,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        bankDetails.bankName.isNotEmpty
                            ? bankDetails.bankName
                            : 'Linked Bank',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.inter(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: AppColors.primaryBrown,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.success.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          AppIcon(
                            AppIcons.check,
                            size: 9,
                            color: AppColors.success,
                          ),
                          const SizedBox(width: 3),
                          Text(
                            'Saved',
                            style: GoogleFonts.inter(
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              color: AppColors.success,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  formatMaskedAccountNumber(bankDetails.accountNumber),
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: AppColors.deepDarkBrown,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                if (bankDetails.accountHolderName.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    bankDetails.accountHolderName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.inter(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w400,
                      color: AppColors.muted,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// Important Information block — sets expectations on processing
// time and steers misuse cases to support without overwhelming the
// priest with legalese.
class _ImportantInfoBlock extends StatelessWidget {
  final List<String> points;

  const _ImportantInfoBlock({required this.points});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: AppColors.primaryBrown.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: AppColors.primaryBrown.withValues(alpha: 0.12),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              AppIcon(
                AppIcons.shield,
                size: 14,
                color: AppColors.primaryBrown,
              ),
              const SizedBox(width: 8),
              Text(
                'Important Information',
                style: GoogleFonts.inter(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: AppColors.primaryBrown,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ...points.map((p) => Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 7),
                      child: Container(
                        width: 4,
                        height: 4,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: AppColors.primaryBrown
                              .withValues(alpha: 0.55),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        p,
                        style: GoogleFonts.inter(
                          fontSize: 12,
                          fontWeight: FontWeight.w400,
                          height: 1.45,
                          color: AppColors.deepDarkBrown
                              .withValues(alpha: 0.78),
                        ),
                      ),
                    ),
                  ],
                ),
              )),
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
            child: const AppIcon(
              AppIcons.check,
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

// ─── Linked Bank card (wallet page, below hero) ────────────────

// Inline saved-bank surface. Renders the priest's linked account
// just under the balance hero so they can verify "where does my
// money land" without leaving the wallet page. Edit re-enters the
// bank-details form (pre-filled); Delete kicks off the confirmation
// dialog defined below.
class _LinkedBankCard extends StatelessWidget {
  final BankDetails details;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _LinkedBankCard({
    required this.details,
    required this.onEdit,
    required this.onDelete,
  });

  String get _accountTypeLabel {
    switch (details.accountType) {
      case 'savings':
        return 'Savings';
      case 'current':
        return 'Current';
      default:
        return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
      decoration: BoxDecoration(
        color: AppColors.surfaceWhite,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: AppColors.muted.withValues(alpha: 0.10),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 14,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header row — bank icon + name + Saved badge.
          Row(
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.amberGold.withValues(alpha: 0.14),
                ),
                alignment: Alignment.center,
                child: AppIcon(
                  AppIcons.bank,
                  size: 22,
                  color: AppColors.amberGold,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            details.bankName.isNotEmpty
                                ? details.bankName
                                : 'Linked Bank',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: GoogleFonts.inter(
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                              color: AppColors.primaryBrown,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: AppColors.success.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              AppIcon(
                                AppIcons.check,
                                size: 10,
                                color: AppColors.success,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                'Saved',
                                style: GoogleFonts.inter(
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w700,
                                  color: AppColors.success,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      details.accountHolderName.isNotEmpty
                          ? details.accountHolderName
                          : '—',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.inter(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w500,
                        color: AppColors.muted,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),

          // Masked account number — the field the priest cross-
          // checks against bank SMS / passbook. Grouped 4-4-4-4.
          Text(
            formatMaskedAccountNumber(details.accountNumber),
            style: GoogleFonts.inter(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.2,
              color: AppColors.deepDarkBrown,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(height: 12),

          // IFSC + Branch + Account Type — small meta row. Wraps
          // gracefully when branch name is long.
          Wrap(
            spacing: 18,
            runSpacing: 6,
            children: [
              _MetaLabel(
                label: 'IFSC',
                value: details.ifscCode.isNotEmpty
                    ? details.ifscCode
                    : '—',
              ),
              if (details.branchName.isNotEmpty)
                _MetaLabel(
                  label: 'Branch',
                  value: details.branchName,
                ),
              if (_accountTypeLabel.isNotEmpty)
                _MetaLabel(
                  label: 'Type',
                  value: _accountTypeLabel,
                ),
            ],
          ),
          const SizedBox(height: 16),
          Container(
            height: 1,
            color: AppColors.muted.withValues(alpha: 0.10),
          ),
          const SizedBox(height: 12),

          // Action row — Edit (brown) + Delete (muted red). Edit
          // gets the visual primary treatment because it's the more
          // common action; Delete sits quiet to dampen accidental
          // taps without hiding it.
          Row(
            children: [
              Expanded(
                child: _BankActionButton(
                  label: 'Edit',
                  icon: AppIcons.edit,
                  color: AppColors.primaryBrown,
                  onTap: onEdit,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _BankActionButton(
                  label: 'Delete',
                  icon: AppIcons.delete,
                  color: AppColors.errorRed,
                  onTap: onDelete,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _MetaLabel extends StatelessWidget {
  final String label;
  final String value;

  const _MetaLabel({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: GoogleFonts.inter(
            fontSize: 10.5,
            fontWeight: FontWeight.w500,
            letterSpacing: 0.4,
            color: AppColors.muted,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: GoogleFonts.inter(
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
            color: AppColors.deepDarkBrown,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}

// Tinted outline button used for the inline Edit / Delete actions
// on the Linked Bank card. Press-scale identical to the page's
// other CTAs so the visual rhythm is consistent.
class _BankActionButton extends StatefulWidget {
  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  const _BankActionButton({
    required this.label,
    required this.icon,
    required this.color,
    required this.onTap,
  });

  @override
  State<_BankActionButton> createState() => _BankActionButtonState();
}

class _BankActionButtonState extends State<_BankActionButton> {
  double _scale = 1.0;

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (_) => setState(() => _scale = 0.97),
      onPointerUp: (_) => setState(() => _scale = 1.0),
      onPointerCancel: (_) => setState(() => _scale = 1.0),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          HapticFeedback.selectionClick();
          widget.onTap();
        },
        child: AnimatedScale(
          scale: _scale,
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
          child: Container(
            height: 44,
            decoration: BoxDecoration(
              color: widget.color.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: widget.color.withValues(alpha: 0.22),
              ),
            ),
            alignment: Alignment.center,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                AppIcon(widget.icon, size: 14, color: widget.color),
                const SizedBox(width: 7),
                Text(
                  widget.label,
                  style: GoogleFonts.inter(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                    color: widget.color,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Delete confirmation dialog ────────────────────────────────

// Shown from the wallet page's Delete button. Adapts its body copy
// to the pending-withdrawal count: with pending rows the priest is
// told those will still process to the snapshotted bank, without
// any the message is the simpler "you won't be able to withdraw
// until you add one again". -1 means the count lookup failed and
// the copy softens to "could not check".
class _DeleteBankDialog extends StatelessWidget {
  final int pendingWithdrawals;

  const _DeleteBankDialog({required this.pendingWithdrawals});

  @override
  Widget build(BuildContext context) {
    final hasPending = pendingWithdrawals > 0;
    final lookupFailed = pendingWithdrawals < 0;

    return Dialog(
      backgroundColor: AppColors.surfaceWhite,
      insetPadding: const EdgeInsets.symmetric(horizontal: 32),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(22, 24, 22, 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.errorRed.withValues(alpha: 0.10),
                ),
                alignment: Alignment.center,
                child: AppIcon(
                  AppIcons.delete,
                  size: 26,
                  color: AppColors.errorRed,
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Remove bank account?',
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: AppColors.deepDarkBrown,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              hasPending
                  ? 'You have $pendingWithdrawals pending withdrawal'
                      '${pendingWithdrawals == 1 ? '' : 's'}. '
                      'Those will still be processed to this account. '
                      'New withdrawals will be blocked until you add an '
                      'account again.'
                  : lookupFailed
                      ? 'We could not check your pending withdrawals. '
                          'You can still remove the account — any in-flight '
                          'payouts will use the snapshotted details.'
                      : 'You will not be able to withdraw until you add '
                          'a bank account again.',
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(
                fontSize: 13,
                fontWeight: FontWeight.w400,
                height: 1.5,
                color: AppColors.muted,
              ),
            ),
            const SizedBox(height: 22),
            Row(
              children: [
                Expanded(
                  child: TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    style: TextButton.styleFrom(
                      foregroundColor: AppColors.deepDarkBrown,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: Text(
                      'Cancel',
                      style: GoogleFonts.inter(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: ElevatedButton(
                    onPressed: () => Navigator.pop(context, true),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.errorRed,
                      foregroundColor: Colors.white,
                      elevation: 0,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: Text(
                      'Remove',
                      style: GoogleFonts.inter(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
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
