// Admin session monitor — read-only tabbed list of every session
// the platform has ever brokered. Active tab is live (stream-backed
// list + count badge) so the admin can watch a session transition
// in real time; Completed and All tabs are one-shot fetches.
//
// Tapping a card opens a modal bottom sheet with the full denorm-
// alised picture: revenue split, rating, end reason, timestamps.
// We use a sheet (not a full page) because every field is read-
// only — admins should be able to glance and dismiss without
// burning a navigation stack frame.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shimmer/shimmer.dart';

import 'package:gospel_vox/core/services/injection_container.dart';
import 'package:gospel_vox/core/theme/admin_colors.dart';
import 'package:gospel_vox/core/widgets/app_snackbar.dart';
import 'package:gospel_vox/features/admin/sessions/bloc/admin_sessions_cubit.dart';
import 'package:gospel_vox/features/admin/sessions/bloc/admin_sessions_state.dart';
import 'package:gospel_vox/features/admin/sessions/data/admin_session_model.dart';

const _kFilters = ['active', 'completed', 'all'];

// Maps the raw endReason tokens emitted by the session CFs to
// admin-friendly copy. We still surface the underlying code in
// the detail sheet for CF-log cross-referencing, but the lead
// line shows this string so the admin doesn't have to memorise
// the token taxonomy. Unrecognised codes pass through untouched
// — better than showing a misleading mistranslation.
String _humanizeEndReason(String code) {
  switch (code) {
    case 'balance_zero':
      return 'Balance ran out';
    case 'watchdog_timeout':
      return 'Connection dropped (watchdog)';
    case 'user_ended':
      return 'User ended session';
    case 'priest_ended':
      return 'Priest ended session';
    case 'network_disconnected':
      return 'Network disconnected';
    case 'connection_failed':
      return 'Failed to connect';
    default:
      return code;
  }
}

class AdminSessionsPage extends StatelessWidget {
  const AdminSessionsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.dark,
      ),
      child: BlocProvider<AdminSessionsCubit>(
        create: (_) =>
            sl<AdminSessionsCubit>()..loadSessions('active'),
        child: const _AdminSessionsView(),
      ),
    );
  }
}

class _AdminSessionsView extends StatefulWidget {
  const _AdminSessionsView();

  @override
  State<_AdminSessionsView> createState() => _AdminSessionsViewState();
}

class _AdminSessionsViewState extends State<_AdminSessionsView>
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
    context.read<AdminSessionsCubit>().loadSessions(filter);
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
      body: BlocConsumer<AdminSessionsCubit, AdminSessionsState>(
        listener: (ctx, state) {
          if (state is AdminSessionsError) {
            AppSnackBar.error(ctx, state.message);
          }
        },
        builder: (ctx, state) {
          if (state is AdminSessionsError) {
            return _ErrorView(
              message: state.message,
              onRetry: () => ctx
                  .read<AdminSessionsCubit>()
                  .loadSessions(_kFilters[_tabController.index]),
            );
          }
          if (state is AdminSessionsLoaded) {
            return _SessionsList(
              sessions: state.sessions,
              filter: state.filter,
              onRefresh: () => ctx
                  .read<AdminSessionsCubit>()
                  .loadSessions(state.filter),
              onTap: (s) => _openDetail(ctx, s),
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
        'Session Monitor',
        style: GoogleFonts.inter(
          fontSize: 18,
          fontWeight: FontWeight.w600,
          color: AdminColors.textPrimary,
        ),
      ),
      centerTitle: false,
      bottom: PreferredSize(
        preferredSize: const Size.fromHeight(60),
        child: BlocBuilder<AdminSessionsCubit, AdminSessionsState>(
          buildWhen: (prev, curr) =>
              prev.runtimeType != curr.runtimeType ||
              (prev is AdminSessionsLoaded &&
                  curr is AdminSessionsLoaded &&
                  prev.activeCount != curr.activeCount),
          builder: (_, state) {
            final activeCount = state is AdminSessionsLoaded
                ? state.activeCount
                : 0;
            return _TabBarPill(
              controller: _tabController,
              activeCount: activeCount,
            );
          },
        ),
      ),
    );
  }

  void _openDetail(BuildContext ctx, AdminSessionModel s) {
    showModalBottomSheet<void>(
      context: ctx,
      backgroundColor: Colors.white,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _SessionDetailSheet(session: s),
    );
  }
}

// ─── Tab bar ────────────────────────────────────────────────────

class _TabBarPill extends StatelessWidget {
  final TabController controller;
  final int activeCount;

  const _TabBarPill({
    required this.controller,
    required this.activeCount,
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
            _TabLabel(label: 'Active', count: activeCount, live: true),
            const _TabLabel(label: 'Completed', count: 0),
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
  // Active tab gets the live (green) badge so the admin knows
  // they're watching realtime — every other tab is one-shot fetch.
  final bool live;
  const _TabLabel({
    required this.label,
    required this.count,
    this.live = false,
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
                color: live
                    ? AdminColors.success
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

class _SessionsList extends StatelessWidget {
  final List<AdminSessionModel> sessions;
  final String filter;
  final Future<void> Function() onRefresh;
  final void Function(AdminSessionModel) onTap;

  const _SessionsList({
    required this.sessions,
    required this.filter,
    required this.onRefresh,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    if (sessions.isEmpty) {
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
        itemCount: sessions.length,
        itemBuilder: (_, i) => _SessionCard(
          session: sessions[i],
          onTap: () => onTap(sessions[i]),
        ),
      ),
    );
  }
}

// ─── Session card ──────────────────────────────────────────────

class _SessionCard extends StatefulWidget {
  final AdminSessionModel session;
  final VoidCallback onTap;
  const _SessionCard({required this.session, required this.onTap});

  @override
  State<_SessionCard> createState() => _SessionCardState();
}

class _SessionCardState extends State<_SessionCard> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final s = widget.session;
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
                      '${s.userName} → ${s.priestName}',
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
                  _StatusBadge(
                    label: s.statusLabel,
                    color: s.statusColor,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: AdminColors.inputBackground,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      s.type == 'chat' ? 'Chat' : 'Voice',
                      style: GoogleFonts.inter(
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                        color: AdminColors.textBody,
                      ),
                    ),
                  ),
                  if (s.durationMinutes > 0) ...[
                    const SizedBox(width: 8),
                    Text(
                      '${s.durationMinutes} min',
                      style: GoogleFonts.inter(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: AdminColors.textMuted,
                      ),
                    ),
                  ],
                  const Spacer(),
                  if (s.totalCharged > 0)
                    Text(
                      '₹${s.totalCharged}',
                      style: GoogleFonts.inter(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: AdminColors.textPrimary,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Text(
                    s.formattedDate,
                    style: GoogleFonts.inter(
                      fontSize: 11,
                      fontWeight: FontWeight.w400,
                      color: AdminColors.textLight,
                    ),
                  ),
                  const Spacer(),
                  if (s.userRating != null)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.star_rounded,
                          size: 14,
                          color: AdminColors.warning,
                        ),
                        const SizedBox(width: 3),
                        Text(
                          s.userRating!.toStringAsFixed(1),
                          style: GoogleFonts.inter(
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                            color: AdminColors.textMuted,
                          ),
                        ),
                      ],
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

// ─── Status badge ──────────────────────────────────────────────

class _StatusBadge extends StatelessWidget {
  final String label;
  final Color color;
  const _StatusBadge({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        // Tinted background derived from the foreground colour so
        // we don't manage a parallel bg-token per status.
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: GoogleFonts.inter(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }
}

// ─── Detail sheet ──────────────────────────────────────────────

class _SessionDetailSheet extends StatelessWidget {
  final AdminSessionModel session;
  const _SessionDetailSheet({required this.session});

  @override
  Widget build(BuildContext context) {
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
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Session Details',
                      style: GoogleFonts.inter(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                        color: AdminColors.textPrimary,
                      ),
                    ),
                  ),
                  _StatusBadge(
                    label: session.statusLabel,
                    color: session.statusColor,
                  ),
                ],
              ),
              const SizedBox(height: 16),
              _SectionLabel('PARTICIPANTS'),
              _DetailRow(label: 'User', value: session.userName),
              _DetailRow(label: 'Priest', value: session.priestName),
              _DetailRow(
                label: 'Type',
                value: session.type == 'chat' ? 'Chat' : 'Voice',
              ),
              const SizedBox(height: 14),
              _SectionLabel('BILLING'),
              _DetailRow(
                label: 'Duration',
                value: '${session.durationMinutes} min',
              ),
              _DetailRow(
                label: 'Rate',
                value: '₹${session.ratePerMinute}/min',
              ),
              _DetailRow(
                label: 'Total Charged',
                value: '₹${session.totalCharged}',
              ),
              _DetailRow(
                label: 'Priest Earnings',
                value: '₹${session.priestEarnings}',
              ),
              _DetailRow(
                label: 'Platform Revenue',
                value: '₹${session.platformRevenue}',
                emphasised: true,
              ),
              _DetailRow(
                label: 'Commission',
                value: '${session.commissionPercent}%',
              ),
              if (session.userRating != null ||
                  (session.userFeedback ?? '').isNotEmpty) ...[
                const SizedBox(height: 14),
                _SectionLabel('RATING'),
                if (session.userRating != null)
                  _DetailRow(
                    label: 'Stars',
                    value:
                        '${session.userRating!.toStringAsFixed(1)} / 5',
                  ),
                if ((session.userFeedback ?? '').isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    'Feedback',
                    style: GoogleFonts.inter(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: AdminColors.textMuted,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    session.userFeedback!,
                    style: GoogleFonts.inter(
                      fontSize: 13,
                      fontWeight: FontWeight.w400,
                      color: AdminColors.textBody,
                      height: 1.45,
                    ),
                  ),
                ],
              ],
              if ((session.endReason ?? '').isNotEmpty) ...[
                const SizedBox(height: 14),
                _SectionLabel('END REASON'),
                // Show the human label first (what the admin
                // actually wants), and the raw token underneath
                // for cross-referencing CF logs / Firestore docs.
                _DetailRow(
                  label: 'Reason',
                  value: _humanizeEndReason(session.endReason!),
                ),
                _DetailRow(
                  label: 'Code',
                  value: session.endReason!,
                ),
              ],
              const SizedBox(height: 14),
              _SectionLabel('TIMESTAMPS'),
              _DetailRow(
                label: 'Created',
                value: _fmt(session.createdAt),
              ),
              _DetailRow(
                label: 'Started',
                value: _fmt(session.startedAt),
              ),
              _DetailRow(
                label: 'Ended',
                value: _fmt(session.endedAt),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _fmt(DateTime? d) {
    if (d == null) return '—';
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    final hour =
        d.hour > 12 ? d.hour - 12 : (d.hour == 0 ? 12 : d.hour);
    final period = d.hour >= 12 ? 'PM' : 'AM';
    final minute = d.minute.toString().padLeft(2, '0');
    return '${months[d.month - 1]} ${d.day}, ${d.year} '
        '$hour:$minute $period';
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
  final bool emphasised;
  const _DetailRow({
    required this.label,
    required this.value,
    this.emphasised = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
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
                fontWeight: emphasised ? FontWeight.w700 : FontWeight.w500,
                color: emphasised
                    ? AdminColors.brandBrown
                    : AdminColors.textPrimary,
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
                width: 140,
                decoration: BoxDecoration(
                  color: AdminColors.inputBackground,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
              const SizedBox(height: 8),
              Container(
                height: 10,
                width: 100,
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
      'active' => (
          Icons.bolt_outlined,
          'No live sessions',
          'Active sessions will appear here in real time',
        ),
      'completed' => (
          Icons.history,
          'No completed sessions',
          'Finished sessions will appear here',
        ),
      _ => (
          Icons.chat_bubble_outline,
          'No sessions yet',
          'Sessions across every status will appear here',
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
