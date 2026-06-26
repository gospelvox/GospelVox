// Full detail of one withdrawal for the admin — everything unmasked and
// copyable (the list masks for shoulder-surf safety; here the admin gets
// the complete account to pay into), the lifecycle with timestamps, a
// one-tap "Download Receipt" (CSV), and a summary of THIS priest's whole
// withdrawal history with a link to see them all. Read-only: the
// Manage actions stay on the list card for fast batch processing.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:gospel_vox/core/theme/admin_colors.dart';
import 'package:gospel_vox/core/widgets/app_icons.dart';
import 'package:gospel_vox/core/widgets/app_snackbar.dart';
import 'package:gospel_vox/features/admin/withdrawals/data/admin_withdrawal_model.dart';
import 'package:gospel_vox/features/admin/withdrawals/data/admin_withdrawals_repository.dart';
import 'package:gospel_vox/features/admin/withdrawals/data/withdrawal_export.dart';
import 'package:gospel_vox/features/admin/withdrawals/data/withdrawal_share.dart';
import 'package:gospel_vox/features/admin/withdrawals/pages/admin_priest_withdrawals_page.dart';

class WithdrawalDetailPage extends StatefulWidget {
  final AdminWithdrawalModel withdrawal;
  const WithdrawalDetailPage({super.key, required this.withdrawal});

  @override
  State<WithdrawalDetailPage> createState() => _WithdrawalDetailPageState();
}

class _WithdrawalDetailPageState extends State<WithdrawalDetailPage> {
  final _repo = AdminWithdrawalsRepository();
  PriestWithdrawalSummary? _summary;
  // Mutable copy so the page reflects an edit-reference / reverse action
  // without leaving and re-opening.
  late AdminWithdrawalModel _w;

  @override
  void initState() {
    super.initState();
    _w = widget.withdrawal;
    _loadSummary();
  }

  Future<void> _loadSummary() async {
    try {
      final rows = await _repo.getWithdrawalsForPriest(_w.priestId);
      if (!mounted) return;
      setState(() => _summary = PriestWithdrawalSummary.from(rows));
    } catch (_) {
      // Summary is supplementary — leave it null on failure.
    }
  }

  // Re-pull the authoritative doc after an edit/reverse.
  Future<void> _refreshW() async {
    final fresh = await _repo.getWithdrawalById(_w.id);
    if (!mounted || fresh == null) return;
    setState(() => _w = fresh);
  }

  Future<void> _editReference() async {
    final result = await showDialog<(String, String)>(
      context: context,
      builder: (_) => _EditReferenceDialog(
        currentReference: _w.reference ?? '',
        currentTransactionId: _w.transactionId ?? '',
      ),
    );
    if (result == null || !mounted) return;
    try {
      await _repo.editReference(
        withdrawalId: _w.id,
        reference: result.$1,
        transactionId: result.$2,
      );
      await _refreshW();
      if (!mounted) return;
      AppSnackBar.success(context, 'Updated');
    } catch (_) {
      if (!mounted) return;
      AppSnackBar.error(context, 'Could not update. Try again.');
    }
  }

  Future<void> _reverse() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => const _ReverseDialog(),
    );
    if (ok != true || !mounted) return;
    try {
      await _repo.reverseToProcessing(_w.id);
      await _refreshW();
      if (!mounted) return;
      AppSnackBar.success(context, 'Moved back to Processing');
    } catch (_) {
      if (!mounted) return;
      AppSnackBar.error(context, 'Could not reverse. Try again.');
    }
  }

  Future<void> _downloadReceipt() async {
    final w = _w;
    final result = await shareCsvFile(
      csv: buildReceiptCsv(w),
      filename: 'receipt_${_safe(w.bankAccountName)}_${w.id}.csv',
      subject: 'Withdrawal receipt',
    );
    if (!mounted) return;
    switch (result) {
      case CsvShareResult.shared:
        break;
      case CsvShareResult.copiedToClipboard:
        AppSnackBar.success(context, 'Share unavailable — receipt copied');
      case CsvShareResult.failed:
        AppSnackBar.error(context, 'Could not export the receipt.');
    }
  }

  String _safe(String s) =>
      s.replaceAll(RegExp(r'[^A-Za-z0-9]+'), '_').toLowerCase();

  String _titleCase(String s) =>
      s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';

  @override
  Widget build(BuildContext context) {
    final w = _w;
    final country = w.countryIso.isEmpty ? 'IN' : w.countryIso;
    final currency = w.currency.isEmpty ? 'INR' : w.currency;

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
          'Withdrawal Detail',
          style: GoogleFonts.inter(
            fontSize: 18,
            fontWeight: FontWeight.w600,
            color: AdminColors.textPrimary,
          ),
        ),
        centerTitle: false,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          // Amount + status
          Row(
            children: [
              Expanded(
                child: Text(
                  '₹${w.amount}',
                  style: GoogleFonts.inter(
                    fontSize: 26,
                    fontWeight: FontWeight.w800,
                    color: AdminColors.textPrimary,
                  ),
                ),
              ),
              _StatusBadge(status: w.status),
            ],
          ),
          if (w.currency.isNotEmpty && w.currency != 'INR') ...[
            const SizedBox(height: 6),
            Text(
              'Amount is in ₹ — pay the equivalent to this $currency account.',
              style: GoogleFonts.inter(
                fontSize: 12,
                fontWeight: FontWeight.w400,
                color: const Color(0xFF1A56DB),
              ),
            ),
          ],
          const SizedBox(height: 20),

          _Section(
            title: 'PRIEST & BANK',
            child: Column(
              children: [
                _CopyRow(label: 'Holder', value: w.bankAccountName),
                _CopyRow(label: 'Country', value: '$country · $currency',
                    copyable: false),
                if (w.bankAccountNumber.isNotEmpty)
                  _CopyRow(
                      label: 'Account No', value: w.bankAccountNumber,
                      mono: true),
                if (w.iban.isNotEmpty)
                  _CopyRow(label: 'IBAN', value: w.iban, mono: true),
                if (w.bankIfscCode.isNotEmpty)
                  _CopyRow(label: 'IFSC', value: w.bankIfscCode, mono: true),
                if (w.routingNumber.isNotEmpty)
                  _CopyRow(label: 'Routing', value: w.routingNumber, mono: true),
                if (w.sortCode.isNotEmpty)
                  _CopyRow(label: 'Sort Code', value: w.sortCode, mono: true),
                if (w.swiftBic.isNotEmpty)
                  _CopyRow(label: 'SWIFT/BIC', value: w.swiftBic, mono: true),
                _CopyRow(label: 'Bank', value: w.bankName),
                if (w.accountType.isNotEmpty)
                  _CopyRow(
                      label: 'Acct Type',
                      value: _titleCase(w.accountType),
                      copyable: false),
                if ((w.upiId ?? '').isNotEmpty)
                  _CopyRow(label: 'UPI', value: w.upiId!),
              ],
            ),
          ),
          const SizedBox(height: 16),

          _Section(
            title: 'CONTACT',
            child: Column(
              children: [
                _CopyRow(label: 'Phone', value: w.phone, mono: true),
                _CopyRow(label: 'Email', value: w.email),
              ],
            ),
          ),
          const SizedBox(height: 16),

          _Section(
            title: 'LIFECYCLE',
            child: Column(
              children: [
                _InfoRow(label: 'Requested', value: w.formattedCreatedAt),
                if (w.formattedProcessingAt.isNotEmpty)
                  _InfoRow(label: 'Processing', value: w.formattedProcessingAt),
                if (w.formattedPaidAt.isNotEmpty)
                  _InfoRow(label: 'Sent', value: w.formattedPaidAt),
                if (w.reference != null)
                  _CopyRow(
                      label: 'Reference No.',
                      value: w.reference!,
                      mono: true),
                if (w.transactionId != null)
                  _CopyRow(
                      label: 'Transaction ID',
                      value: w.transactionId!,
                      mono: true),
                if (w.isOnHold && w.onHoldReason != null)
                  _InfoRow(label: 'On hold', value: w.onHoldReason!),
                if (w.formattedBlockedAt.isNotEmpty)
                  _InfoRow(label: 'Cancelled', value: w.formattedBlockedAt),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // This priest summary
          _PriestSummaryCard(
            name: w.bankAccountName,
            summary: _summary,
            onViewAll: () {
              Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => AdminPriestWithdrawalsPage(
                  priestId: w.priestId,
                  priestName: w.bankAccountName,
                ),
              ));
            },
          ),
          // Corrections for an already-sent payout.
          if (w.isPaid) ...[
            const SizedBox(height: 16),
            _Section(
              title: 'CORRECTIONS',
              child: Column(
                children: [
                  _ActionRow(
                    label: 'Edit reference / transaction ID',
                    sub: 'Fix a typo in the reference number or '
                        'transaction ID',
                    icon: AppIcons.tag,
                    onTap: _editReference,
                  ),
                  const SizedBox(height: 4),
                  _ActionRow(
                    label: 'Reverse to Processing',
                    sub: 'Marked Sent by mistake (does not un-send money)',
                    icon: AppIcons.replay,
                    color: const Color(0xFFC2410C),
                    onTap: _reverse,
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 24),

          _ReceiptButton(onTap: _downloadReceipt),
        ],
      ),
    );
  }
}

// A tappable label+subtitle row used in the CORRECTIONS section.
class _ActionRow extends StatelessWidget {
  final String label;
  final String sub;
  final IconData icon;
  final Color? color;
  final VoidCallback onTap;
  const _ActionRow({
    required this.label,
    required this.sub,
    required this.icon,
    required this.onTap,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final c = color ?? AdminColors.brandBrown;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            AppIcon(icon, size: 16, color: c),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: GoogleFonts.inter(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                      color: c,
                    ),
                  ),
                  const SizedBox(height: 1),
                  Text(
                    sub,
                    style: GoogleFonts.inter(
                      fontSize: 11.5,
                      color: AdminColors.textMuted,
                    ),
                  ),
                ],
              ),
            ),
            AppIcon(AppIcons.chevronRight, size: 15, color: AdminColors.textLight),
          ],
        ),
      ),
    );
  }
}

// Edit reference + transaction ID (both prefilled). Returns
// (referenceNumber, transactionId); reference is required.
class _EditReferenceDialog extends StatefulWidget {
  final String currentReference;
  final String currentTransactionId;
  const _EditReferenceDialog({
    required this.currentReference,
    required this.currentTransactionId,
  });

  @override
  State<_EditReferenceDialog> createState() => _EditReferenceDialogState();
}

class _EditReferenceDialogState extends State<_EditReferenceDialog> {
  late final TextEditingController _ref =
      TextEditingController(text: widget.currentReference);
  late final TextEditingController _txn =
      TextEditingController(text: widget.currentTransactionId);
  String? _error;

  @override
  void dispose() {
    _ref.dispose();
    _txn.dispose();
    super.dispose();
  }

  InputDecoration _dec(String hint, [String? error]) => InputDecoration(
        hintText: hint,
        isDense: true,
        errorText: error,
        border: const OutlineInputBorder(),
      );

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: Colors.white,
      title: Text('Edit reference / transaction ID',
          style: GoogleFonts.inter(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: AdminColors.textPrimary)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Reference Number',
              style: GoogleFonts.inter(
                  fontSize: 12, fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          TextField(
            controller: _ref,
            autofocus: true,
            textCapitalization: TextCapitalization.characters,
            style: GoogleFonts.robotoMono(fontSize: 14),
            onChanged: (_) {
              if (_error != null) setState(() => _error = null);
            },
            decoration: _dec('UTR / wire reference', _error),
          ),
          const SizedBox(height: 12),
          Text('Transaction ID (optional)',
              style: GoogleFonts.inter(
                  fontSize: 12, fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          TextField(
            controller: _txn,
            textCapitalization: TextCapitalization.characters,
            style: GoogleFonts.robotoMono(fontSize: 14),
            decoration: _dec('Bank Transaction ID, if any'),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () {
            final r = _ref.text.trim();
            if (r.isEmpty) {
              setState(() => _error = 'Reference number is required');
              return;
            }
            Navigator.of(context).pop((r, _txn.text.trim()));
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}

class _ReverseDialog extends StatelessWidget {
  const _ReverseDialog();

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: Colors.white,
      title: Text('Reverse to Processing?',
          style: GoogleFonts.inter(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: AdminColors.textPrimary)),
      content: Text(
        'This moves the payout back to Processing and clears the Sent '
        'reference. Use only if you marked it Sent by mistake — it does '
        'NOT pull back money already wired.',
        style: GoogleFonts.inter(
            fontSize: 13, color: AdminColors.textBody, height: 1.45),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Reverse'),
        ),
      ],
    );
  }
}

// ─── Pieces ────────────────────────────────────────────────────

class _Section extends StatelessWidget {
  final String title;
  final Widget child;
  const _Section({required this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
      decoration: AdminColors.cardDecoration,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: GoogleFonts.inter(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.5,
              color: AdminColors.textMuted,
            ),
          ),
          const SizedBox(height: 4),
          child,
        ],
      ),
    );
  }
}

class _CopyRow extends StatefulWidget {
  final String label;
  final String value;
  final bool mono;
  final bool copyable;
  const _CopyRow({
    required this.label,
    required this.value,
    this.mono = false,
    this.copyable = true,
  });

  @override
  State<_CopyRow> createState() => _CopyRowState();
}

class _CopyRowState extends State<_CopyRow> {
  bool _copied = false;

  @override
  Widget build(BuildContext context) {
    final valueStyle = widget.mono
        ? GoogleFonts.robotoMono(
            fontSize: 13.5,
            fontWeight: FontWeight.w500,
            color: AdminColors.textPrimary,
            letterSpacing: 0.3,
          )
        : GoogleFonts.inter(
            fontSize: 13.5,
            fontWeight: FontWeight.w500,
            color: AdminColors.textPrimary,
          );
    final showCopy = widget.copyable && widget.value.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 9),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 92,
            child: Text(
              widget.label,
              style: GoogleFonts.inter(
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                color: AdminColors.textMuted,
              ),
            ),
          ),
          Expanded(
            child: Text(widget.value.isEmpty ? '—' : widget.value,
                style: valueStyle),
          ),
          if (showCopy) ...[
            const SizedBox(width: 8),
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () async {
                await Clipboard.setData(ClipboardData(text: widget.value));
                if (!mounted) return;
                setState(() => _copied = true);
                Future.delayed(const Duration(milliseconds: 1400), () {
                  if (mounted) setState(() => _copied = false);
                });
              },
              child: AppIcon(
                _copied ? AppIcons.check : AppIcons.copy,
                size: 15,
                color: _copied ? AdminColors.success : AdminColors.textMuted,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  const _InfoRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 9),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 92,
            child: Text(
              label,
              style: GoogleFonts.inter(
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                color: AdminColors.textMuted,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value.isEmpty ? '—' : value,
              style: GoogleFonts.inter(
                fontSize: 13.5,
                fontWeight: FontWeight.w500,
                color: AdminColors.textPrimary,
                height: 1.35,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PriestSummaryCard extends StatelessWidget {
  final String name;
  final PriestWithdrawalSummary? summary;
  final VoidCallback onViewAll;
  const _PriestSummaryCard({
    required this.name,
    required this.summary,
    required this.onViewAll,
  });

  @override
  Widget build(BuildContext context) {
    final s = summary;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: AdminColors.cardDecoration,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'THIS PRIEST',
            style: GoogleFonts.inter(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.5,
              color: AdminColors.textMuted,
            ),
          ),
          const SizedBox(height: 8),
          if (s == null)
            Text(
              'Loading $name’s history…',
              style: GoogleFonts.inter(
                fontSize: 13,
                color: AdminColors.textMuted,
              ),
            )
          else ...[
            Text(
              '$name · ${s.total} withdrawal${s.total == 1 ? '' : 's'}',
              style: GoogleFonts.inter(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: AdminColors.textPrimary,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '₹${s.paidAmount} sent · ₹${s.inFlightAmount} in progress'
              '${s.pending > 0 ? ' · ${s.pending} pending' : ''}',
              style: GoogleFonts.inter(
                fontSize: 12.5,
                color: AdminColors.textBody,
              ),
            ),
          ],
          const SizedBox(height: 12),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onViewAll,
            child: Row(
              children: [
                Text(
                  'View all from this priest',
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: AdminColors.brandBrown,
                  ),
                ),
                const SizedBox(width: 3),
                AppIcon(AppIcons.chevronRight,
                    size: 16, color: AdminColors.brandBrown),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ReceiptButton extends StatelessWidget {
  final VoidCallback onTap;
  const _ReceiptButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        height: 50,
        decoration: BoxDecoration(
          color: AdminColors.brandBrown,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const AppIcon(AppIcons.download, size: 16, color: Colors.white),
              const SizedBox(width: 8),
              Text(
                'Download Receipt',
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  final String status;
  const _StatusBadge({required this.status});

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
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration:
          BoxDecoration(color: bg, borderRadius: BorderRadius.circular(8)),
      child: Text(
        label,
        style: GoogleFonts.inter(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: fg,
        ),
      ),
    );
  }
}
