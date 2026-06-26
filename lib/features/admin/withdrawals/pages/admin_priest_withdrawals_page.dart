// Every withdrawal by ONE priest, in one place — so when a priest
// requests ₹100 three times, the admin sees the whole history and the
// totals at a glance instead of hunting through the main queue. Totals
// header, a per-priest Excel export, and a per-row receipt download.
// Read-only; the admin processes payouts from the main queue.

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:gospel_vox/core/theme/admin_colors.dart';
import 'package:gospel_vox/core/widgets/app_icons.dart';
import 'package:gospel_vox/core/widgets/app_snackbar.dart';
import 'package:gospel_vox/features/admin/withdrawals/data/admin_withdrawal_model.dart';
import 'package:gospel_vox/features/admin/withdrawals/data/admin_withdrawals_repository.dart';
import 'package:gospel_vox/features/admin/withdrawals/data/withdrawal_export.dart';
import 'package:gospel_vox/features/admin/withdrawals/data/withdrawal_share.dart';
import 'package:gospel_vox/core/widgets/app_loading_widget.dart';

class AdminPriestWithdrawalsPage extends StatefulWidget {
  final String priestId;
  final String priestName;
  const AdminPriestWithdrawalsPage({
    super.key,
    required this.priestId,
    required this.priestName,
  });

  @override
  State<AdminPriestWithdrawalsPage> createState() =>
      _AdminPriestWithdrawalsPageState();
}

class _AdminPriestWithdrawalsPageState
    extends State<AdminPriestWithdrawalsPage> {
  final _repo = AdminWithdrawalsRepository();
  bool _loading = true;
  String? _error;
  List<AdminWithdrawalModel> _items = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final rows = await _repo.getWithdrawalsForPriest(widget.priestId);
      if (!mounted) return;
      setState(() {
        _items = rows;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load this priest’s withdrawals.';
        _loading = false;
      });
    }
  }

  String _safe(String s) =>
      s.replaceAll(RegExp(r'[^A-Za-z0-9]+'), '_').toLowerCase();

  Future<void> _exportAll() async {
    if (_items.isEmpty) return;
    final result = await shareCsvFile(
      csv: buildWithdrawalsCsv(_items),
      filename: '${_safe(widget.priestName)}_withdrawals.csv',
      subject: '${widget.priestName} — withdrawals',
    );
    if (!mounted) return;
    switch (result) {
      case CsvShareResult.shared:
        break;
      case CsvShareResult.copiedToClipboard:
        AppSnackBar.success(context, 'Share unavailable — CSV copied');
      case CsvShareResult.failed:
        AppSnackBar.error(context, 'Could not export.');
    }
  }

  Future<void> _exportReceipt(AdminWithdrawalModel w) async {
    final result = await shareCsvFile(
      csv: buildReceiptCsv(w),
      filename: 'receipt_${_safe(widget.priestName)}_${w.id}.csv',
      subject: 'Withdrawal receipt',
    );
    if (!mounted) return;
    if (result == CsvShareResult.copiedToClipboard) {
      AppSnackBar.success(context, 'Share unavailable — receipt copied');
    } else if (result == CsvShareResult.failed) {
      AppSnackBar.error(context, 'Could not export the receipt.');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AdminColors.background,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        leading: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => Navigator.of(context).maybePop(),
          child: const AppIcon(AppIcons.back,
              color: AdminColors.textPrimary, size: 22),
        ),
        title: Text(
          widget.priestName,
          style: GoogleFonts.inter(
            fontSize: 18,
            fontWeight: FontWeight.w600,
            color: AdminColors.textPrimary,
          ),
        ),
        centerTitle: false,
        actions: [
          if (!_loading && _items.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _exportAll,
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
            ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(
        child: AppLoader(),
      );
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_error!,
                  textAlign: TextAlign.center,
                  style: GoogleFonts.inter(
                      fontSize: 14, color: AdminColors.textMuted)),
              const SizedBox(height: 16),
              GestureDetector(
                onTap: _load,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 24, vertical: 10),
                  decoration: BoxDecoration(
                    color: AdminColors.brandBrown,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text('Retry',
                      style: GoogleFonts.inter(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: Colors.white)),
                ),
              ),
            ],
          ),
        ),
      );
    }
    final summary = PriestWithdrawalSummary.from(_items);
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      itemCount: _items.length + 1,
      itemBuilder: (_, i) {
        if (i == 0) return _SummaryHeader(summary: summary);
        final w = _items[i - 1];
        return _HistoryRow(
          withdrawal: w,
          onReceipt: () => _exportReceipt(w),
        );
      },
    );
  }
}

class _SummaryHeader extends StatelessWidget {
  final PriestWithdrawalSummary summary;
  const _SummaryHeader({required this.summary});

  @override
  Widget build(BuildContext context) {
    final s = summary;
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(16),
      decoration: AdminColors.cardDecoration,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${s.total} withdrawal${s.total == 1 ? '' : 's'}',
            style: GoogleFonts.inter(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: AdminColors.textPrimary,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              _Stat(label: 'Sent', value: '₹${s.paidAmount}',
                  color: AdminColors.success),
              _Stat(label: 'In progress', value: '₹${s.inFlightAmount}',
                  color: const Color(0xFF1A56DB)),
              _Stat(label: 'Total', value: '₹${s.totalAmount}',
                  color: AdminColors.textPrimary),
            ],
          ),
          if (s.pending + s.processing + s.onHold + s.blocked > 0) ...[
            const SizedBox(height: 10),
            Text(
              [
                if (s.pending > 0) '${s.pending} pending',
                if (s.processing > 0) '${s.processing} processing',
                if (s.onHold > 0) '${s.onHold} on hold',
                if (s.blocked > 0) '${s.blocked} cancelled',
              ].join(' · '),
              style: GoogleFonts.inter(
                fontSize: 12,
                color: AdminColors.textMuted,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  const _Stat({required this.label, required this.value, required this.color});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            value,
            style: GoogleFonts.inter(
              fontSize: 16,
              fontWeight: FontWeight.w800,
              color: color,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: GoogleFonts.inter(
              fontSize: 11,
              fontWeight: FontWeight.w400,
              color: AdminColors.textMuted,
            ),
          ),
        ],
      ),
    );
  }
}

class _HistoryRow extends StatelessWidget {
  final AdminWithdrawalModel withdrawal;
  final VoidCallback onReceipt;
  const _HistoryRow({required this.withdrawal, required this.onReceipt});

  @override
  Widget build(BuildContext context) {
    final w = withdrawal;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
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
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: AdminColors.textPrimary,
                  ),
                ),
              ),
              _MiniBadge(status: w.status),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            w.formattedCreatedAt.isEmpty
                ? 'Requested recently'
                : 'Requested ${w.formattedCreatedAt}',
            style: GoogleFonts.inter(
              fontSize: 11.5,
              color: AdminColors.textLight,
            ),
          ),
          if (w.reference != null) ...[
            const SizedBox(height: 3),
            Text(
              'Ref: ${w.reference}',
              style: GoogleFonts.robotoMono(
                fontSize: 11.5,
                color: AdminColors.textMuted,
              ),
            ),
          ],
          const SizedBox(height: 10),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onReceipt,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const AppIcon(AppIcons.download,
                    size: 13, color: AdminColors.brandBrown),
                const SizedBox(width: 5),
                Text(
                  'Receipt',
                  style: GoogleFonts.inter(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: AdminColors.brandBrown,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MiniBadge extends StatelessWidget {
  final String status;
  const _MiniBadge({required this.status});

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
      decoration:
          BoxDecoration(color: bg, borderRadius: BorderRadius.circular(6)),
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
