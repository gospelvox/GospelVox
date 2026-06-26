// Admin Revenue page — a clear, at-a-glance breakdown of platform
// earnings. Shows the total the platform keeps, where it comes from
// (calls/chats, bible sessions, activation fees), the gross-vs-store-
// fee picture, top earning speakers, and recent revenue activity.
//
// Period (Today / Week / Month / All) is local UI state: the data is
// fetched once and every figure is recomputed client-side, so toggling
// periods is instant.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shimmer/shimmer.dart';

import 'package:gospel_vox/core/services/injection_container.dart';
import 'package:gospel_vox/core/theme/admin_colors.dart';
import 'package:gospel_vox/core/widgets/app_icons.dart';
import 'package:gospel_vox/core/widgets/app_snackbar.dart';
import 'package:gospel_vox/features/admin/revenue/bloc/revenue_cubit.dart';
import 'package:gospel_vox/features/admin/revenue/bloc/revenue_state.dart';
import 'package:gospel_vox/features/admin/revenue/data/revenue_export.dart';
import 'package:gospel_vox/features/admin/revenue/data/revenue_models.dart';

final NumberFormat _inr =
    NumberFormat.currency(locale: 'en_IN', symbol: '₹', decimalDigits: 0);

String _money(num v) => _inr.format(v);

// Per-source colour + icon, used by the breakdown bars and the recent
// list so a source always reads the same way.
Color _sourceColor(RevenueSource s) {
  switch (s) {
    case RevenueSource.callChat:
      return AdminColors.info;
    case RevenueSource.bible:
      return AdminColors.warning;
    case RevenueSource.activation:
      return AdminColors.success;
  }
}

IconData _sourceIcon(RevenueSource s) {
  switch (s) {
    case RevenueSource.callChat:
      return AppIcons.chat;
    case RevenueSource.bible:
      return AppIcons.bible;
    case RevenueSource.activation:
      return AppIcons.badge;
  }
}

// ═══════════════════════════════════════════════════════════════════
// Page
// ═══════════════════════════════════════════════════════════════════

class RevenuePage extends StatelessWidget {
  const RevenuePage({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) => sl<RevenueCubit>()..loadRevenue(),
      child: Scaffold(
        backgroundColor: AdminColors.background,
        appBar: AppBar(
          backgroundColor: AdminColors.cardSurface,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0.5,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back_ios_new,
                size: 18, color: AdminColors.textPrimary),
            onPressed: () =>
                context.canPop() ? context.pop() : context.go('/admin'),
          ),
          title: Text('Revenue',
              style: GoogleFonts.inter(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  color: AdminColors.textPrimary)),
          centerTitle: false,
          actions: const [_ExportButton(), SizedBox(width: 4)],
        ),
        body: SafeArea(
          top: false,
          child: BlocConsumer<RevenueCubit, RevenueState>(
            listener: (context, state) {},
            builder: (context, state) {
              if (state is RevenueLoaded) {
                return _Content(data: state.data);
              }
              if (state is RevenueError) {
                return _ErrorView(
                  message: state.message,
                  onRetry: () =>
                      context.read<RevenueCubit>().loadRevenue(),
                );
              }
              return const _ShimmerView();
            },
          ),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════
// Export button — writes a CSV (opens in Excel / Sheets) and shares it
// ═══════════════════════════════════════════════════════════════════

class _ExportButton extends StatefulWidget {
  const _ExportButton();

  @override
  State<_ExportButton> createState() => _ExportButtonState();
}

class _ExportButtonState extends State<_ExportButton> {
  bool _busy = false;

  Future<void> _export() async {
    final cubitState = context.read<RevenueCubit>().state;
    if (cubitState is! RevenueLoaded) {
      AppSnackBar.info(context, 'Revenue is still loading…');
      return;
    }

    setState(() => _busy = true);
    try {
      final now = DateTime.now();
      final bytes = buildRevenueXlsx(cubitState.data, now);
      final fileName = revenueXlsxFileName(now);

      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/$fileName');
      await file.writeAsBytes(bytes);

      await SharePlus.instance.share(
        ShareParams(
          files: [
            XFile(
              file.path,
              mimeType:
                  'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
              name: fileName,
            ),
          ],
          subject: 'Gospel Vox — Revenue export',
          text: 'Revenue export from Gospel Vox.',
        ),
      );
    } catch (e) {
      if (mounted) {
        AppSnackBar.error(context, 'Export failed. Please try again.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: 'Export to spreadsheet',
      onPressed: _busy ? null : _export,
      icon: _busy
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: AdminColors.brandBrown,
              ),
            )
          : const Icon(Icons.file_download_outlined,
              size: 22, color: AdminColors.brandBrown),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════
// Content (holds the selected period)
// ═══════════════════════════════════════════════════════════════════

class _Content extends StatefulWidget {
  final RevenueData data;
  const _Content({required this.data});

  @override
  State<_Content> createState() => _ContentState();
}

class _ContentState extends State<_Content> {
  RevenuePeriod _period = RevenuePeriod.all;

  @override
  Widget build(BuildContext context) {
    final data = widget.data;
    final now = DateTime.now();

    final total = data.totalFor(_period, now);
    final callChat = data.sourceTotal(RevenueSource.callChat, _period, now);
    final bible = data.sourceTotal(RevenueSource.bible, _period, now);
    final activation =
        data.sourceTotal(RevenueSource.activation, _period, now);
    final gross = data.grossSalesFor(_period, now);
    final recent = data.recentIn(_period, now);

    return RefreshIndicator(
      color: AdminColors.brandBrown,
      onRefresh: () => context.read<RevenueCubit>().refreshRevenue(),
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(
          parent: ClampingScrollPhysics(),
        ),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 40),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _PeriodSelector(
              selected: _period,
              onChanged: (p) => setState(() => _period = p),
            ),
            const SizedBox(height: 16),
            _HeroCard(
              total: total,
              period: _period,
              storeCutPercent: data.storeCutPercent,
            ),
            const SizedBox(height: 20),
            _SectionLabel('WHERE IT COMES FROM'),
            const SizedBox(height: 8),
            _BreakdownCard(
              total: total,
              rows: [
                _BreakdownRow(RevenueSource.callChat, callChat),
                _BreakdownRow(RevenueSource.bible, bible),
                _BreakdownRow(RevenueSource.activation, activation),
              ],
            ),
            const SizedBox(height: 20),
            _SectionLabel('MONEY FLOW'),
            const SizedBox(height: 8),
            _StoreFeeCard(
              gross: gross,
              revenue: total,
              storeCutPercent: data.storeCutPercent,
              period: _period,
            ),
            const SizedBox(height: 20),
            _SectionLabel('SPEAKERS'),
            const SizedBox(height: 8),
            const _ViewSpeakersButton(),
            const SizedBox(height: 20),
            _SectionLabel('RECENT REVENUE'),
            const SizedBox(height: 8),
            _RecentCard(recent: recent),
          ],
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════
// Period selector
// ═══════════════════════════════════════════════════════════════════

class _PeriodSelector extends StatelessWidget {
  final RevenuePeriod selected;
  final ValueChanged<RevenuePeriod> onChanged;
  const _PeriodSelector({required this.selected, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: AdminColors.inputBackground,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: RevenuePeriod.values.map((p) {
          final active = p == selected;
          return Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => onChanged(p),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                padding: const EdgeInsets.symmetric(vertical: 9),
                decoration: BoxDecoration(
                  color: active ? AdminColors.brandBrown : Colors.transparent,
                  borderRadius: BorderRadius.circular(9),
                ),
                alignment: Alignment.center,
                child: Text(
                  p.label,
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: active ? Colors.white : AdminColors.textMuted,
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════
// Hero — total revenue
// ═══════════════════════════════════════════════════════════════════

class _HeroCard extends StatelessWidget {
  final double total;
  final RevenuePeriod period;
  final int storeCutPercent;
  const _HeroCard({
    required this.total,
    required this.period,
    required this.storeCutPercent,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF6B3A2A), Color(0xFF8A4B33)],
        ),
        boxShadow: const [
          BoxShadow(
            color: Color(0x1A6B3A2A),
            blurRadius: 14,
            offset: Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const AppIcon(AppIcons.trendingUp,
                  size: 16, color: AdminColors.brandGold),
              const SizedBox(width: 6),
              Text(
                'Total Revenue · ${period.longLabel}',
                style: GoogleFonts.inter(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: Colors.white.withValues(alpha: 0.85),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            _money(total),
            style: GoogleFonts.inter(
              fontSize: 36,
              fontWeight: FontWeight.w800,
              color: Colors.white,
              height: 1.05,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'What the platform keeps — commission from calls, chats & '
            'bible sessions, plus speaker activation fees.',
            style: GoogleFonts.inter(
              fontSize: 11.5,
              fontWeight: FontWeight.w400,
              color: Colors.white.withValues(alpha: 0.78),
              height: 1.35,
            ),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════
// Breakdown by source
// ═══════════════════════════════════════════════════════════════════

class _BreakdownRow {
  final RevenueSource source;
  final double amount;
  _BreakdownRow(this.source, this.amount);
}

class _BreakdownCard extends StatelessWidget {
  final double total;
  final List<_BreakdownRow> rows;
  const _BreakdownCard({required this.total, required this.rows});

  @override
  Widget build(BuildContext context) {
    final sorted = [...rows]..sort((a, b) => b.amount.compareTo(a.amount));

    if (total <= 0) {
      return _EmptyCard(
        icon: AppIcons.trendingUp,
        text: 'No revenue in this period yet.',
      );
    }

    return Container(
      decoration: AdminColors.cardDecoration,
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          for (var i = 0; i < sorted.length; i++) ...[
            _breakdownTile(sorted[i]),
            if (i != sorted.length - 1) const SizedBox(height: 16),
          ],
        ],
      ),
    );
  }

  Widget _breakdownTile(_BreakdownRow row) {
    final color = _sourceColor(row.source);
    final fraction = total > 0 ? (row.amount / total).clamp(0.0, 1.0) : 0.0;
    final pct = (fraction * 100).round();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(9),
              ),
              alignment: Alignment.center,
              child: AppIcon(_sourceIcon(row.source), size: 16, color: color),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                row.source.label,
                style: GoogleFonts.inter(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                  color: AdminColors.textPrimary,
                ),
              ),
            ),
            Text(
              _money(row.amount),
              style: GoogleFonts.inter(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: AdminColors.textPrimary,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: Container(
                  height: 6,
                  color: AdminColors.inputBackground,
                  child: FractionallySizedBox(
                    alignment: Alignment.centerLeft,
                    widthFactor: fraction == 0 ? 0.02 : fraction,
                    child: Container(color: color),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),
            SizedBox(
              width: 34,
              child: Text(
                '$pct%',
                textAlign: TextAlign.right,
                style: GoogleFonts.inter(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: AdminColors.textMuted,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

// ═══════════════════════════════════════════════════════════════════
// Money flow — gross sales vs store fee
// ═══════════════════════════════════════════════════════════════════

class _StoreFeeCard extends StatelessWidget {
  final double gross;
  final double revenue;
  final int storeCutPercent;
  final RevenuePeriod period;
  const _StoreFeeCard({
    required this.gross,
    required this.revenue,
    required this.storeCutPercent,
    required this.period,
  });

  @override
  Widget build(BuildContext context) {
    final afterFee = gross * (1 - storeCutPercent / 100);

    return Container(
      decoration: AdminColors.cardDecoration,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: _flowMetric(
                  'Customers paid',
                  _money(gross),
                  AdminColors.textPrimary,
                ),
              ),
              Container(width: 1, height: 36, color: AdminColors.borderLight),
              Expanded(
                child: _flowMetric(
                  'You received (est.)',
                  _money(afterFee),
                  AdminColors.success,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(11),
            decoration: BoxDecoration(
              color: AdminColors.warningBg,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const AppIcon(AppIcons.info,
                    size: 15, color: AdminColors.warning),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Google Play / Apple keep about $storeCutPercent% of '
                    'every in-app payment, so the gross above is before '
                    'their fee. This is an estimate.',
                    style: GoogleFonts.inter(
                      fontSize: 11,
                      fontWeight: FontWeight.w400,
                      color: AdminColors.textBody,
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _flowMetric(String label, String value, Color valueColor) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: GoogleFonts.inter(
            fontSize: 11,
            fontWeight: FontWeight.w500,
            color: AdminColors.textMuted,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: GoogleFonts.inter(
            fontSize: 18,
            fontWeight: FontWeight.w800,
            color: valueColor,
          ),
        ),
      ],
    );
  }
}

// ═══════════════════════════════════════════════════════════════════
// Speakers — a simple link into the speakers area. Deliberately shows
// NO per-speaker earnings here; just a way to open the speakers list.
// ═══════════════════════════════════════════════════════════════════

class _ViewSpeakersButton extends StatefulWidget {
  const _ViewSpeakersButton();

  @override
  State<_ViewSpeakersButton> createState() => _ViewSpeakersButtonState();
}

class _ViewSpeakersButtonState extends State<_ViewSpeakersButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      onTap: () => context.push('/admin/speakers'),
      child: AnimatedScale(
        scale: _pressed ? 0.98 : 1.0,
        duration: const Duration(milliseconds: 80),
        child: Container(
          decoration: AdminColors.cardDecoration,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          child: Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: AdminColors.brandBrown.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(10),
                ),
                alignment: Alignment.center,
                child: const AppIcon(AppIcons.users,
                    size: 19, color: AdminColors.brandBrown),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'View Speakers',
                      style: GoogleFonts.inter(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: AdminColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Open the speakers list & profiles',
                      style: GoogleFonts.inter(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w400,
                        color: AdminColors.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
              const AppIcon(AppIcons.arrowRight,
                  size: 16, color: AdminColors.textLight),
            ],
          ),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════
// Recent revenue
// ═══════════════════════════════════════════════════════════════════

class _RecentCard extends StatelessWidget {
  final List<RevenueTxn> recent;
  const _RecentCard({required this.recent});

  static final DateFormat _df = DateFormat('MMM d, h:mm a');

  @override
  Widget build(BuildContext context) {
    if (recent.isEmpty) {
      return _EmptyCard(
        icon: AppIcons.wallet,
        text: 'No revenue in this period yet.',
      );
    }

    return Container(
      decoration: AdminColors.cardDecoration,
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        children: [
          for (var i = 0; i < recent.length; i++)
            _row(recent[i], last: i == recent.length - 1),
        ],
      ),
    );
  }

  Widget _row(RevenueTxn t, {required bool last}) {
    final color = _sourceColor(t.source);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        border: last
            ? null
            : const Border(
                bottom: BorderSide(color: AdminColors.borderLight),
              ),
      ),
      child: Row(
        children: [
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(9),
            ),
            alignment: Alignment.center,
            child: AppIcon(_sourceIcon(t.source), size: 15, color: color),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  t.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: AdminColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  t.at != null ? _df.format(t.at!) : '—',
                  style: GoogleFonts.inter(
                    fontSize: 11,
                    fontWeight: FontWeight.w400,
                    color: AdminColors.textLight,
                  ),
                ),
              ],
            ),
          ),
          Text(
            '+${_money(t.amount)}',
            style: GoogleFonts.inter(
              fontSize: 13.5,
              fontWeight: FontWeight.w700,
              color: AdminColors.success,
            ),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════
// Shared bits
// ═══════════════════════════════════════════════════════════════════

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 2),
      child: Text(
        text,
        style: GoogleFonts.inter(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: AdminColors.textLight,
          letterSpacing: 0.8,
        ),
      ),
    );
  }
}

class _EmptyCard extends StatelessWidget {
  final IconData icon;
  final String text;
  const _EmptyCard({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: AdminColors.cardDecoration,
      padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 16),
      child: Column(
        children: [
          AppIcon(icon, size: 28, color: AdminColors.textLight),
          const SizedBox(height: 10),
          Text(
            text,
            textAlign: TextAlign.center,
            style: GoogleFonts.inter(
              fontSize: 12.5,
              fontWeight: FontWeight.w400,
              color: AdminColors.textMuted,
            ),
          ),
        ],
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
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const AppIcon(AppIcons.cloudOff,
              size: 48, color: AdminColors.textLight),
          const SizedBox(height: 16),
          Text(
            message,
            style: GoogleFonts.inter(
              fontSize: 14,
              fontWeight: FontWeight.w400,
              color: AdminColors.textMuted,
            ),
          ),
          const SizedBox(height: 24),
          TextButton.icon(
            icon: const AppIcon(AppIcons.refresh,
                color: AdminColors.brandBrown),
            label: Text(
              'Try Again',
              style: GoogleFonts.inter(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: AdminColors.brandBrown,
              ),
            ),
            onPressed: onRetry,
          ),
        ],
      ),
    );
  }
}

class _ShimmerView extends StatelessWidget {
  const _ShimmerView();

  static BoxDecoration _box() => BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
      );

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 40),
      child: Shimmer.fromColors(
        baseColor: const Color(0xFFE5E7EB),
        highlightColor: const Color(0xFFF3F4F6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(height: 44, decoration: _box()),
            const SizedBox(height: 16),
            Container(height: 150, decoration: _box()),
            const SizedBox(height: 20),
            Container(height: 160, decoration: _box()),
            const SizedBox(height: 20),
            Container(height: 110, decoration: _box()),
            const SizedBox(height: 20),
            Container(height: 200, decoration: _box()),
          ],
        ),
      ),
    );
  }
}
