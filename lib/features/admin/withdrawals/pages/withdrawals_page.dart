// Admin withdrawal monitor — the V1 payout dashboard. Admin reads
// the queue, manually transfers funds via their bank, then taps
// "Mark as Paid" to flip the row. Block + refund is the fraud path.
//
// This is the only admin screen with mutating actions on cards in
// the list itself (rather than buried in a detail page) because
// the workflow is high-volume — admin scrolls a queue, processes
// one, scrolls to the next. Burying the buttons would slow it down.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shimmer/shimmer.dart';

import 'package:gospel_vox/core/services/injection_container.dart';
import 'package:gospel_vox/core/theme/admin_colors.dart';
import 'package:gospel_vox/core/widgets/app_snackbar.dart';
import 'package:gospel_vox/features/admin/withdrawals/bloc/admin_withdrawals_cubit.dart';
import 'package:gospel_vox/features/admin/withdrawals/bloc/admin_withdrawals_state.dart';
import 'package:gospel_vox/features/admin/withdrawals/data/admin_withdrawal_model.dart';

const _kFilters = ['pending', 'paid', 'blocked', 'all'];

class WithdrawalsPage extends StatelessWidget {
  const WithdrawalsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.dark,
      ),
      child: BlocProvider<AdminWithdrawalsCubit>(
        create: (_) =>
            sl<AdminWithdrawalsCubit>()..loadWithdrawals('pending'),
        child: const _AdminWithdrawalsView(),
      ),
    );
  }
}

class _AdminWithdrawalsView extends StatefulWidget {
  const _AdminWithdrawalsView();

  @override
  State<_AdminWithdrawalsView> createState() =>
      _AdminWithdrawalsViewState();
}

class _AdminWithdrawalsViewState extends State<_AdminWithdrawalsView>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: _kFilters.length, vsync: this);
    _tabController.addListener(_onTabChanged);
  }

  void _onTabChanged() {
    if (_tabController.indexIsChanging) return;
    final filter = _kFilters[_tabController.index];
    context.read<AdminWithdrawalsCubit>().loadWithdrawals(filter);
  }

  @override
  void dispose() {
    _tabController.removeListener(_onTabChanged);
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AdminColors.background,
      appBar: _buildAppBar(),
      body: BlocConsumer<AdminWithdrawalsCubit, AdminWithdrawalsState>(
        listener: (ctx, state) {
          if (state is AdminWithdrawalsError) {
            AppSnackBar.error(ctx, state.message);
          }
        },
        builder: (ctx, state) {
          if (state is AdminWithdrawalsError) {
            return _ErrorView(
              message: state.message,
              onRetry: () => ctx
                  .read<AdminWithdrawalsCubit>()
                  .loadWithdrawals(_kFilters[_tabController.index]),
            );
          }
          if (state is AdminWithdrawalsLoaded) {
            return _WithdrawalsList(
              withdrawals: state.withdrawals,
              filter: state.filter,
              actionInProgressId: state.actionInProgressId,
              actionInProgressKind: state.actionInProgressKind,
              onRefresh: () => ctx
                  .read<AdminWithdrawalsCubit>()
                  .loadWithdrawals(state.filter),
              onMarkPaid: (w) => _confirmMarkPaid(ctx, w),
              onBlock: (w) => _confirmBlock(ctx, w),
            );
          }
          return const _ShimmerList();
        },
      ),
    );
  }

  PreferredSizeWidget _buildAppBar() {
    return AppBar(
      backgroundColor: Colors.white,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      systemOverlayStyle: SystemUiOverlayStyle.dark,
      leading: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          if (context.canPop()) {
            context.pop();
          } else {
            context.go('/admin');
          }
        },
        child: const Icon(
          Icons.arrow_back,
          color: AdminColors.textPrimary,
          size: 22,
        ),
      ),
      title: Text(
        'Withdrawals',
        style: GoogleFonts.inter(
          fontSize: 18,
          fontWeight: FontWeight.w600,
          color: AdminColors.textPrimary,
        ),
      ),
      centerTitle: false,
      bottom: PreferredSize(
        preferredSize: const Size.fromHeight(60),
        child: BlocBuilder<AdminWithdrawalsCubit, AdminWithdrawalsState>(
          buildWhen: (prev, curr) {
            if (prev.runtimeType != curr.runtimeType) return true;
            if (prev is AdminWithdrawalsLoaded &&
                curr is AdminWithdrawalsLoaded) {
              return prev.pendingCount != curr.pendingCount ||
                  prev.paidCount != curr.paidCount ||
                  prev.blockedCount != curr.blockedCount;
            }
            return false;
          },
          builder: (_, state) {
            final loaded = state is AdminWithdrawalsLoaded ? state : null;
            return _TabBarPill(
              controller: _tabController,
              pending: loaded?.pendingCount ?? 0,
              paid: loaded?.paidCount ?? 0,
              blocked: loaded?.blockedCount ?? 0,
            );
          },
        ),
      ),
    );
  }

  Future<void> _confirmMarkPaid(
      BuildContext ctx, AdminWithdrawalModel w) async {
    final cubit = ctx.read<AdminWithdrawalsCubit>();
    final confirmed = await showModalBottomSheet<bool>(
      context: ctx,
      backgroundColor: Colors.white,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetCtx) => _MarkPaidSheet(withdrawal: w),
    );
    if (confirmed != true) return;
    if (!mounted) return;

    final ok = await cubit.markAsPaid(w.id);
    if (!mounted) return;
    if (ok) {
      AppSnackBar.success(context, 'Marked as paid.');
    } else {
      AppSnackBar.error(context, 'Could not update. Try again.');
    }
  }

  Future<void> _confirmBlock(
      BuildContext ctx, AdminWithdrawalModel w) async {
    final cubit = ctx.read<AdminWithdrawalsCubit>();
    final confirmed = await showModalBottomSheet<bool>(
      context: ctx,
      backgroundColor: Colors.white,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetCtx) => _BlockSheet(withdrawal: w),
    );
    if (confirmed != true) return;
    if (!mounted) return;

    final ok = await cubit.blockWithdrawal(
      withdrawalId: w.id,
      priestId: w.priestId,
      amount: w.amount,
    );
    if (!mounted) return;
    if (ok) {
      AppSnackBar.success(
          context, 'Withdrawal blocked, amount refunded.');
    } else {
      AppSnackBar.error(context, 'Could not block. Try again.');
    }
  }
}

// ─── Tab bar ────────────────────────────────────────────────────

class _TabBarPill extends StatelessWidget {
  final TabController controller;
  final int pending;
  final int paid;
  final int blocked;

  const _TabBarPill({
    required this.controller,
    required this.pending,
    required this.paid,
    required this.blocked,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Container(
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: AdminColors.inputBackground,
          borderRadius: BorderRadius.circular(10),
        ),
        child: TabBar(
          controller: controller,
          indicator: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(8),
            boxShadow: [
              BoxShadow(
                blurRadius: 4,
                offset: const Offset(0, 1),
                color: Colors.black.withValues(alpha: 0.06),
              ),
            ],
          ),
          indicatorSize: TabBarIndicatorSize.tab,
          dividerColor: Colors.transparent,
          labelPadding: EdgeInsets.zero,
          labelColor: AdminColors.textPrimary,
          // 12px to fit four tabs at narrow widths without overflow.
          labelStyle: GoogleFonts.inter(
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
          unselectedLabelColor: AdminColors.textMuted,
          unselectedLabelStyle: GoogleFonts.inter(
            fontSize: 12,
            fontWeight: FontWeight.w500,
          ),
          tabs: [
            _TabLabel(
                label: 'Pending', count: pending, color: AdminColors.warning),
            _TabLabel(
                label: 'Paid', count: paid, color: AdminColors.success),
            _TabLabel(
                label: 'Blocked',
                count: blocked,
                color: AdminColors.error),
            const _TabLabel(label: 'All', count: 0),
          ],
        ),
      ),
    );
  }
}

class _TabLabel extends StatelessWidget {
  final String label;
  final int count;
  final Color? color;
  const _TabLabel({
    required this.label,
    required this.count,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Tab(
      height: 38,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(label, overflow: TextOverflow.ellipsis),
          ),
          if (count > 0) ...[
            const SizedBox(width: 5),
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 5,
                vertical: 2,
              ),
              decoration: BoxDecoration(
                color: color ?? AdminColors.textLight,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                count > 99 ? '99+' : count.toString(),
                style: GoogleFonts.inter(
                  fontSize: 9,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ─── List ──────────────────────────────────────────────────────

class _WithdrawalsList extends StatelessWidget {
  final List<AdminWithdrawalModel> withdrawals;
  final String filter;
  final String? actionInProgressId;
  final String? actionInProgressKind;
  final Future<void> Function() onRefresh;
  final void Function(AdminWithdrawalModel) onMarkPaid;
  final void Function(AdminWithdrawalModel) onBlock;

  const _WithdrawalsList({
    required this.withdrawals,
    required this.filter,
    required this.actionInProgressId,
    required this.actionInProgressKind,
    required this.onRefresh,
    required this.onMarkPaid,
    required this.onBlock,
  });

  @override
  Widget build(BuildContext context) {
    if (withdrawals.isEmpty) {
      return RefreshIndicator(
        color: AdminColors.brandBrown,
        onRefresh: onRefresh,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(
            parent: ClampingScrollPhysics(),
          ),
          children: [
            SizedBox(
              height: MediaQuery.of(context).size.height * 0.6,
              child: _EmptyState(filter: filter),
            ),
          ],
        ),
      );
    }
    return RefreshIndicator(
      color: AdminColors.brandBrown,
      onRefresh: onRefresh,
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(
          parent: ClampingScrollPhysics(),
        ),
        padding: const EdgeInsets.fromLTRB(0, 12, 0, 24),
        itemCount: withdrawals.length,
        itemBuilder: (_, i) {
          final w = withdrawals[i];
          final isPaying = actionInProgressId == w.id &&
              actionInProgressKind == 'paid';
          final isBlocking = actionInProgressId == w.id &&
              actionInProgressKind == 'blocked';
          return _WithdrawalCard(
            withdrawal: w,
            isPaying: isPaying,
            isBlocking: isBlocking,
            onMarkPaid: () => onMarkPaid(w),
            onBlock: () => onBlock(w),
          );
        },
      ),
    );
  }
}

// ─── Withdrawal card ───────────────────────────────────────────

class _WithdrawalCard extends StatelessWidget {
  final AdminWithdrawalModel withdrawal;
  final bool isPaying;
  final bool isBlocking;
  final VoidCallback onMarkPaid;
  final VoidCallback onBlock;

  const _WithdrawalCard({
    required this.withdrawal,
    required this.isPaying,
    required this.isBlocking,
    required this.onMarkPaid,
    required this.onBlock,
  });

  @override
  Widget build(BuildContext context) {
    final w = withdrawal;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      padding: const EdgeInsets.all(16),
      decoration: AdminColors.cardDecoration,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '₹${w.amount}',
                  style: GoogleFonts.inter(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: AdminColors.textPrimary,
                  ),
                ),
              ),
              _WithdrawalStatusBadge(status: w.status),
            ],
          ),
          const SizedBox(height: 8),
          _IconRow(
            icon: Icons.account_balance_outlined,
            text: w.bankName.isEmpty
                ? 'A/c ••••${w.lastFourAccount}'
                : '${w.bankName} · A/c ••••${w.lastFourAccount}',
          ),
          const SizedBox(height: 4),
          _IconRow(
            icon: Icons.person_outline,
            text: w.bankAccountName.isEmpty
                ? 'No account holder'
                : w.bankAccountName,
          ),
          const SizedBox(height: 4),
          _IconRow(
            icon: Icons.tag,
            text: 'IFSC: ${w.bankIfscCode.isEmpty ? '—' : w.bankIfscCode}',
          ),
          if ((w.upiId ?? '').isNotEmpty) ...[
            const SizedBox(height: 4),
            _IconRow(
              icon: Icons.qr_code,
              text: 'UPI: ${w.upiId!}',
            ),
          ],
          const SizedBox(height: 8),
          Text(
            w.formattedCreatedAt.isEmpty
                ? 'Requested recently'
                : 'Requested ${w.formattedCreatedAt}',
            style: GoogleFonts.inter(
              fontSize: 11,
              fontWeight: FontWeight.w400,
              color: AdminColors.textLight,
            ),
          ),
          if (w.isPending) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _ActionButton(
                    label: 'Block',
                    foreground: AdminColors.error,
                    background: Colors.white,
                    border: AdminColors.error,
                    loading: isBlocking,
                    disabled: isPaying,
                    onTap: onBlock,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  flex: 2,
                  child: _ActionButton(
                    label: 'Mark as Paid',
                    foreground: Colors.white,
                    background: AdminColors.success,
                    border: AdminColors.success,
                    loading: isPaying,
                    disabled: isBlocking,
                    onTap: onMarkPaid,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _IconRow extends StatelessWidget {
  final IconData icon;
  final String text;
  const _IconRow({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 16, color: AdminColors.textLight),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: GoogleFonts.inter(
              fontSize: 12,
              fontWeight: FontWeight.w400,
              color: AdminColors.textMuted,
            ),
          ),
        ),
      ],
    );
  }
}

class _WithdrawalStatusBadge extends StatelessWidget {
  final String status;
  const _WithdrawalStatusBadge({required this.status});

  @override
  Widget build(BuildContext context) {
    final (bg, fg, label) = switch (status) {
      'paid' => (AdminColors.successBg, AdminColors.success, 'Paid'),
      'blocked' => (AdminColors.errorBg, AdminColors.error, 'Blocked'),
      _ => (AdminColors.warningBg, AdminColors.warning, 'Pending'),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: GoogleFonts.inter(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: fg,
        ),
      ),
    );
  }
}

// ─── Action button ─────────────────────────────────────────────

class _ActionButton extends StatefulWidget {
  final String label;
  final Color foreground;
  final Color background;
  final Color border;
  final bool loading;
  final bool disabled;
  final VoidCallback onTap;

  const _ActionButton({
    required this.label,
    required this.foreground,
    required this.background,
    required this.border,
    required this.loading,
    required this.disabled,
    required this.onTap,
  });

  @override
  State<_ActionButton> createState() => _ActionButtonState();
}

class _ActionButtonState extends State<_ActionButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final disabled = widget.disabled || widget.loading;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown:
          disabled ? null : (_) => setState(() => _pressed = true),
      onTapUp:
          disabled ? null : (_) => setState(() => _pressed = false),
      onTapCancel:
          disabled ? null : () => setState(() => _pressed = false),
      onTap: disabled ? null : widget.onTap,
      child: AnimatedScale(
        scale: _pressed ? 0.97 : 1.0,
        duration: const Duration(milliseconds: 120),
        child: Container(
          height: 40,
          decoration: BoxDecoration(
            color: disabled
                ? widget.background.withValues(alpha: 0.5)
                : widget.background,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: widget.border, width: 1),
          ),
          child: Center(
            child: widget.loading
                ? SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation(
                        widget.foreground,
                      ),
                    ),
                  )
                : Text(
                    widget.label,
                    style: GoogleFonts.inter(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: widget.foreground,
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}

// ─── Confirmation sheets ───────────────────────────────────────

// The Mark-as-Paid sheet is the only place in the app that reveals
// the full bank account number. The card list intentionally masks
// to ••••1234 for casual viewing safety; admin actually doing the
// transfer needs the full digits to paste into their banking app.
// A copy-to-clipboard affordance sits next to the number so the
// admin doesn't have to long-press-select on a small screen.
class _MarkPaidSheet extends StatelessWidget {
  final AdminWithdrawalModel withdrawal;
  const _MarkPaidSheet({required this.withdrawal});

  @override
  Widget build(BuildContext context) {
    final w = withdrawal;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color:
                        AdminColors.textLight.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Text(
                'Mark as Paid?',
                style: GoogleFonts.inter(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: AdminColors.textPrimary,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Use these details to send ₹${w.amount}, then confirm '
                'below once the bank transfer has been sent.',
                style: GoogleFonts.inter(
                  fontSize: 13,
                  fontWeight: FontWeight.w400,
                  color: AdminColors.textBody,
                  height: 1.45,
                ),
              ),
              const SizedBox(height: 16),
              _PayoutDetails(withdrawal: w),
              const SizedBox(height: 12),
              Text(
                'This action cannot be undone from the app.',
                style: GoogleFonts.inter(
                  fontSize: 12,
                  fontWeight: FontWeight.w400,
                  color: AdminColors.textMuted,
                ),
              ),
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(
                    child: _SheetButton(
                      label: 'Cancel',
                      foreground: AdminColors.textBody,
                      background: AdminColors.inputBackground,
                      border: AdminColors.borderLight,
                      onTap: () => Navigator.of(context).pop(false),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    flex: 2,
                    child: _SheetButton(
                      label: "Yes, I've Paid",
                      foreground: Colors.white,
                      background: AdminColors.success,
                      border: AdminColors.success,
                      onTap: () => Navigator.of(context).pop(true),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// Payout details panel inside the confirm sheet. Each row that
// represents a value the admin will copy into their banking app
// gets its own copy button — this is the single screen where
// fast, mistake-free copy-paste of bank fields actually matters.
class _PayoutDetails extends StatelessWidget {
  final AdminWithdrawalModel withdrawal;
  const _PayoutDetails({required this.withdrawal});

  @override
  Widget build(BuildContext context) {
    final w = withdrawal;
    return Container(
      decoration: BoxDecoration(
        color: AdminColors.inputBackground,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AdminColors.borderLight),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      child: Column(
        children: [
          _PayoutRow(
            label: 'Amount',
            value: '₹${w.amount}',
            copyText: w.amount.toString(),
          ),
          const _PayoutDivider(),
          _PayoutRow(
            label: 'Account holder',
            value: w.bankAccountName.isEmpty ? '—' : w.bankAccountName,
            copyText: w.bankAccountName.isEmpty ? null : w.bankAccountName,
          ),
          const _PayoutDivider(),
          _PayoutRow(
            label: 'Bank',
            value: w.bankName.isEmpty ? '—' : w.bankName,
            copyText: w.bankName.isEmpty ? null : w.bankName,
          ),
          const _PayoutDivider(),
          _PayoutRow(
            label: 'Account number',
            value: w.bankAccountNumber.isEmpty
                ? '—'
                : w.bankAccountNumber,
            copyText: w.bankAccountNumber.isEmpty
                ? null
                : w.bankAccountNumber,
            monospace: true,
          ),
          const _PayoutDivider(),
          _PayoutRow(
            label: 'IFSC',
            value: w.bankIfscCode.isEmpty ? '—' : w.bankIfscCode,
            copyText: w.bankIfscCode.isEmpty ? null : w.bankIfscCode,
            monospace: true,
          ),
          if ((w.upiId ?? '').isNotEmpty) ...[
            const _PayoutDivider(),
            _PayoutRow(
              label: 'UPI',
              value: w.upiId!,
              copyText: w.upiId,
            ),
          ],
        ],
      ),
    );
  }
}

class _PayoutDivider extends StatelessWidget {
  const _PayoutDivider();

  @override
  Widget build(BuildContext context) =>
      Container(height: 1, color: AdminColors.borderLight);
}

class _PayoutRow extends StatefulWidget {
  final String label;
  final String value;
  // Null disables the copy affordance — used for empty/placeholder
  // rows so the admin doesn't tap and copy "—".
  final String? copyText;
  final bool monospace;

  const _PayoutRow({
    required this.label,
    required this.value,
    required this.copyText,
    this.monospace = false,
  });

  @override
  State<_PayoutRow> createState() => _PayoutRowState();
}

class _PayoutRowState extends State<_PayoutRow> {
  bool _justCopied = false;
  Timer? _resetTimer;

  @override
  void dispose() {
    _resetTimer?.cancel();
    super.dispose();
  }

  Future<void> _copy() async {
    final text = widget.copyText;
    if (text == null) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    setState(() => _justCopied = true);
    _resetTimer?.cancel();
    // Brief visual confirmation; long enough to register, short
    // enough not to lock the icon if admin copies several fields
    // in quick succession.
    _resetTimer = Timer(const Duration(milliseconds: 1500), () {
      if (!mounted) return;
      setState(() => _justCopied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final canCopy = widget.copyText != null;
    final valueStyle = widget.monospace
        ? GoogleFonts.robotoMono(
            fontSize: 13,
            fontWeight: FontWeight.w500,
            color: AdminColors.textPrimary,
            letterSpacing: 0.3,
          )
        : GoogleFonts.inter(
            fontSize: 13,
            fontWeight: FontWeight.w500,
            color: AdminColors.textPrimary,
          );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 110,
            child: Text(
              widget.label,
              style: GoogleFonts.inter(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: AdminColors.textMuted,
                letterSpacing: 0.3,
              ),
            ),
          ),
          Expanded(
            child: Text(
              widget.value,
              style: valueStyle,
              softWrap: true,
            ),
          ),
          if (canCopy) ...[
            const SizedBox(width: 8),
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _copy,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: _justCopied
                      ? AdminColors.successBg
                      : Colors.white,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: _justCopied
                        ? AdminColors.success
                        : AdminColors.borderLight,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _justCopied
                          ? Icons.check_rounded
                          : Icons.copy_rounded,
                      size: 13,
                      color: _justCopied
                          ? AdminColors.success
                          : AdminColors.textMuted,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      _justCopied ? 'Copied' : 'Copy',
                      style: GoogleFonts.inter(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: _justCopied
                            ? AdminColors.success
                            : AdminColors.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _BlockSheet extends StatelessWidget {
  final AdminWithdrawalModel withdrawal;
  const _BlockSheet({required this.withdrawal});

  @override
  Widget build(BuildContext context) {
    final w = withdrawal;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color:
                      AdminColors.textLight.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              'Block Withdrawal?',
              style: GoogleFonts.inter(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: AdminColors.error,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              'This will refund ₹${w.amount} back to the priest’s '
              'wallet and flag this withdrawal as suspicious.',
              style: GoogleFonts.inter(
                fontSize: 14,
                fontWeight: FontWeight.w400,
                color: AdminColors.textBody,
                height: 1.45,
              ),
            ),
            const SizedBox(height: 24),
            Row(
              children: [
                Expanded(
                  child: _SheetButton(
                    label: 'Cancel',
                    foreground: AdminColors.textBody,
                    background: AdminColors.inputBackground,
                    border: AdminColors.borderLight,
                    onTap: () => Navigator.of(context).pop(false),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  flex: 2,
                  child: _SheetButton(
                    label: 'Block',
                    foreground: Colors.white,
                    background: AdminColors.error,
                    border: AdminColors.error,
                    onTap: () => Navigator.of(context).pop(true),
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

class _SheetButton extends StatefulWidget {
  final String label;
  final Color foreground;
  final Color background;
  final Color border;
  final VoidCallback onTap;

  const _SheetButton({
    required this.label,
    required this.foreground,
    required this.background,
    required this.border,
    required this.onTap,
  });

  @override
  State<_SheetButton> createState() => _SheetButtonState();
}

class _SheetButtonState extends State<_SheetButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _pressed ? 0.97 : 1.0,
        duration: const Duration(milliseconds: 120),
        child: Container(
          height: 46,
          decoration: BoxDecoration(
            color: widget.background,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: widget.border, width: 1),
          ),
          child: Center(
            child: Text(
              widget.label,
              style: GoogleFonts.inter(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: widget.foreground,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Shimmer / empty / error ───────────────────────────────────

class _ShimmerList extends StatelessWidget {
  const _ShimmerList();

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(0, 12, 0, 24),
      itemCount: 4,
      itemBuilder: (_, _) => Container(
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        padding: const EdgeInsets.all(16),
        decoration: AdminColors.cardDecoration,
        child: Shimmer.fromColors(
          baseColor: AdminColors.inputBackground,
          highlightColor: Colors.white,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                height: 18,
                width: 120,
                decoration: BoxDecoration(
                  color: AdminColors.inputBackground,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
              const SizedBox(height: 10),
              Container(
                height: 12,
                width: 220,
                decoration: BoxDecoration(
                  color: AdminColors.inputBackground,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
              const SizedBox(height: 6),
              Container(
                height: 12,
                width: 160,
                decoration: BoxDecoration(
                  color: AdminColors.inputBackground,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final String filter;
  const _EmptyState({required this.filter});

  @override
  Widget build(BuildContext context) {
    final (icon, title, body) = switch (filter) {
      'pending' => (
          Icons.inbox_outlined,
          'No pending withdrawals',
          'New withdrawal requests will appear here',
        ),
      'paid' => (
          Icons.task_alt,
          'No paid withdrawals yet',
          'Payouts you mark as paid will appear here',
        ),
      'blocked' => (
          Icons.block_outlined,
          'No blocked withdrawals',
          'Blocked payouts will appear here',
        ),
      _ => (
          Icons.payments_outlined,
          'No withdrawals yet',
          'Withdrawals across every status will appear here',
        ),
    };

    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 48,
              color: AdminColors.textLight.withValues(alpha: 0.4),
            ),
            const SizedBox(height: 16),
            Text(
              title,
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(
                fontSize: 15,
                fontWeight: FontWeight.w500,
                color: AdminColors.textMuted,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              body,
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(
                fontSize: 13,
                fontWeight: FontWeight.w400,
                color: AdminColors.textLight,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorView({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(
              Icons.error_outline,
              size: 48,
              color: AdminColors.error,
            ),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: AdminColors.textMuted,
              ),
            ),
            const SizedBox(height: 20),
            GestureDetector(
              onTap: onRetry,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: AdminColors.brandBrown,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  'Retry',
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
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
