// Priest "My Withdrawals" — the transparency screen. Each withdrawal is
// a tracker card showing the Requested -> Processing -> Sent timeline
// with dates, the bank reference (with copy) once sent, a reason + "Fix
// now" when on hold, and a refund note when cancelled. Same status
// words the admin sees, so nothing is hidden from the priest.

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:gospel_vox/core/services/injection_container.dart';
import 'package:gospel_vox/core/theme/app_colors.dart';
import 'package:gospel_vox/core/widgets/app_back_button.dart';
import 'package:gospel_vox/core/widgets/app_snackbar.dart';
import 'package:gospel_vox/core/widgets/app_icons.dart';
import 'package:gospel_vox/features/priest/wallet/bloc/priest_withdrawals_cubit.dart';
import 'package:gospel_vox/features/priest/wallet/data/priest_wallet_repository.dart';
import 'package:gospel_vox/features/priest/wallet/data/wallet_models.dart';
import 'package:gospel_vox/features/priest/wallet/data/withdrawal_status.dart';
import 'package:gospel_vox/features/priest/wallet/data/withdrawal_timeline.dart';
import 'package:gospel_vox/core/widgets/app_loading_widget.dart';

const Color _kGreen = AppColors.successGreen;

class WithdrawalStatusPage extends StatelessWidget {
  const WithdrawalStatusPage({super.key});

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    return BlocProvider(
      create: (_) {
        final cubit = PriestWithdrawalsCubit(sl<PriestWalletRepository>());
        if (uid != null) cubit.load(uid);
        return cubit;
      },
      child: _WithdrawalStatusView(uid: uid),
    );
  }
}

class _WithdrawalStatusView extends StatelessWidget {
  final String? uid;
  const _WithdrawalStatusView({required this.uid});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
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
          'My Withdrawals',
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
      ),
      body: BlocBuilder<PriestWithdrawalsCubit, PriestWithdrawalsState>(
        builder: (context, state) {
          return switch (state) {
            PriestWithdrawalsLoading() => const Center(
                child: AppLoader(),
              ),
            PriestWithdrawalsError(:final message) => _ErrorBody(
                message: message,
                onRetry: () {
                  final id = uid;
                  if (id != null) {
                    context.read<PriestWithdrawalsCubit>().load(id);
                  }
                },
              ),
            PriestWithdrawalsLoaded(:final items) => _ListBody(
                items: items,
                uid: uid,
              ),
          };
        },
      ),
    );
  }
}

class _ListBody extends StatelessWidget {
  final List<WithdrawalRecord> items;
  final String? uid;
  const _ListBody({required this.items, required this.uid});

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return RefreshIndicator(
        color: AppColors.primaryBrown,
        onRefresh: () async {
          final id = uid;
          if (id != null) {
            await context.read<PriestWithdrawalsCubit>().refresh(id);
          }
        },
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(
            parent: BouncingScrollPhysics(),
          ),
          children: [
            SizedBox(
              height: MediaQuery.of(context).size.height * 0.65,
              child: const _EmptyBody(),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      color: AppColors.primaryBrown,
      onRefresh: () async {
        final id = uid;
        if (id != null) {
          await context.read<PriestWithdrawalsCubit>().refresh(id);
        }
      },
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(
          parent: BouncingScrollPhysics(),
        ),
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
        itemCount: items.length,
        itemBuilder: (_, i) => Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: _WithdrawalCard(record: items[i], uid: uid),
        ),
      ),
    );
  }
}

// ─── Card ──────────────────────────────────────────────────────

class _WithdrawalCard extends StatelessWidget {
  final WithdrawalRecord record;
  final String? uid;
  const _WithdrawalCard({required this.record, required this.uid});

  @override
  Widget build(BuildContext context) {
    final r = record;
    final stages = buildWithdrawalTimeline(r);

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.surfaceWhite,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.muted.withValues(alpha: 0.08)),
        boxShadow: [
          BoxShadow(
            blurRadius: 10,
            offset: const Offset(0, 3),
            color: Colors.black.withValues(alpha: 0.03),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  _money(r.amount),
                  style: GoogleFonts.inter(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    color: AppColors.deepDarkBrown,
                    letterSpacing: -0.4,
                  ),
                ),
              ),
              _StatusBadge(status: r.status),
            ],
          ),
          const SizedBox(height: 16),
          // Timeline
          for (int i = 0; i < stages.length; i++)
            _TimelineStep(stage: stages[i], isLast: i == stages.length - 1),
          // Reference (once sent)
          if (r.status == WithdrawalStatus.paid && r.reference != null) ...[
            const SizedBox(height: 6),
            _ReferenceRow(
              reference: r.reference!,
              transactionId: r.transactionId,
            ),
          ],
          // Fix-now (on hold)
          if (r.status == WithdrawalStatus.onHold) ...[
            const SizedBox(height: 14),
            _FixNowButton(uid: uid),
          ],
        ],
      ),
    );
  }
}

class _TimelineStep extends StatelessWidget {
  final WithdrawalStage stage;
  final bool isLast;
  const _TimelineStep({required this.stage, required this.isLast});

  @override
  Widget build(BuildContext context) {
    final isDone = stage.state == WithdrawalStageState.done;
    final isCurrent = stage.state == WithdrawalStageState.current;
    final dotColor = isDone
        ? _kGreen
        : isCurrent
            ? AppColors.primaryBrown
            : AppColors.muted.withValues(alpha: 0.3);
    final labelColor = stage.state == WithdrawalStageState.upcoming
        ? AppColors.muted.withValues(alpha: 0.6)
        : AppColors.deepDarkBrown;

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Dot + connector rail
          Column(
            children: [
              Container(
                width: 18,
                height: 18,
                margin: const EdgeInsets.only(top: 1),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isDone || isCurrent
                      ? dotColor
                      : Colors.transparent,
                  border: Border.all(color: dotColor, width: 2),
                ),
                child: isDone
                    ? const AppIcon(AppIcons.check,
                        size: 11, color: Colors.white)
                    : null,
              ),
              if (!isLast)
                Expanded(
                  child: Container(
                    width: 2,
                    margin: const EdgeInsets.symmetric(vertical: 2),
                    color: isDone
                        ? _kGreen.withValues(alpha: 0.4)
                        : AppColors.muted.withValues(alpha: 0.15),
                  ),
                ),
            ],
          ),
          const SizedBox(width: 14),
          // Label + date + note
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(bottom: isLast ? 0 : 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          stage.label,
                          style: GoogleFonts.inter(
                            fontSize: 14,
                            fontWeight: isCurrent
                                ? FontWeight.w700
                                : FontWeight.w600,
                            color: labelColor,
                          ),
                        ),
                      ),
                      if (stage.at != null)
                        Text(
                          _fmtDate(stage.at),
                          style: GoogleFonts.inter(
                            fontSize: 11,
                            fontWeight: FontWeight.w400,
                            color: AppColors.muted,
                          ),
                        ),
                    ],
                  ),
                  if (stage.note != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      stage.note!,
                      style: GoogleFonts.inter(
                        fontSize: 12,
                        fontWeight: FontWeight.w400,
                        height: 1.4,
                        color: AppColors.muted,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ReferenceRow extends StatelessWidget {
  final String reference;
  final String? transactionId;
  const _ReferenceRow({required this.reference, this.transactionId});

  @override
  Widget build(BuildContext context) {
    final hasTxn = (transactionId ?? '').isNotEmpty;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: _kGreen.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _kGreen.withValues(alpha: 0.18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _RefLine(label: 'Reference Number', value: reference),
          if (hasTxn) ...[
            const SizedBox(height: 10),
            _RefLine(label: 'Transaction ID', value: transactionId!),
          ],
          const SizedBox(height: 8),
          Text(
            "If you haven't received it, contact your bank with "
            '${hasTxn ? 'these details' : 'this reference'}.',
            style: GoogleFonts.inter(
              fontSize: 11,
              fontWeight: FontWeight.w400,
              height: 1.4,
              color: AppColors.muted,
            ),
          ),
        ],
      ),
    );
  }
}

// One label + value + copy line inside the green reference box.
class _RefLine extends StatelessWidget {
  final String label;
  final String value;
  const _RefLine({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: GoogleFonts.inter(
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  color: AppColors.muted,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                value,
                style: GoogleFonts.robotoMono(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: AppColors.deepDarkBrown,
                ),
              ),
            ],
          ),
        ),
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            Clipboard.setData(ClipboardData(text: value));
            HapticFeedback.selectionClick();
            AppSnackBar.success(context, '$label copied');
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: AppColors.surfaceWhite,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: _kGreen.withValues(alpha: 0.3)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const AppIcon(AppIcons.copy, size: 13, color: _kGreen),
                const SizedBox(width: 5),
                Text(
                  'Copy',
                  style: GoogleFonts.inter(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: _kGreen,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _FixNowButton extends StatelessWidget {
  final String? uid;
  const _FixNowButton({required this.uid});

  Future<void> _fixNow(BuildContext context) async {
    final id = uid;
    if (id == null) return;
    // Pre-fill the bank form with the priest's current details so they
    // correct rather than re-type. If we can't load them, open a blank
    // form — still lets them fix the account.
    BankDetails? existing;
    try {
      existing = await sl<PriestWalletRepository>().fetchBankDetailsOnce(id);
    } catch (_) {
      existing = null;
    }
    if (!context.mounted) return;
    context.push('/priest/bank-details', extra: existing);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _fixNow(context),
      child: Container(
        width: double.infinity,
        height: 44,
        decoration: BoxDecoration(
          color: AppColors.primaryBrown,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Center(
          child: Text(
            'Fix Bank Details',
            style: GoogleFonts.inter(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: Colors.white,
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Status badge ──────────────────────────────────────────────

class _StatusBadge extends StatelessWidget {
  final WithdrawalStatus status;
  const _StatusBadge({required this.status});

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = switch (status) {
      WithdrawalStatus.pending => (
          const Color(0xFFFFF4E5),
          const Color(0xFFB26A00),
        ),
      WithdrawalStatus.processing => (
          const Color(0xFFE8F0FE),
          const Color(0xFF1A56DB),
        ),
      WithdrawalStatus.paid => (
          const Color(0xFFE7F4EC),
          _kGreen,
        ),
      WithdrawalStatus.onHold => (
          const Color(0xFFFFF1E6),
          const Color(0xFFC2410C),
        ),
      WithdrawalStatus.blocked => (
          const Color(0xFFFDECEC),
          const Color(0xFFB42318),
        ),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        status.label,
        style: GoogleFonts.inter(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: fg,
        ),
      ),
    );
  }
}

// ─── Empty / error ─────────────────────────────────────────────

class _EmptyBody extends StatelessWidget {
  const _EmptyBody();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            AppIcon(
              AppIcons.bank,
              size: 48,
              color: AppColors.muted.withValues(alpha: 0.2),
            ),
            const SizedBox(height: 16),
            Text(
              'No withdrawals yet',
              style: GoogleFonts.inter(
                fontSize: 15,
                fontWeight: FontWeight.w500,
                color: AppColors.muted,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'When you withdraw, you can track its status here.',
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(
                fontSize: 13,
                fontWeight: FontWeight.w400,
                color: AppColors.muted.withValues(alpha: 0.6),
              ),
            ),
          ],
        ),
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
            const AppIcon(AppIcons.error, size: 44, color: AppColors.errorRed),
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
            GestureDetector(
              onTap: onRetry,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 28, vertical: 12),
                decoration: BoxDecoration(
                  color: AppColors.primaryBrown,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  'Retry',
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

// ─── helpers ───────────────────────────────────────────────────

// The amount is always in the platform currency (₹) — 1 coin = ₹1 for
// every priest. A foreign priest is owed the ₹ value (the admin
// converts at the bank), so we never relabel it with the bank currency.
String _money(int amount) => '₹${_groupThousands(amount)}';

// Plain thousands grouping (1,234,567). Avoids an intl dependency, like
// the rest of the wallet code.
String _groupThousands(int v) {
  final s = v.toString();
  final buf = StringBuffer();
  for (int i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
    buf.write(s[i]);
  }
  return buf.toString();
}

String _fmtDate(DateTime? d) {
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
