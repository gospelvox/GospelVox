// Session history list — shared between user and priest sides. The
// `isUserSide` flag flips three things:
//   • which loader runs (userId vs priestId filter)
//   • whether the summary card shows "Spent" or "Earned"
//   • which name is shown on each card (priest name vs user name)
//
// Why one page instead of two: the layout, filter chips, summary card,
// and card chrome are identical — duplicating the file would let the
// two halves drift on padding, sort order, and rating display.

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shimmer/shimmer.dart';

import 'package:gospel_vox/core/theme/app_colors.dart';
import 'package:gospel_vox/core/widgets/app_snackbar.dart';
import 'package:gospel_vox/features/shared/bloc/session_history_cubit.dart';
import 'package:gospel_vox/features/shared/bloc/session_history_state.dart';
import 'package:gospel_vox/features/shared/data/session_model.dart';

const Color _kCompletedGreen = Color(0xFF059669);
const Color _kDeclinedRed = Color(0xFFDC2626);

class SessionHistoryPage extends StatelessWidget {
  final bool isUserSide;

  const SessionHistoryPage({super.key, required this.isUserSide});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: _buildAppBar(context),
      body: BlocConsumer<SessionHistoryCubit, SessionHistoryState>(
        listener: (context, state) {
          if (state is SessionHistoryError) {
            AppSnackBar.error(context, state.message);
          }
        },
        builder: (context, state) {
          if (state is SessionHistoryLoading ||
              state is SessionHistoryInitial) {
            return const _HistoryShimmer();
          }
          if (state is SessionHistoryError) {
            return _ErrorView(
              message: state.message,
              onRetry: () => _retry(context),
            );
          }
          if (state is SessionHistoryLoaded) {
            return _LoadedBody(state: state, isUserSide: isUserSide);
          }
          return const SizedBox.shrink();
        },
      ),
    );
  }

  PreferredSizeWidget _buildAppBar(BuildContext context) {
    return AppBar(
      backgroundColor: AppColors.background,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
      centerTitle: false,
      leadingWidth: 60,
      leading: Padding(
        padding: const EdgeInsets.only(left: 16),
        child: GestureDetector(
          onTap: () => context.pop(),
          behavior: HitTestBehavior.opaque,
          child: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.surfaceWhite,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.04),
                  blurRadius: 6,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Icon(
              Icons.arrow_back_ios_new,
              size: 16,
              color: AppColors.deepDarkBrown,
            ),
          ),
        ),
      ),
      title: Text(
        'Session History',
        style: GoogleFonts.inter(
          fontSize: 18,
          fontWeight: FontWeight.w600,
          color: AppColors.deepDarkBrown,
        ),
      ),
      bottom: PreferredSize(
        preferredSize: const Size.fromHeight(1),
        child: Container(
          height: 1,
          color: AppColors.muted.withValues(alpha: 0.08),
        ),
      ),
    );
  }

  void _retry(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    final cubit = context.read<SessionHistoryCubit>();
    if (isUserSide) {
      cubit.loadUserSessions(uid);
    } else {
      cubit.loadPriestSessions(uid);
    }
  }
}

// ─── Loaded body with summary, chips, and list ─────────────

class _LoadedBody extends StatelessWidget {
  final SessionHistoryLoaded state;
  final bool isUserSide;

  const _LoadedBody({required this.state, required this.isUserSide});

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<SessionHistoryCubit>();
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';

    return RefreshIndicator(
      color: AppColors.primaryBrown,
      backgroundColor: AppColors.surfaceWhite,
      onRefresh: () => cubit.refresh(uid, isUserSide),
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(
          parent: BouncingScrollPhysics(),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 16),
            _SummaryCard(state: state, isUserSide: isUserSide),
            const SizedBox(height: 20),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  _FilterChip(
                    label: 'All',
                    isActive: state.activeFilter == 'all',
                    onTap: () => cubit.filterByType('all'),
                  ),
                  const SizedBox(width: 8),
                  _FilterChip(
                    label: 'Chat',
                    isActive: state.activeFilter == 'chat',
                    onTap: () => cubit.filterByType('chat'),
                  ),
                  const SizedBox(width: 8),
                  _FilterChip(
                    label: 'Voice',
                    isActive: state.activeFilter == 'voice',
                    onTap: () => cubit.filterByType('voice'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            if (state.filtered.isEmpty)
              _EmptyHistory(isUserSide: isUserSide)
            else
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Column(
                  children: state.filtered
                      .map(
                        (session) => _SessionHistoryCard(
                          session: session,
                          isUserSide: isUserSide,
                          onTap: () => _openDetail(context, session),
                        ),
                      )
                      .toList(),
                ),
              ),
            const SizedBox(height: 100),
          ],
        ),
      ),
    );
  }

  void _openDetail(BuildContext context, SessionModel session) {
    context.push('/session/detail', extra: {
      'session': session,
      'isUserSide': isUserSide,
    });
  }
}

// ─── Summary card ──────────────────────────────────────────

class _SummaryCard extends StatelessWidget {
  final SessionHistoryLoaded state;
  final bool isUserSide;

  const _SummaryCard({required this.state, required this.isUserSide});

  @override
  Widget build(BuildContext context) {
    final secondaryValue = isUserSide
        ? '₹${state.totalSpent}'
        : '₹${state.totalEarned}';

    return Container(
      margin: const EdgeInsets.fromLTRB(20, 0, 20, 0),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.surfaceWhite,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: AppColors.muted.withValues(alpha: 0.08),
        ),
        boxShadow: [
          BoxShadow(
            blurRadius: 8,
            color: Colors.black.withValues(alpha: 0.03),
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _SummaryStat(
            label: 'Total',
            value: '${state.totalSessions}',
            icon: Icons.chat_bubble_outline_rounded,
          ),
          const _SummaryDivider(),
          _SummaryStat(
            label: isUserSide ? 'Spent' : 'Earned',
            value: secondaryValue,
            icon: isUserSide
                ? Icons.toll_rounded
                : Icons.account_balance_wallet_outlined,
          ),
          const _SummaryDivider(),
          _SummaryStat(
            label: 'Avg Rating',
            value: _avgRating(state.allSessions),
            icon: Icons.star_outline_rounded,
          ),
        ],
      ),
    );
  }

  String _avgRating(List<SessionModel> sessions) {
    final rated = sessions
        .where((s) => s.userRating != null && s.userRating! > 0)
        .toList();
    if (rated.isEmpty) return '—';
    final avg =
        rated.fold<double>(0.0, (sum, s) => sum + s.userRating!) /
            rated.length;
    return avg.toStringAsFixed(1);
  }
}

class _SummaryStat extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;

  const _SummaryStat({
    required this.label,
    required this.value,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Flexible(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 18,
            color: AppColors.primaryBrown.withValues(alpha: 0.5),
          ),
          const SizedBox(height: 8),
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

class _SummaryDivider extends StatelessWidget {
  const _SummaryDivider();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 1,
      height: 36,
      color: AppColors.muted.withValues(alpha: 0.1),
    );
  }
}

// ─── Filter chip ───────────────────────────────────────────

class _FilterChip extends StatelessWidget {
  final String label;
  final bool isActive;
  final VoidCallback onTap;

  const _FilterChip({
    required this.label,
    required this.isActive,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: isActive ? AppColors.primaryBrown : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isActive
                ? AppColors.primaryBrown
                : AppColors.muted.withValues(alpha: 0.2),
          ),
        ),
        child: Text(
          label,
          style: GoogleFonts.inter(
            fontSize: 13,
            fontWeight: isActive ? FontWeight.w600 : FontWeight.w500,
            color: isActive ? Colors.white : AppColors.muted,
          ),
        ),
      ),
    );
  }
}

// ─── Session history card ──────────────────────────────────

class _SessionHistoryCard extends StatefulWidget {
  final SessionModel session;
  final bool isUserSide;
  final VoidCallback onTap;

  const _SessionHistoryCard({
    required this.session,
    required this.isUserSide,
    required this.onTap,
  });

  @override
  State<_SessionHistoryCard> createState() => _SessionHistoryCardState();
}

class _SessionHistoryCardState extends State<_SessionHistoryCard> {
  double _scale = 1.0;

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final isUserSide = widget.isUserSide;
    final otherName = isUserSide ? session.priestName : session.userName;
    final hasRating =
        session.userRating != null && session.userRating! > 0;

    return Listener(
      onPointerDown: (_) => setState(() => _scale = 0.98),
      onPointerUp: (_) => setState(() => _scale = 1.0),
      onPointerCancel: (_) => setState(() => _scale = 1.0),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _scale,
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
          child: Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.surfaceWhite,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: AppColors.muted.withValues(alpha: 0.06),
              ),
              boxShadow: [
                BoxShadow(
                  blurRadius: 6,
                  color: Colors.black.withValues(alpha: 0.02),
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildTopRow(otherName: otherName, session: session),
                const SizedBox(height: 12),
                _buildBottomRow(
                  session: session,
                  isUserSide: isUserSide,
                  hasRating: hasRating,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTopRow({
    required String otherName,
    required SessionModel session,
  }) {
    return Row(
      children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: session.isChat
                ? AppColors.primaryBrown.withValues(alpha: 0.06)
                : AppColors.amberGold.withValues(alpha: 0.08),
          ),
          child: Icon(
            session.isChat
                ? Icons.chat_bubble_outline_rounded
                : Icons.mic_none_rounded,
            size: 16,
            color: session.isChat
                ? AppColors.primaryBrown
                : AppColors.amberGold,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                otherName.isNotEmpty ? otherName : 'Unknown',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: AppColors.deepDarkBrown,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                '${session.isChat ? 'Chat' : 'Voice'} · '
                '${_formatShortDate(session.createdAt)}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.inter(
                  fontSize: 12,
                  fontWeight: FontWeight.w400,
                  color: AppColors.muted,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        _StatusBadge(status: session.status),
      ],
    );
  }

  Widget _buildBottomRow({
    required SessionModel session,
    required bool isUserSide,
    required bool hasRating,
  }) {
    final children = <Widget>[];

    if (session.durationMinutes > 0) {
      children.add(
        _DetailChip(
          icon: Icons.access_time_rounded,
          text: '${session.durationMinutes} min',
        ),
      );
      children.add(const SizedBox(width: 10));
    }

    if (session.status == 'completed') {
      children.add(
        _DetailChip(
          icon: isUserSide
              ? Icons.toll_rounded
              : Icons.account_balance_wallet_outlined,
          text: isUserSide
              ? '${session.totalCharged} coins'
              : '₹${session.priestEarnings}',
          valueColor: isUserSide ? null : const Color(0xFF2E7D4F),
        ),
      );
      children.add(const SizedBox(width: 10));
    }

    children.add(const Spacer());

    if (hasRating) {
      children.add(
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.star_rounded,
              size: 14,
              color: AppColors.amberGold,
            ),
            const SizedBox(width: 3),
            Text(
              session.userRating!.toStringAsFixed(1),
              style: GoogleFonts.inter(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: AppColors.deepDarkBrown,
              ),
            ),
          ],
        ),
      );
    }

    return Row(children: children);
  }
}

// ─── Status badge ──────────────────────────────────────────

class _StatusBadge extends StatelessWidget {
  final String status;

  const _StatusBadge({required this.status});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: _statusBgColor(status),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        _statusLabel(status),
        style: GoogleFonts.inter(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: _statusTextColor(status),
        ),
      ),
    );
  }
}

String _statusLabel(String status) {
  switch (status) {
    case 'completed':
      return 'Completed';
    case 'declined':
      return 'Declined';
    case 'expired':
      return 'Expired';
    case 'cancelled':
      return 'Cancelled';
    case 'active':
      return 'Active';
    case 'pending':
      return 'Pending';
    default:
      return status.isNotEmpty
          ? '${status[0].toUpperCase()}${status.substring(1)}'
          : '—';
  }
}

Color _statusBgColor(String status) {
  switch (status) {
    case 'completed':
    case 'active':
      return _kCompletedGreen.withValues(alpha: 0.08);
    case 'declined':
      return _kDeclinedRed.withValues(alpha: 0.08);
    case 'expired':
    case 'cancelled':
      return AppColors.muted.withValues(alpha: 0.08);
    default:
      return AppColors.muted.withValues(alpha: 0.08);
  }
}

Color _statusTextColor(String status) {
  switch (status) {
    case 'completed':
    case 'active':
      return _kCompletedGreen;
    case 'declined':
      return _kDeclinedRed;
    default:
      return AppColors.muted;
  }
}

// ─── Detail chip (duration / cost / earned) ────────────────

class _DetailChip extends StatelessWidget {
  final IconData icon;
  final String text;
  final Color? valueColor;

  const _DetailChip({
    required this.icon,
    required this.text,
    this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          icon,
          size: 13,
          color: AppColors.muted.withValues(alpha: 0.5),
        ),
        const SizedBox(width: 4),
        Text(
          text,
          style: GoogleFonts.inter(
            fontSize: 12,
            fontWeight: FontWeight.w500,
            color: valueColor ?? AppColors.muted,
          ),
        ),
      ],
    );
  }
}

// ─── Empty / error / shimmer states ────────────────────────

class _EmptyHistory extends StatelessWidget {
  final bool isUserSide;
  const _EmptyHistory({required this.isUserSide});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 60, horizontal: 32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.history_rounded,
            size: 48,
            color: AppColors.muted.withValues(alpha: 0.2),
          ),
          const SizedBox(height: 16),
          Text(
            'No sessions yet',
            style: GoogleFonts.inter(
              fontSize: 15,
              fontWeight: FontWeight.w500,
              color: AppColors.muted,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            isUserSide
                ? 'Your consultation history will appear here'
                : "Sessions you've conducted will appear here",
            textAlign: TextAlign.center,
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

class _ErrorView extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _ErrorView({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.error_outline,
              size: 48,
              color: AppColors.muted.withValues(alpha: 0.3),
            ),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(
                fontSize: 15,
                fontWeight: FontWeight.w500,
                color: AppColors.muted,
              ),
            ),
            const SizedBox(height: 16),
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onRetry,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: AppColors.primaryBrown.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  'Retry',
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: AppColors.primaryBrown,
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

class _HistoryShimmer extends StatelessWidget {
  const _HistoryShimmer();

  @override
  Widget build(BuildContext context) {
    return Shimmer.fromColors(
      baseColor: AppColors.muted.withValues(alpha: 0.08),
      highlightColor: AppColors.muted.withValues(alpha: 0.03),
      child: SingleChildScrollView(
        physics: const NeverScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              height: 100,
              decoration: BoxDecoration(
                color: AppColors.surfaceWhite,
                borderRadius: BorderRadius.circular(16),
              ),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Container(
                  width: 60,
                  height: 32,
                  decoration: BoxDecoration(
                    color: AppColors.surfaceWhite,
                    borderRadius: BorderRadius.circular(20),
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  width: 70,
                  height: 32,
                  decoration: BoxDecoration(
                    color: AppColors.surfaceWhite,
                    borderRadius: BorderRadius.circular(20),
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  width: 70,
                  height: 32,
                  decoration: BoxDecoration(
                    color: AppColors.surfaceWhite,
                    borderRadius: BorderRadius.circular(20),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            for (int i = 0; i < 5; i++) ...[
              Container(
                height: 96,
                margin: const EdgeInsets.only(bottom: 10),
                decoration: BoxDecoration(
                  color: AppColors.surfaceWhite,
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ─── Date formatter ────────────────────────────────────────

String _formatShortDate(DateTime? date) {
  if (date == null) return '—';
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  return '${months[date.month - 1]} ${date.day}, ${date.year}';
}
