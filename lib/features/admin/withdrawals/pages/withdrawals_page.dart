// Admin withdrawal monitor — the manual payout dashboard.
//
// Flow the admin works:
//   1. Pending tab lists new requests. Export -> a CSV of every
//      pending payout (name, country, currency, amount, full bank
//      routing details) to hand to the bank, then optionally move them
//      all to Processing in one tap.
//   2. Per row, "Manage Payout" opens the applicable lifecycle actions:
//      Mark Processing, Mark Sent (records the bank reference), Put On
//      Hold (with a reason), or Block & Refund.
//   3. Every status change fires the onWithdrawalStatus Cloud Function,
//      which notifies the priest — so the admin never has to message
//      anyone manually.
//
// The money never moves in-app: this screen only collects/moves data
// and records what the admin did off-app at the bank.

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
import 'package:gospel_vox/features/admin/withdrawals/data/withdrawal_export.dart';
import 'package:gospel_vox/features/admin/withdrawals/data/withdrawal_share.dart';
import 'package:gospel_vox/features/admin/withdrawals/pages/withdrawal_detail_page.dart';
import 'package:gospel_vox/core/widgets/app_icons.dart';
import 'package:gospel_vox/core/widgets/app_loading_widget.dart';

const _kFilters = [
  'pending',
  'processing',
  'paid',
  'on_hold',
  'blocked',
  'all',
];

// Actions the Manage sheet can return.
enum _PayoutAction { processing, sent, onHold, block }

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
  State<_AdminWithdrawalsView> createState() => _AdminWithdrawalsViewState();
}

class _AdminWithdrawalsViewState extends State<_AdminWithdrawalsView>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  // Client-side search over the loaded list (name / account / IBAN).
  String _search = '';
  // Owned here so the text survives BlocConsumer rebuilds (a per-row
  // action emits new state, which would otherwise reset an uncontrolled
  // field mid-typing).
  final TextEditingController _searchController = TextEditingController();

  // Date filter: 'all' or 'today' (the day's batch).
  String _dateFilter = 'all';

  // Multi-select for bulk actions (bulk Mark-Sent with one reference,
  // bulk On-Hold for a bounced batch).
  bool _selectionMode = false;
  final Set<String> _selectedIds = {};

  // Keep only today's rows when the 'today' filter is on.
  List<AdminWithdrawalModel> _applyDateFilter(
      List<AdminWithdrawalModel> all) {
    if (_dateFilter != 'today') return all;
    final now = DateTime.now();
    return all.where((w) {
      final c = w.createdAt;
      return c != null &&
          c.year == now.year &&
          c.month == now.month &&
          c.day == now.day;
    }).toList();
  }

  void _enterSelection() => setState(() {
        _selectionMode = true;
        _selectedIds.clear();
      });

  void _exitSelection() => setState(() {
        _selectionMode = false;
        _selectedIds.clear();
      });

  void _toggleSelect(String id) => setState(() {
        if (!_selectedIds.add(id)) _selectedIds.remove(id);
      });

  void _selectAll(List<AdminWithdrawalModel> visible) => setState(() {
        _selectedIds
          ..clear()
          ..addAll(visible.map((w) => w.id));
      });

  // Bulk actions only make sense where rows are still actionable.
  bool _bulkAllowed(String filter) =>
      filter == 'pending' || filter == 'processing' || filter == 'on_hold';

  // Filters the loaded list by priest name, account number, IBAN, or
  // priest id. Empty query returns everything.
  List<AdminWithdrawalModel> _applySearch(List<AdminWithdrawalModel> all) {
    final q = _search.trim().toLowerCase();
    if (q.isEmpty) return all;
    return all.where((w) {
      return w.bankAccountName.toLowerCase().contains(q) ||
          w.bankAccountNumber.toLowerCase().contains(q) ||
          w.iban.toLowerCase().contains(q) ||
          w.priestId.toLowerCase().contains(q);
    }).toList();
  }

  void _openDetail(AdminWithdrawalModel w) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => WithdrawalDetailPage(withdrawal: w)),
    );
  }

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: _kFilters.length, vsync: this);
    _tabController.addListener(_onTabChanged);
  }

  void _onTabChanged() {
    if (_tabController.indexIsChanging) return;
    if (_selectionMode) _exitSelection();
    final filter = _kFilters[_tabController.index];
    context.read<AdminWithdrawalsCubit>().loadWithdrawals(filter);
  }

  @override
  void dispose() {
    _tabController.removeListener(_onTabChanged);
    _tabController.dispose();
    _searchController.dispose();
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
            final filtered =
                _applyDateFilter(_applySearch(state.withdrawals));
            final bulkAllowed = _bulkAllowed(state.filter);
            return Column(
              children: [
                _SearchBar(
                  controller: _searchController,
                  onChanged: (v) => setState(() => _search = v),
                ),
                _ControlsRow(
                  dateFilter: _dateFilter,
                  onDateFilter: (v) => setState(() => _dateFilter = v),
                  showSelect: bulkAllowed && filtered.isNotEmpty,
                  selectionMode: _selectionMode,
                  onToggleSelectionMode:
                      _selectionMode ? _exitSelection : _enterSelection,
                ),
                Expanded(
                  child: _WithdrawalsList(
                    withdrawals: filtered,
                    filter: state.filter,
                    searching: _search.trim().isNotEmpty ||
                        _dateFilter != 'all',
                    actionInProgressId: state.actionInProgressId,
                    selectionMode: _selectionMode && bulkAllowed,
                    selectedIds: _selectedIds,
                    onToggleSelect: _toggleSelect,
                    onRefresh: () => ctx
                        .read<AdminWithdrawalsCubit>()
                        .loadWithdrawals(state.filter),
                    onManage: (w) => _openManage(ctx, w),
                    onOpen: _openDetail,
                  ),
                ),
                if (_selectionMode && bulkAllowed)
                  () {
                    // Only ever act on rows that are CURRENTLY visible —
                    // a selected row that left the tab/filter (live stream
                    // moved it, or search/date narrowed) is excluded, so a
                    // bulk write never touches a row the admin can't see.
                    final filteredIds = filtered.map((w) => w.id).toSet();
                    final visible =
                        _selectedIds.where(filteredIds.contains).toList();
                    return _BulkBar(
                      count: visible.length,
                      allSelected: filtered.isNotEmpty &&
                          visible.length == filtered.length,
                      onSelectAll: () => _selectAll(filtered),
                      onSent: () => _bulkSent(ctx, visible),
                      onHold: () => _bulkHold(ctx, visible),
                    );
                  }(),
              ],
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
        child: const AppIcon(
          AppIcons.back,
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
      actions: [
        // Export is only meaningful on the Pending tab — it's the batch
        // the admin hands to the bank.
        BlocBuilder<AdminWithdrawalsCubit, AdminWithdrawalsState>(
          builder: (ctx, state) {
            final loaded =
                state is AdminWithdrawalsLoaded ? state : null;
            // Export is available on every tab now — not just Pending —
            // so the admin can download any view (paid, all, a search
            // result) anytime, not only at request time.
            final showExport =
                loaded != null && loaded.withdrawals.isNotEmpty;
            if (!showExport) return const SizedBox.shrink();
            return Padding(
              padding: const EdgeInsets.only(right: 8),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => _export(
                    _applyDateFilter(_applySearch(loaded.withdrawals)),
                    loaded.filter),
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const AppIcon(AppIcons.download,
                          size: 16, color: AdminColors.brandBrown),
                      const SizedBox(width: 6),
                      Text(
                        'Export',
                        style: GoogleFonts.inter(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: AdminColors.brandBrown,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ],
      bottom: PreferredSize(
        preferredSize: const Size.fromHeight(52),
        child: BlocBuilder<AdminWithdrawalsCubit, AdminWithdrawalsState>(
          buildWhen: (prev, curr) => true,
          builder: (_, state) {
            final loaded = state is AdminWithdrawalsLoaded ? state : null;
            return _ScrollableTabs(
              controller: _tabController,
              pending: loaded?.pendingCount ?? 0,
              processing: loaded?.processingCount ?? 0,
              paid: loaded?.paidCount ?? 0,
              onHold: loaded?.onHoldCount ?? 0,
              blocked: loaded?.blockedCount ?? 0,
            );
          },
        ),
      ),
    );
  }

  // ── Manage flow ──

  Future<void> _openManage(
      BuildContext ctx, AdminWithdrawalModel w) async {
    final cubit = ctx.read<AdminWithdrawalsCubit>();
    final action = await showModalBottomSheet<_PayoutAction>(
      context: ctx,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _ManageSheet(withdrawal: w),
    );
    if (action == null || !mounted) return;

    switch (action) {
      case _PayoutAction.processing:
        await _confirmProcessing(cubit, w);
      case _PayoutAction.sent:
        await _markSent(cubit, w);
      case _PayoutAction.onHold:
        await _putOnHold(cubit, w);
      case _PayoutAction.block:
        await _block(cubit, w);
    }
  }

  Future<void> _confirmProcessing(
      AdminWithdrawalsCubit cubit, AdminWithdrawalModel w) async {
    final ok = await cubit.markProcessing(w.id);
    if (!mounted) return;
    _toast(ok, 'Moved to Processing.', 'Could not update. Try again.');
  }

  Future<void> _markSent(
      AdminWithdrawalsCubit cubit, AdminWithdrawalModel w) async {
    // Show the priest's CURRENT bank details (reflects an on-hold
    // correction); fall back to the request snapshot only if they've
    // since cleared their details, so a payout is never undeliverable.
    final current = await cubit.resolveCurrentPayout(w);
    if (!mounted) return;
    final result = await showModalBottomSheet<(String, String)>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _MarkSentSheet(
        withdrawal: current ?? w,
        usingRequestSnapshot: current == null,
      ),
    );
    if (result == null || !mounted) return;
    final ok = await cubit.markSent(
      withdrawalId: w.id,
      reference: result.$1,
      transactionId: result.$2,
    );
    if (!mounted) return;
    _toast(ok, 'Marked as sent.', 'Could not update. Try again.');
  }

  Future<void> _putOnHold(
      AdminWithdrawalsCubit cubit, AdminWithdrawalModel w) async {
    final reason = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _OnHoldSheet(withdrawal: w),
    );
    if (reason == null || !mounted) return;
    final ok = await cubit.putOnHold(withdrawalId: w.id, reason: reason);
    if (!mounted) return;
    _toast(ok, 'Put on hold.', 'Could not update. Try again.');
  }

  Future<void> _block(
      AdminWithdrawalsCubit cubit, AdminWithdrawalModel w) async {
    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: Colors.white,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _BlockSheet(withdrawal: w),
    );
    if (confirmed != true || !mounted) return;
    final ok = await cubit.blockWithdrawal(
      withdrawalId: w.id,
      priestId: w.priestId,
      amount: w.amount,
    );
    if (!mounted) return;
    _toast(ok, 'Withdrawal blocked, amount refunded.',
        'Could not block. Try again.');
  }

  void _toast(bool ok, String success, String failure) {
    if (ok) {
      AppSnackBar.success(context, success);
    } else {
      AppSnackBar.error(context, failure);
    }
  }

  // ── Bulk actions ──

  Future<void> _bulkSent(BuildContext ctx, List<String> ids) async {
    if (ids.isEmpty) {
      AppSnackBar.error(context, 'Select at least one visible payout.');
      return;
    }
    final cubit = ctx.read<AdminWithdrawalsCubit>();
    final reference = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _BulkInputSheet(
        title: 'Mark ${ids.length} as Sent',
        subtitle: 'Enter the ONE bank reference for this batch (e.g. the '
            'UTR the bank returned). Every selected priest gets it.',
        fieldLabel: 'Bank reference / transaction ID',
        hint: 'e.g. UTR / wire ref',
        mono: true,
        confirmLabel: 'Confirm Sent',
        confirmColor: AdminColors.success,
      ),
    );
    if (reference == null || !mounted) return;
    final ok = await cubit.markSentBatch(ids, reference);
    if (!mounted) return;
    if (ok) {
      _exitSelection();
      AppSnackBar.success(context, 'Marked ${ids.length} as sent.');
    } else {
      AppSnackBar.error(context, 'Could not update some rows. Try again.');
    }
  }

  Future<void> _bulkHold(BuildContext ctx, List<String> ids) async {
    if (ids.isEmpty) {
      AppSnackBar.error(context, 'Select at least one visible payout.');
      return;
    }
    final cubit = ctx.read<AdminWithdrawalsCubit>();
    final reason = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _BulkInputSheet(
        title: 'Put ${ids.length} On Hold',
        subtitle: 'Each selected priest sees this reason and a prompt to '
            'fix their bank details. No money is refunded.',
        fieldLabel: 'Reason shown to the priest',
        hint: 'e.g. Bank rejected the transfer',
        presets: const [
          'Bank rejected the transfer',
          'Account number invalid',
          'Name does not match account',
        ],
        confirmLabel: 'Put On Hold',
        confirmColor: const Color(0xFFC2410C),
      ),
    );
    if (reason == null || !mounted) return;
    final ok = await cubit.putOnHoldBatch(ids, reason);
    if (!mounted) return;
    if (ok) {
      _exitSelection();
      AppSnackBar.success(context, 'Put ${ids.length} on hold.');
    } else {
      AppSnackBar.error(context, 'Could not update. Try again.');
    }
  }

  // ── Export ──

  // Exports the currently-shown list (any tab / search result) as a CSV
  // via share_plus, then — only on the Pending tab — offers to advance
  // the exported batch to Processing so each priest sees movement.
  Future<void> _export(
      List<AdminWithdrawalModel> rows, String filter) async {
    if (rows.isEmpty) return;
    final cubit = context.read<AdminWithdrawalsCubit>();
    final result = await shareCsvFile(
      csv: buildWithdrawalsCsv(rows),
      filename: 'withdrawals_$filter.csv',
      subject: 'Withdrawals ($filter)',
    );
    if (!mounted) return;
    if (result == CsvShareResult.copiedToClipboard) {
      AppSnackBar.success(context, 'Share unavailable — CSV copied');
    } else if (result == CsvShareResult.failed) {
      AppSnackBar.error(context, 'Could not export.');
      return;
    }

    // Only a freshly-exported Pending batch is offered the move to
    // Processing (the others are already past that stage).
    if (filter != 'pending') return;
    final move = await showDialog<bool>(
      context: context,
      barrierColor: AdminColors.textPrimary.withValues(alpha: 0.35),
      builder: (_) => _MarkProcessingDialog(count: rows.length),
    );
    if (move != true || !mounted) return;
    final ok =
        await cubit.markProcessingBatch(rows.map((w) => w.id).toList());
    if (!mounted) return;
    _toast(ok, 'Moved ${rows.length} to Processing.',
        'Could not update some rows. Try again.');
  }
}

// ─── Scrollable tabs ────────────────────────────────────────────

class _ScrollableTabs extends StatelessWidget {
  final TabController controller;
  final int pending;
  final int processing;
  final int paid;
  final int onHold;
  final int blocked;

  const _ScrollableTabs({
    required this.controller,
    required this.pending,
    required this.processing,
    required this.paid,
    required this.onHold,
    required this.blocked,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.only(left: 8, bottom: 8),
      child: TabBar(
        controller: controller,
        isScrollable: true,
        tabAlignment: TabAlignment.start,
        indicatorSize: TabBarIndicatorSize.label,
        indicatorColor: AdminColors.brandBrown,
        labelColor: AdminColors.textPrimary,
        unselectedLabelColor: AdminColors.textMuted,
        labelStyle:
            GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.w600),
        unselectedLabelStyle:
            GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.w500),
        dividerColor: Colors.transparent,
        tabs: [
          _TabLabel(label: 'Pending', count: pending, color: AdminColors.warning),
          _TabLabel(
              label: 'Processing',
              count: processing,
              color: const Color(0xFF1A56DB)),
          _TabLabel(label: 'Sent', count: paid, color: AdminColors.success),
          _TabLabel(
              label: 'On Hold',
              count: onHold,
              color: const Color(0xFFC2410C)),
          _TabLabel(
              label: 'Cancelled', count: blocked, color: AdminColors.error),
          const _TabLabel(label: 'All', count: 0),
        ],
      ),
    );
  }
}

class _TabLabel extends StatelessWidget {
  final String label;
  final int count;
  final Color? color;
  const _TabLabel({required this.label, required this.count, this.color});

  @override
  Widget build(BuildContext context) {
    return Tab(
      height: 36,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label),
            if (count > 0) ...[
              const SizedBox(width: 5),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
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
      ),
    );
  }
}

// ─── Search ─────────────────────────────────────────────────────

class _SearchBar extends StatelessWidget {
  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  const _SearchBar({required this.controller, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: TextField(
        controller: controller,
        onChanged: onChanged,
        style: GoogleFonts.inter(
          fontSize: 14,
          color: AdminColors.textPrimary,
        ),
        decoration: InputDecoration(
          isDense: true,
          hintText: 'Search by name or account number',
          hintStyle: GoogleFonts.inter(
            fontSize: 13,
            color: AdminColors.textLight,
          ),
          prefixIcon: const Icon(Icons.search,
              size: 18, color: AdminColors.textLight),
          suffixIcon: controller.text.isEmpty
              ? null
              : GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {
                    controller.clear();
                    onChanged('');
                  },
                  child: const Icon(Icons.close,
                      size: 16, color: AdminColors.textLight),
                ),
          filled: true,
          fillColor: AdminColors.inputBackground,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: AdminColors.borderLight),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: AdminColors.brandBrown),
          ),
        ),
      ),
    );
  }
}

class _NoSearchResults extends StatelessWidget {
  const _NoSearchResults();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          AppIcon(AppIcons.search,
              size: 44, color: AdminColors.textLight.withValues(alpha: 0.4)),
          const SizedBox(height: 14),
          Text(
            'No matches',
            style: GoogleFonts.inter(
              fontSize: 15,
              fontWeight: FontWeight.w500,
              color: AdminColors.textMuted,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Try a different name or account number',
            style: GoogleFonts.inter(
              fontSize: 13,
              color: AdminColors.textLight,
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Controls (date filter + select toggle) ────────────────────

class _ControlsRow extends StatelessWidget {
  final String dateFilter;
  final ValueChanged<String> onDateFilter;
  final bool showSelect;
  final bool selectionMode;
  final VoidCallback onToggleSelectionMode;
  const _ControlsRow({
    required this.dateFilter,
    required this.onDateFilter,
    required this.showSelect,
    required this.selectionMode,
    required this.onToggleSelectionMode,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 8, 4),
      child: Row(
        children: [
          _DateChip(
            label: 'All',
            selected: dateFilter == 'all',
            onTap: () => onDateFilter('all'),
          ),
          const SizedBox(width: 8),
          _DateChip(
            label: 'Today',
            selected: dateFilter == 'today',
            onTap: () => onDateFilter('today'),
          ),
          const Spacer(),
          if (showSelect)
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onToggleSelectionMode,
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Text(
                  selectionMode ? 'Done' : 'Select',
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: AdminColors.brandBrown,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _DateChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _DateChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: selected
              ? AdminColors.brandBrown.withValues(alpha: 0.1)
              : AdminColors.inputBackground,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: selected ? AdminColors.brandBrown : AdminColors.borderLight,
          ),
        ),
        child: Text(
          label,
          style: GoogleFonts.inter(
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
            color: selected ? AdminColors.brandBrown : AdminColors.textMuted,
          ),
        ),
      ),
    );
  }
}

// ─── Bulk action bar ───────────────────────────────────────────

class _BulkBar extends StatelessWidget {
  final int count;
  final bool allSelected;
  final VoidCallback onSelectAll;
  final VoidCallback onSent;
  final VoidCallback onHold;
  const _BulkBar({
    required this.count,
    required this.allSelected,
    required this.onSelectAll,
    required this.onSent,
    required this.onHold,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = count > 0;
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border(top: BorderSide(color: AdminColors.borderLight)),
          boxShadow: [
            BoxShadow(
              blurRadius: 10,
              offset: const Offset(0, -2),
              color: Colors.black.withValues(alpha: 0.05),
            ),
          ],
        ),
        child: Row(
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '$count selected',
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: AdminColors.textPrimary,
                  ),
                ),
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: onSelectAll,
                  child: Text(
                    allSelected ? 'All selected' : 'Select all',
                    style: GoogleFonts.inter(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      color: AdminColors.brandBrown,
                    ),
                  ),
                ),
              ],
            ),
            const Spacer(),
            _BulkBtn(
              label: 'On Hold',
              color: const Color(0xFFC2410C),
              onTap: enabled ? onHold : null,
            ),
            const SizedBox(width: 8),
            _BulkBtn(
              label: 'Mark Sent',
              color: AdminColors.success,
              onTap: enabled ? onSent : null,
            ),
          ],
        ),
      ),
    );
  }
}

class _BulkBtn extends StatelessWidget {
  final String label;
  final Color color;
  final VoidCallback? onTap;
  const _BulkBtn({required this.label, required this.color, this.onTap});

  @override
  Widget build(BuildContext context) {
    final on = onTap != null;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: on ? color : color.withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(
          label,
          style: GoogleFonts.inter(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: Colors.white,
          ),
        ),
      ),
    );
  }
}

// Generic single-field bottom sheet for bulk Mark-Sent (reference) and
// bulk On-Hold (reason). Returns the entered text via Navigator.pop.
class _BulkInputSheet extends StatefulWidget {
  final String title;
  final String subtitle;
  final String fieldLabel;
  final String hint;
  final String confirmLabel;
  final Color confirmColor;
  final List<String> presets;
  final bool mono;
  const _BulkInputSheet({
    required this.title,
    required this.subtitle,
    required this.fieldLabel,
    required this.hint,
    required this.confirmLabel,
    required this.confirmColor,
    this.presets = const [],
    this.mono = false,
  });

  @override
  State<_BulkInputSheet> createState() => _BulkInputSheetState();
}

class _BulkInputSheetState extends State<_BulkInputSheet> {
  final _controller = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final t = _controller.text.trim();
    if (t.isEmpty) {
      setState(() => _error = 'This field is required');
      return;
    }
    Navigator.of(context).pop(t);
  }

  @override
  Widget build(BuildContext context) {
    final viewInsets = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: viewInsets),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
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
                      color: AdminColors.textLight.withValues(alpha: 0.4),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                Text(
                  widget.title,
                  style: GoogleFonts.inter(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: AdminColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  widget.subtitle,
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    fontWeight: FontWeight.w400,
                    color: AdminColors.textBody,
                    height: 1.45,
                  ),
                ),
                if (widget.presets.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: widget.presets
                        .map((p) => GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: () {
                                _controller.text = p;
                                setState(() => _error = null);
                              },
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 12, vertical: 7),
                                decoration: BoxDecoration(
                                  color: AdminColors.inputBackground,
                                  borderRadius: BorderRadius.circular(20),
                                  border: Border.all(
                                      color: AdminColors.borderLight),
                                ),
                                child: Text(
                                  p,
                                  style: GoogleFonts.inter(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w500,
                                    color: AdminColors.textBody,
                                  ),
                                ),
                              ),
                            ))
                        .toList(),
                  ),
                ],
                const SizedBox(height: 14),
                Text(
                  widget.fieldLabel,
                  style: GoogleFonts.inter(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: AdminColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _controller,
                  autofocus: true,
                  textCapitalization: widget.mono
                      ? TextCapitalization.characters
                      : TextCapitalization.sentences,
                  onChanged: (_) {
                    if (_error != null) setState(() => _error = null);
                  },
                  style: widget.mono
                      ? GoogleFonts.robotoMono(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: AdminColors.textPrimary,
                        )
                      : GoogleFonts.inter(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: AdminColors.textPrimary,
                        ),
                  decoration: InputDecoration(
                    hintText: widget.hint,
                    hintStyle: GoogleFonts.inter(
                      fontSize: 13,
                      color: AdminColors.textLight,
                    ),
                    filled: true,
                    fillColor: AdminColors.inputBackground,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 14),
                    errorText: _error,
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide:
                          const BorderSide(color: AdminColors.borderLight),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: widget.confirmColor),
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide:
                          const BorderSide(color: AdminColors.borderLight),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                Row(
                  children: [
                    Expanded(
                      child: _SheetButton(
                        label: 'Cancel',
                        foreground: AdminColors.textBody,
                        background: AdminColors.inputBackground,
                        border: AdminColors.borderLight,
                        onTap: () => Navigator.of(context).pop(),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      flex: 2,
                      child: _SheetButton(
                        label: widget.confirmLabel,
                        foreground: Colors.white,
                        background: widget.confirmColor,
                        border: widget.confirmColor,
                        onTap: _submit,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ─── List ──────────────────────────────────────────────────────

class _WithdrawalsList extends StatelessWidget {
  final List<AdminWithdrawalModel> withdrawals;
  final String filter;
  final bool searching;
  final String? actionInProgressId;
  final bool selectionMode;
  final Set<String> selectedIds;
  final void Function(String) onToggleSelect;
  final Future<void> Function() onRefresh;
  final void Function(AdminWithdrawalModel) onManage;
  final void Function(AdminWithdrawalModel) onOpen;

  const _WithdrawalsList({
    required this.withdrawals,
    required this.filter,
    required this.searching,
    required this.actionInProgressId,
    required this.selectionMode,
    required this.selectedIds,
    required this.onToggleSelect,
    required this.onRefresh,
    required this.onManage,
    required this.onOpen,
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
              child: searching
                  ? const _NoSearchResults()
                  : _EmptyState(filter: filter),
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
          final busy = actionInProgressId == w.id;
          return _WithdrawalCard(
            withdrawal: w,
            busy: busy,
            selectionMode: selectionMode,
            selected: selectedIds.contains(w.id),
            onToggleSelect: () => onToggleSelect(w.id),
            onManage: () => onManage(w),
            onOpen: () => onOpen(w),
          );
        },
      ),
    );
  }
}

// ─── Withdrawal card ───────────────────────────────────────────

class _WithdrawalCard extends StatelessWidget {
  final AdminWithdrawalModel withdrawal;
  final bool busy;
  final bool selectionMode;
  final bool selected;
  final VoidCallback onToggleSelect;
  final VoidCallback onManage;
  // Tapping the card body (anywhere except the Manage button) opens the
  // full detail page.
  final VoidCallback onOpen;

  const _WithdrawalCard({
    required this.withdrawal,
    required this.busy,
    required this.selectionMode,
    required this.selected,
    required this.onToggleSelect,
    required this.onManage,
    required this.onOpen,
  });

  bool get _canManage =>
      withdrawal.isPending ||
      withdrawal.isProcessing ||
      withdrawal.isOnHold;

  @override
  Widget build(BuildContext context) {
    final w = withdrawal;
    final country = w.countryIso.isEmpty ? 'IN' : w.countryIso;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      // In selection mode the whole card toggles selection; otherwise it
      // opens the detail page.
      onTap: selectionMode ? onToggleSelect : onOpen,
      child: Container(
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        padding: const EdgeInsets.all(16),
        decoration: selectionMode && selected
            ? AdminColors.cardDecoration.copyWith(
                border: Border.all(color: AdminColors.brandBrown, width: 1.5),
              )
            : AdminColors.cardDecoration,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (selectionMode) ...[
                  Icon(
                    selected
                        ? Icons.check_circle
                        : Icons.radio_button_unchecked,
                    size: 20,
                    color: selected
                        ? AdminColors.brandBrown
                        : AdminColors.textLight,
                  ),
                  const SizedBox(width: 12),
                ],
                Expanded(
                  child: Text(
                    _money(w.amount),
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
            icon: AppIcons.userOutline,
            text: w.bankAccountName.isEmpty
                ? 'No account holder'
                : '${w.bankAccountName}  ·  $country',
          ),
          const SizedBox(height: 4),
          _IconRow(
            icon: AppIcons.bank,
            text: w.bankName.isEmpty
                ? 'A/c ••••${w.lastFourAccount}'
                : '${w.bankName} · ••••${w.lastFourAccount}',
          ),
          const SizedBox(height: 4),
          _IconRow(icon: AppIcons.tag, text: _routingLine(w)),
          if (w.reference != null) ...[
            const SizedBox(height: 4),
            _IconRow(icon: AppIcons.check, text: 'Ref: ${w.reference}'),
          ],
          if (w.isOnHold && w.onHoldReason != null) ...[
            const SizedBox(height: 4),
            _IconRow(icon: AppIcons.error, text: 'Hold: ${w.onHoldReason}'),
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
            if (_canManage && !selectionMode) ...[
              const SizedBox(height: 12),
              _ManageButton(busy: busy, onTap: onManage),
            ],
          ],
        ),
      ),
    );
  }

  // Shows whichever routing identifier this country uses.
  String _routingLine(AdminWithdrawalModel w) {
    if (w.bankIfscCode.isNotEmpty) return 'IFSC: ${w.bankIfscCode}';
    if (w.routingNumber.isNotEmpty) return 'Routing: ${w.routingNumber}';
    if (w.sortCode.isNotEmpty) return 'Sort: ${w.sortCode}';
    if (w.swiftBic.isNotEmpty) return 'SWIFT: ${w.swiftBic}';
    return 'No routing details';
  }
}

class _ManageButton extends StatelessWidget {
  final bool busy;
  final VoidCallback onTap;
  const _ManageButton({required this.busy, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: busy ? null : onTap,
      child: Container(
        height: 42,
        decoration: BoxDecoration(
          color: busy
              ? AdminColors.brandBrown.withValues(alpha: 0.5)
              : AdminColors.brandBrown,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Center(
          child: busy
              ? const SizedBox(
                  width: 29,
                  height: 29,
                  child: AppLoader(),
                )
              : Text(
                  'Manage Payout',
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
        ),
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
        AppIcon(icon, size: 16, color: AdminColors.textLight),
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
      'processing' => (
          const Color(0xFFE8F0FE),
          const Color(0xFF1A56DB),
          'Processing',
        ),
      'paid' => (AdminColors.successBg, AdminColors.success, 'Sent'),
      'on_hold' => (
          const Color(0xFFFFF1E6),
          const Color(0xFFC2410C),
          'On Hold',
        ),
      'blocked' => (AdminColors.errorBg, AdminColors.error, 'Cancelled'),
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

// ─── Manage sheet ──────────────────────────────────────────────

class _ManageSheet extends StatelessWidget {
  final AdminWithdrawalModel withdrawal;
  const _ManageSheet({required this.withdrawal});

  @override
  Widget build(BuildContext context) {
    final w = withdrawal;
    final actions = <(_PayoutAction, String, String, Color)>[
      if (w.isPending)
        (
          _PayoutAction.processing,
          'Mark as Processing',
          'Added to a bank batch',
          const Color(0xFF1A56DB),
        ),
      (
        _PayoutAction.sent,
        'Mark as Sent',
        'Record the bank reference',
        AdminColors.success,
      ),
      (
        _PayoutAction.onHold,
        'Put On Hold',
        'Pause with a reason for the priest',
        const Color(0xFFC2410C),
      ),
      (
        _PayoutAction.block,
        'Block & Refund',
        'Cancel and return the money',
        AdminColors.error,
      ),
    ];

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: AdminColors.textLight.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 18),
            Text(
              'Manage ${_money(w.amount)} payout',
              style: GoogleFonts.inter(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: AdminColors.textPrimary,
              ),
            ),
            const SizedBox(height: 14),
            for (final a in actions) ...[
              _ManageRow(
                label: a.$2,
                subtitle: a.$3,
                color: a.$4,
                onTap: () => Navigator.of(context).pop(a.$1),
              ),
              const SizedBox(height: 8),
            ],
          ],
        ),
      ),
    );
  }
}

class _ManageRow extends StatelessWidget {
  final String label;
  final String subtitle;
  final Color color;
  final VoidCallback onTap;
  const _ManageRow({
    required this.label,
    required this.subtitle,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: AdminColors.inputBackground,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AdminColors.borderLight),
        ),
        child: Row(
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(shape: BoxShape.circle, color: color),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: GoogleFonts.inter(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: AdminColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: GoogleFonts.inter(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w400,
                      color: AdminColors.textMuted,
                    ),
                  ),
                ],
              ),
            ),
            AppIcon(AppIcons.chevronDown,
                size: 16, color: AdminColors.textLight),
          ],
        ),
      ),
    );
  }
}

// ─── Mark-Sent sheet (reference capture) ───────────────────────

class _MarkSentSheet extends StatefulWidget {
  final AdminWithdrawalModel withdrawal;
  // True when `withdrawal` is the request-time snapshot because the
  // priest has no current bank details (they cleared them). Drives the
  // warning banner so the admin knows to verify before sending.
  final bool usingRequestSnapshot;
  const _MarkSentSheet({
    required this.withdrawal,
    this.usingRequestSnapshot = false,
  });

  @override
  State<_MarkSentSheet> createState() => _MarkSentSheetState();
}

class _MarkSentSheetState extends State<_MarkSentSheet> {
  final _controller = TextEditingController();
  final _txnController = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    _txnController.dispose();
    super.dispose();
  }

  void _submit() {
    final ref = _controller.text.trim();
    if (ref.isEmpty) {
      setState(() => _error = 'Enter the reference number');
      return;
    }
    // (reference, transactionId) — transaction id is optional.
    Navigator.of(context).pop((ref, _txnController.text.trim()));
  }

  @override
  Widget build(BuildContext context) {
    final w = widget.withdrawal;
    final viewInsets = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: viewInsets),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
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
                      color: AdminColors.textLight.withValues(alpha: 0.4),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                Text(
                  'Mark as Sent',
                  style: GoogleFonts.inter(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: AdminColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'Send ${_money(w.amount)} using the details '
                  'below, then enter the reference the bank returned.',
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    fontWeight: FontWeight.w400,
                    color: AdminColors.textBody,
                    height: 1.45,
                  ),
                ),
                // Foreign account: the amount is in ₹ — the admin must
                // convert. Shown only when the destination isn't INR.
                if (w.currency.isNotEmpty && w.currency != 'INR') ...[
                  const SizedBox(height: 10),
                  _SentNote(
                    icon: AppIcons.info,
                    color: const Color(0xFF1A56DB),
                    text: 'This account is in ${w.currency}. The amount is '
                        'in ₹ — convert it at the bank before sending.',
                  ),
                ],
                // Stale-snapshot guard: the priest has no current bank
                // details, so we're showing the original request's.
                if (widget.usingRequestSnapshot) ...[
                  const SizedBox(height: 10),
                  _SentNote(
                    icon: AppIcons.error,
                    color: const Color(0xFFC2410C),
                    text: "Couldn't load the priest's latest bank details — "
                        'showing the details from the original request. '
                        'Verify before sending.',
                  ),
                ] else ...[
                  const SizedBox(height: 10),
                  _SentNote(
                    icon: AppIcons.check,
                    color: AdminColors.success,
                    text: "Showing the priest's current bank details.",
                  ),
                ],
                const SizedBox(height: 16),
                _PayoutDetails(withdrawal: w),
                const SizedBox(height: 16),
                Text(
                  'Reference Number',
                  style: GoogleFonts.inter(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: AdminColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _controller,
                  autofocus: true,
                  textCapitalization: TextCapitalization.characters,
                  onChanged: (_) {
                    if (_error != null) setState(() => _error = null);
                  },
                  style: GoogleFonts.robotoMono(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: AdminColors.textPrimary,
                  ),
                  decoration: InputDecoration(
                    hintText: 'e.g. UTR / wire reference',
                    hintStyle: GoogleFonts.inter(
                      fontSize: 13,
                      color: AdminColors.textLight,
                    ),
                    filled: true,
                    fillColor: AdminColors.inputBackground,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 14),
                    errorText: _error,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide:
                          const BorderSide(color: AdminColors.borderLight),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide:
                          const BorderSide(color: AdminColors.borderLight),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide:
                          const BorderSide(color: AdminColors.brandBrown),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  'Transaction ID (optional)',
                  style: GoogleFonts.inter(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: AdminColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _txnController,
                  textCapitalization: TextCapitalization.characters,
                  style: GoogleFonts.robotoMono(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: AdminColors.textPrimary,
                  ),
                  decoration: InputDecoration(
                    hintText: 'Bank Transaction ID, if provided',
                    hintStyle: GoogleFonts.inter(
                      fontSize: 13,
                      color: AdminColors.textLight,
                    ),
                    filled: true,
                    fillColor: AdminColors.inputBackground,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 14),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide:
                          const BorderSide(color: AdminColors.borderLight),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide:
                          const BorderSide(color: AdminColors.borderLight),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide:
                          const BorderSide(color: AdminColors.brandBrown),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                Row(
                  children: [
                    Expanded(
                      child: _SheetButton(
                        label: 'Cancel',
                        foreground: AdminColors.textBody,
                        background: AdminColors.inputBackground,
                        border: AdminColors.borderLight,
                        onTap: () => Navigator.of(context).pop(),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      flex: 2,
                      child: _SheetButton(
                        label: 'Confirm Sent',
                        foreground: Colors.white,
                        background: AdminColors.success,
                        border: AdminColors.success,
                        onTap: _submit,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ─── On-Hold sheet (reason capture) ────────────────────────────

class _OnHoldSheet extends StatefulWidget {
  final AdminWithdrawalModel withdrawal;
  const _OnHoldSheet({required this.withdrawal});

  @override
  State<_OnHoldSheet> createState() => _OnHoldSheetState();
}

class _OnHoldSheetState extends State<_OnHoldSheet> {
  final _controller = TextEditingController();
  String? _error;

  // Quick-pick common reasons so the admin rarely types.
  static const _presets = [
    'Account number invalid',
    'Bank rejected the transfer',
    'Name does not match account',
    'IFSC / routing details wrong',
  ];

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final reason = _controller.text.trim();
    if (reason.isEmpty) {
      setState(() => _error = 'Enter a reason the priest will see');
      return;
    }
    Navigator.of(context).pop(reason);
  }

  @override
  Widget build(BuildContext context) {
    final viewInsets = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: viewInsets),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
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
                      color: AdminColors.textLight.withValues(alpha: 0.4),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                Text(
                  'Put On Hold',
                  style: GoogleFonts.inter(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: AdminColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'The priest sees this reason and a prompt to fix their '
                  'bank details. No money is refunded — the payout is '
                  'just paused.',
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    fontWeight: FontWeight.w400,
                    color: AdminColors.textBody,
                    height: 1.45,
                  ),
                ),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: _presets
                      .map((p) => GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () {
                              _controller.text = p;
                              setState(() => _error = null);
                            },
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 7),
                              decoration: BoxDecoration(
                                color: AdminColors.inputBackground,
                                borderRadius: BorderRadius.circular(20),
                                border:
                                    Border.all(color: AdminColors.borderLight),
                              ),
                              child: Text(
                                p,
                                style: GoogleFonts.inter(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w500,
                                  color: AdminColors.textBody,
                                ),
                              ),
                            ),
                          ))
                      .toList(),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: _controller,
                  maxLines: 2,
                  textCapitalization: TextCapitalization.sentences,
                  onChanged: (_) {
                    if (_error != null) setState(() => _error = null);
                  },
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: AdminColors.textPrimary,
                  ),
                  decoration: InputDecoration(
                    hintText: 'Reason shown to the priest',
                    hintStyle: GoogleFonts.inter(
                      fontSize: 13,
                      color: AdminColors.textLight,
                    ),
                    filled: true,
                    fillColor: AdminColors.inputBackground,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 12),
                    errorText: _error,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide:
                          const BorderSide(color: AdminColors.borderLight),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide:
                          const BorderSide(color: AdminColors.borderLight),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide:
                          const BorderSide(color: Color(0xFFC2410C)),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                Row(
                  children: [
                    Expanded(
                      child: _SheetButton(
                        label: 'Cancel',
                        foreground: AdminColors.textBody,
                        background: AdminColors.inputBackground,
                        border: AdminColors.borderLight,
                        onTap: () => Navigator.of(context).pop(),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      flex: 2,
                      child: _SheetButton(
                        label: 'Put On Hold',
                        foreground: Colors.white,
                        background: const Color(0xFFC2410C),
                        border: const Color(0xFFC2410C),
                        onTap: _submit,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Payout details (shown in the Mark-Sent sheet) ─────────────

class _PayoutDetails extends StatelessWidget {
  final AdminWithdrawalModel withdrawal;
  const _PayoutDetails({required this.withdrawal});

  @override
  Widget build(BuildContext context) {
    final w = withdrawal;
    final rows = <(String, String)>[
      ('Amount', _money(w.amount)),
      ('Account holder', w.bankAccountName),
      ('Bank', w.bankName),
      ('Country', w.countryIso.isEmpty ? 'IN' : w.countryIso),
      if (w.bankAccountNumber.isNotEmpty)
        ('Account number', w.bankAccountNumber),
      if (w.iban.isNotEmpty) ('IBAN', w.iban),
      if (w.bankIfscCode.isNotEmpty) ('IFSC', w.bankIfscCode),
      if (w.routingNumber.isNotEmpty) ('Routing', w.routingNumber),
      if (w.sortCode.isNotEmpty) ('Sort code', w.sortCode),
      if (w.swiftBic.isNotEmpty) ('SWIFT/BIC', w.swiftBic),
      if ((w.upiId ?? '').isNotEmpty) ('UPI', w.upiId!),
    ];
    return Container(
      decoration: BoxDecoration(
        color: AdminColors.inputBackground,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AdminColors.borderLight),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
      child: Column(
        children: [
          for (var i = 0; i < rows.length; i++) ...[
            if (i > 0) const _PayoutDivider(),
            _PayoutRow(
              label: rows[i].$1,
              value: rows[i].$2.isEmpty ? '—' : rows[i].$2,
              copyText: rows[i].$2.isEmpty ? null : rows[i].$2,
              monospace: const {
                'Account number',
                'IBAN',
                'IFSC',
                'Routing',
                'Sort code',
                'SWIFT/BIC',
              }.contains(rows[i].$1),
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
          Expanded(child: Text(widget.value, style: valueStyle)),
          if (canCopy) ...[
            const SizedBox(width: 8),
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _copy,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: _justCopied ? AdminColors.successBg : Colors.white,
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
                    AppIcon(
                      _justCopied ? AppIcons.check : AppIcons.copy,
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

// ─── Block sheet ───────────────────────────────────────────────

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
                  color: AdminColors.textLight.withValues(alpha: 0.4),
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
              'This will refund ${_money(w.amount)} back to the '
              'priest’s wallet and flag this withdrawal as cancelled.',
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

// ─── Mark-processing dialog (after export) ─────────────────────

class _MarkProcessingDialog extends StatelessWidget {
  final int count;
  const _MarkProcessingDialog({required this.count});

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.white,
      shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 22, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Mark $count as Processing?',
              style: GoogleFonts.inter(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: AdminColors.textPrimary,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Exported rows can move to Processing so each priest sees '
              '“being prepared” on their status screen. Do this once you '
              'have sent the sheet to the bank.',
              style: GoogleFonts.inter(
                fontSize: 13,
                fontWeight: FontWeight.w400,
                color: AdminColors.textBody,
                height: 1.45,
              ),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: _SheetButton(
                    label: 'Not now',
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
                    label: 'Mark Processing',
                    foreground: Colors.white,
                    background: AdminColors.brandBrown,
                    border: AdminColors.brandBrown,
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
          AppIcons.inbox,
          'No pending withdrawals',
          'New withdrawal requests will appear here',
        ),
      'processing' => (
          AppIcons.bank,
          'Nothing in processing',
          'Payouts you export / mark processing appear here',
        ),
      'paid' => (
          AppIcons.taskDone,
          'No sent withdrawals yet',
          'Payouts you mark as sent will appear here',
        ),
      'on_hold' => (
          AppIcons.error,
          'Nothing on hold',
          'Payouts you pause will appear here',
        ),
      'blocked' => (
          AppIcons.block,
          'No cancelled withdrawals',
          'Cancelled payouts will appear here',
        ),
      _ => (
          AppIcons.payments,
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
            AppIcon(
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
            const AppIcon(AppIcons.error, size: 48, color: AdminColors.error),
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
                padding:
                    const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
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

// Small inline note used in the Mark-Sent sheet (currency convert
// reminder / stale-snapshot warning / current-details confirmation).
class _SentNote extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String text;
  const _SentNote({
    required this.icon,
    required this.color,
    required this.text,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppIcon(icon, size: 15, color: color),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              text,
              style: GoogleFonts.inter(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                height: 1.4,
                color: AdminColors.textBody,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── helpers ───────────────────────────────────────────────────

// The amount owed is ALWAYS in the platform currency (₹) — the coin
// economy is 1 coin = ₹1 regardless of the priest's country. The
// destination bank currency is shown separately (so the admin converts
// at the bank); it must never relabel the amount, or a ₹1,000 payout to
// a USD account would read as "$1,000".
String _money(int amount) => '₹$amount';
