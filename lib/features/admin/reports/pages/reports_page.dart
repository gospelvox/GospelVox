// Admin report management — read-only queue of user-submitted
// reports with a single mutating action (mark resolved with notes).
// Mirrors the Sessions monitor shell: tab pills with a count badge,
// shimmer placeholders, pull-to-refresh, modal detail sheet.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shimmer/shimmer.dart';

import 'package:gospel_vox/core/services/injection_container.dart';
import 'package:gospel_vox/core/theme/admin_colors.dart';
import 'package:gospel_vox/core/widgets/app_snackbar.dart';
import 'package:gospel_vox/features/admin/reports/bloc/admin_reports_cubit.dart';
import 'package:gospel_vox/features/admin/reports/bloc/admin_reports_state.dart';
import 'package:gospel_vox/features/admin/reports/data/report_model.dart';

const _kFilters = ['pending', 'resolved', 'all'];

class ReportsPage extends StatelessWidget {
  const ReportsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.dark,
      ),
      child: BlocProvider<AdminReportsCubit>(
        create: (_) =>
            sl<AdminReportsCubit>()..loadReports('pending'),
        child: const _AdminReportsView(),
      ),
    );
  }
}

class _AdminReportsView extends StatefulWidget {
  const _AdminReportsView();

  @override
  State<_AdminReportsView> createState() => _AdminReportsViewState();
}

class _AdminReportsViewState extends State<_AdminReportsView>
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
    context.read<AdminReportsCubit>().loadReports(filter);
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
      body: BlocConsumer<AdminReportsCubit, AdminReportsState>(
        listener: (ctx, state) {
          if (state is AdminReportsError) {
            AppSnackBar.error(ctx, state.message);
          }
        },
        builder: (ctx, state) {
          if (state is AdminReportsError) {
            return _ErrorView(
              message: state.message,
              onRetry: () => ctx
                  .read<AdminReportsCubit>()
                  .loadReports(_kFilters[_tabController.index]),
            );
          }
          if (state is AdminReportsLoaded) {
            return _ReportsList(
              reports: state.reports,
              filter: state.filter,
              onRefresh: () => ctx
                  .read<AdminReportsCubit>()
                  .loadReports(state.filter),
              onTap: (r) => _openDetail(ctx, r),
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
        'Reports',
        style: GoogleFonts.inter(
          fontSize: 18,
          fontWeight: FontWeight.w600,
          color: AdminColors.textPrimary,
        ),
      ),
      centerTitle: false,
      bottom: PreferredSize(
        preferredSize: const Size.fromHeight(60),
        child: BlocBuilder<AdminReportsCubit, AdminReportsState>(
          buildWhen: (prev, curr) =>
              prev.runtimeType != curr.runtimeType ||
              (prev is AdminReportsLoaded &&
                  curr is AdminReportsLoaded &&
                  prev.pendingCount != curr.pendingCount),
          builder: (_, state) {
            final pendingCount = state is AdminReportsLoaded
                ? state.pendingCount
                : 0;
            return _TabBarPill(
              controller: _tabController,
              pendingCount: pendingCount,
            );
          },
        ),
      ),
    );
  }

  Future<void> _openDetail(BuildContext ctx, ReportModel r) async {
    await showModalBottomSheet<void>(
      context: ctx,
      backgroundColor: Colors.white,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetCtx) => BlocProvider.value(
        // Reuse the existing cubit so the sheet's resolve action
        // updates the same state the list is reading from.
        value: ctx.read<AdminReportsCubit>(),
        child: _ReportDetailSheet(report: r),
      ),
    );
  }
}

// ─── Tab bar ────────────────────────────────────────────────────

class _TabBarPill extends StatelessWidget {
  final TabController controller;
  final int pendingCount;

  const _TabBarPill({
    required this.controller,
    required this.pendingCount,
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
          labelStyle: GoogleFonts.inter(
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
          unselectedLabelColor: AdminColors.textMuted,
          unselectedLabelStyle: GoogleFonts.inter(
            fontSize: 13,
            fontWeight: FontWeight.w500,
          ),
          tabs: [
            _TabLabel(
              label: 'Pending',
              count: pendingCount,
              urgent: true,
            ),
            const _TabLabel(label: 'Resolved', count: 0),
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
  // Urgent tabs (Pending) get the warning-coloured badge so the
  // admin's eye lands on the queue that needs work.
  final bool urgent;
  const _TabLabel({
    required this.label,
    required this.count,
    this.urgent = false,
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
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 6,
                vertical: 2,
              ),
              decoration: BoxDecoration(
                color: urgent
                    ? AdminColors.warning
                    : AdminColors.textLight,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                count > 99 ? '99+' : count.toString(),
                style: GoogleFonts.inter(
                  fontSize: 10,
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

// ─── List body ─────────────────────────────────────────────────

class _ReportsList extends StatelessWidget {
  final List<ReportModel> reports;
  final String filter;
  final Future<void> Function() onRefresh;
  final void Function(ReportModel) onTap;

  const _ReportsList({
    required this.reports,
    required this.filter,
    required this.onRefresh,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    if (reports.isEmpty) {
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
        itemCount: reports.length,
        itemBuilder: (_, i) => _ReportCard(
          report: reports[i],
          onTap: () => onTap(reports[i]),
        ),
      ),
    );
  }
}

// ─── Report card ───────────────────────────────────────────────

class _ReportCard extends StatefulWidget {
  final ReportModel report;
  final VoidCallback onTap;
  const _ReportCard({required this.report, required this.onTap});

  @override
  State<_ReportCard> createState() => _ReportCardState();
}

class _ReportCardState extends State<_ReportCard> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final r = widget.report;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _pressed ? 0.98 : 1.0,
        duration: const Duration(milliseconds: 120),
        child: Container(
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          padding: const EdgeInsets.all(14),
          decoration: AdminColors.cardDecoration,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '${r.reporterName} reported ${r.reportedUserName}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.inter(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: AdminColors.textPrimary,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  _ReportStatusBadge(status: r.status),
                ],
              ),
              if (r.reason.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  r.reason,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.inter(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: AdminColors.textBody,
                  ),
                ),
              ],
              if (r.description.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  r.description,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.inter(
                    fontSize: 12,
                    fontWeight: FontWeight.w400,
                    color: AdminColors.textMuted,
                    height: 1.4,
                  ),
                ),
              ],
              if (r.formattedCreatedAt.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  r.formattedCreatedAt,
                  style: GoogleFonts.inter(
                    fontSize: 11,
                    fontWeight: FontWeight.w400,
                    color: AdminColors.textLight,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _ReportStatusBadge extends StatelessWidget {
  final String status;
  const _ReportStatusBadge({required this.status});

  @override
  Widget build(BuildContext context) {
    final (bg, fg, label) = switch (status) {
      'resolved' => (
          AdminColors.successBg,
          AdminColors.success,
          'Resolved'
        ),
      _ => (
          AdminColors.warningBg,
          AdminColors.warning,
          'Pending'
        ),
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

// ─── Detail sheet ──────────────────────────────────────────────

class _ReportDetailSheet extends StatefulWidget {
  final ReportModel report;
  const _ReportDetailSheet({required this.report});

  @override
  State<_ReportDetailSheet> createState() => _ReportDetailSheetState();
}

class _ReportDetailSheetState extends State<_ReportDetailSheet> {
  final TextEditingController _notesCtrl = TextEditingController();

  // Floor on resolution-note length. "ok" / "fine" are not an
  // acceptable audit trail for harassment / abuse reports — the
  // 10-char gate forces the admin to write at least a few words
  // about what they reviewed and what action (if any) was taken.
  static const int _kMinNotesLen = 10;

  @override
  void initState() {
    super.initState();
    _notesCtrl.addListener(_onNotesChanged);
  }

  @override
  void dispose() {
    _notesCtrl.removeListener(_onNotesChanged);
    _notesCtrl.dispose();
    super.dispose();
  }

  void _onNotesChanged() {
    if (!mounted) return;
    // Empty setState — only the counter colour and resolve-button
    // disabled state depend on the live length.
    setState(() {});
  }

  Future<void> _resolve() async {
    final notes = _notesCtrl.text.trim();
    if (notes.length < _kMinNotesLen) {
      AppSnackBar.error(
        context,
        'Add at least $_kMinNotesLen characters before resolving.',
      );
      return;
    }
    final cubit = context.read<AdminReportsCubit>();
    final ok = await cubit.resolveReport(widget.report.id, notes);
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop();
      AppSnackBar.success(context, 'Report resolved.');
    } else {
      AppSnackBar.error(context, 'Could not resolve. Try again.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.report;
    return BlocBuilder<AdminReportsCubit, AdminReportsState>(
      buildWhen: (prev, curr) =>
          prev.runtimeType != curr.runtimeType ||
          (prev is AdminReportsLoaded &&
              curr is AdminReportsLoaded &&
              prev.resolvingId != curr.resolvingId),
      builder: (_, state) {
        final isResolving = state is AdminReportsLoaded &&
            state.resolvingId == r.id;
        final notesLength = _notesCtrl.text.trim().length;
        final meetsMin = notesLength >= _kMinNotesLen;

        return SafeArea(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              20,
              12,
              20,
              MediaQuery.of(context).viewInsets.bottom + 24,
            ),
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
                        color: AdminColors.textLight
                            .withValues(alpha: 0.4),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Report',
                          style: GoogleFonts.inter(
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                            color: AdminColors.textPrimary,
                          ),
                        ),
                      ),
                      _ReportStatusBadge(status: r.status),
                    ],
                  ),
                  const SizedBox(height: 16),
                  _SectionLabel('REPORTER'),
                  _DetailRow(
                    label: 'Filed by',
                    value: r.reporterName,
                  ),
                  _DetailRow(
                    label: 'Against',
                    value: r.reportedUserName,
                  ),
                  if ((r.sessionId ?? '').isNotEmpty)
                    _DetailRow(
                      label: 'Session',
                      value: r.sessionId!,
                    ),
                  const SizedBox(height: 14),
                  _SectionLabel('DETAILS'),
                  if (r.reason.isNotEmpty)
                    _DetailRow(label: 'Reason', value: r.reason),
                  if (r.description.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      'Description',
                      style: GoogleFonts.inter(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: AdminColors.textMuted,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      r.description,
                      style: GoogleFonts.inter(
                        fontSize: 13,
                        fontWeight: FontWeight.w400,
                        color: AdminColors.textBody,
                        height: 1.45,
                      ),
                    ),
                  ],
                  if (r.formattedCreatedAt.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Text(
                      'Filed ${r.formattedCreatedAt}',
                      style: GoogleFonts.inter(
                        fontSize: 11,
                        fontWeight: FontWeight.w400,
                        color: AdminColors.textLight,
                      ),
                    ),
                  ],
                  const SizedBox(height: 20),
                  if (r.isResolved) ...[
                    _SectionLabel('RESOLUTION'),
                    if ((r.adminNotes ?? '').isNotEmpty) ...[
                      Text(
                        r.adminNotes!,
                        style: GoogleFonts.inter(
                          fontSize: 13,
                          fontWeight: FontWeight.w400,
                          color: AdminColors.textBody,
                          height: 1.45,
                        ),
                      ),
                      const SizedBox(height: 8),
                    ],
                    if (r.formattedResolvedAt.isNotEmpty)
                      Text(
                        'Resolved ${r.formattedResolvedAt}',
                        style: GoogleFonts.inter(
                          fontSize: 11,
                          fontWeight: FontWeight.w400,
                          color: AdminColors.textLight,
                        ),
                      ),
                  ] else ...[
                    _SectionLabel('ADMIN NOTES'),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: AdminColors.inputBackground,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          // Subtle red outline when below the
                          // minimum so the gate is visible without
                          // being shouty.
                          color: meetsMin
                              ? AdminColors.borderLight
                              : AdminColors.error.withValues(alpha: 0.35),
                        ),
                      ),
                      child: TextField(
                        controller: _notesCtrl,
                        enabled: !isResolving,
                        maxLines: 3,
                        textCapitalization:
                            TextCapitalization.sentences,
                        style: GoogleFonts.inter(
                          fontSize: 13,
                          fontWeight: FontWeight.w400,
                          color: AdminColors.textPrimary,
                        ),
                        decoration: InputDecoration(
                          isCollapsed: true,
                          contentPadding:
                              const EdgeInsets.symmetric(vertical: 8),
                          border: InputBorder.none,
                          hintText:
                              'Note what was reviewed and any action taken…',
                          hintStyle: GoogleFonts.inter(
                            fontSize: 13,
                            fontWeight: FontWeight.w400,
                            color: AdminColors.textLight,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            meetsMin
                                ? 'Looks good.'
                                : 'At least $_kMinNotesLen characters required.',
                            style: GoogleFonts.inter(
                              fontSize: 11,
                              fontWeight: FontWeight.w400,
                              color: meetsMin
                                  ? AdminColors.success
                                  : AdminColors.textMuted,
                            ),
                          ),
                        ),
                        Text(
                          '$notesLength / $_kMinNotesLen',
                          style: GoogleFonts.inter(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: meetsMin
                                ? AdminColors.success
                                : AdminColors.textLight,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    _ResolveButton(
                      loading: isResolving,
                      onTap: (isResolving || !meetsMin)
                          ? null
                          : _resolve,
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _ResolveButton extends StatefulWidget {
  final bool loading;
  final VoidCallback? onTap;
  const _ResolveButton({required this.loading, required this.onTap});

  @override
  State<_ResolveButton> createState() => _ResolveButtonState();
}

class _ResolveButtonState extends State<_ResolveButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final disabled = widget.onTap == null;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: disabled
          ? null
          : (_) => setState(() => _pressed = true),
      onTapUp:
          disabled ? null : (_) => setState(() => _pressed = false),
      onTapCancel:
          disabled ? null : () => setState(() => _pressed = false),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _pressed ? 0.97 : 1.0,
        duration: const Duration(milliseconds: 120),
        child: Container(
          height: 46,
          decoration: BoxDecoration(
            color: disabled
                ? AdminColors.success.withValues(alpha: 0.6)
                : AdminColors.success,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Center(
            child: widget.loading
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation(Colors.white),
                    ),
                  )
                : Text(
                    'Mark as Resolved',
                    style: GoogleFonts.inter(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
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

class _DetailRow extends StatelessWidget {
  final String label;
  final String value;
  const _DetailRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 90,
            child: Text(
              label,
              style: GoogleFonts.inter(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: AdminColors.textMuted,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: GoogleFonts.inter(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: AdminColors.textPrimary,
              ),
            ),
          ),
        ],
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
        padding: const EdgeInsets.all(14),
        decoration: AdminColors.cardDecoration,
        child: Shimmer.fromColors(
          baseColor: AdminColors.inputBackground,
          highlightColor: Colors.white,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                height: 14,
                width: 200,
                decoration: BoxDecoration(
                  color: AdminColors.inputBackground,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
              const SizedBox(height: 8),
              Container(
                height: 12,
                width: 160,
                decoration: BoxDecoration(
                  color: AdminColors.inputBackground,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
              const SizedBox(height: 6),
              Container(
                height: 12,
                width: 220,
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
          'No pending reports',
          'New reports will appear here',
        ),
      'resolved' => (
          Icons.task_alt,
          'No resolved reports',
          'Resolved reports will appear here',
        ),
      _ => (
          Icons.report_outlined,
          'No reports yet',
          'User-submitted reports will appear here',
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
