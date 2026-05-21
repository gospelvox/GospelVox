// Session history list — shared between user and priest sides. The
// `isUserSide` flag flips three things:
//   • which loader runs (userId vs priestId filter)
//   • whether the summary card shows "Spent" or "Earned"
//   • which name is shown on each card (priest name vs user name)
//
// Why one page instead of two: the layout, filter chips, summary card,
// and card chrome are nearly identical — duplicating the file would
// let the two halves drift on padding, sort order, and rating display.
//
// The list mixes two entry kinds:
//   • RegularSessionEntry (chat / voice consultation)
//   • BibleSessionEntry  (paid bible session attendance / hosting)
// Each kind has its own card chrome (icon, badge colour, secondary
// chips), but they share the same outer container, long-press-to-
// dismiss gesture, and detail-tap handler.
//
// Clear All + long-press dismiss are SOFT hides: Firestore rules
// deny `delete` on /sessions and /bible_sessions/.../registrations,
// so the cubit appends the entry's composite key onto the caller's
// own `hiddenSessionIds` array. The other party + admin still see
// the underlying record.

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shimmer/shimmer.dart';

import 'package:gospel_vox/core/theme/app_colors.dart';
import 'package:gospel_vox/core/utils/date_format.dart' as df;
import 'package:gospel_vox/core/widgets/app_back_button.dart';
import 'package:gospel_vox/core/widgets/app_snackbar.dart';
import 'package:gospel_vox/features/shared/bloc/session_history_cubit.dart';
import 'package:gospel_vox/features/shared/bloc/session_history_state.dart';
import 'package:gospel_vox/features/shared/data/session_history_repository.dart';
import 'package:gospel_vox/core/widgets/app_icons.dart';

const Color _kCompletedGreen = Color(0xFF059669);
const Color _kDeclinedRed = Color(0xFFDC2626);
// Warm amber for the Bible badge — matches the Bible category accent
// used on the user-side Bible tab + dashboard tile.
const Color _kBibleAmber = Color(0xFFC8902A);

class SessionHistoryPage extends StatelessWidget {
  final bool isUserSide;

  const SessionHistoryPage({super.key, required this.isUserSide});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: BlocConsumer<SessionHistoryCubit, SessionHistoryState>(
        listener: (context, state) {
          if (state is SessionHistoryError) {
            AppSnackBar.error(context, state.message);
          }
        },
        builder: (context, state) {
          return Scaffold(
            backgroundColor: AppColors.background,
            appBar: _buildAppBar(context, state),
            body: _buildBody(context, state),
          );
        },
      ),
    );
  }

  Widget _buildBody(BuildContext context, SessionHistoryState state) {
    if (state is SessionHistoryLoading || state is SessionHistoryInitial) {
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
  }

  PreferredSizeWidget _buildAppBar(
    BuildContext context,
    SessionHistoryState state,
  ) {
    final hasAny =
        state is SessionHistoryLoaded && state.allEntries.isNotEmpty;

    return AppBar(
      backgroundColor: AppColors.background,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
      centerTitle: false,
      leadingWidth: 60,
      leading: const Padding(
        padding: EdgeInsets.only(left: 16),
        child: AppBackButton(),
      ),
      title: Text(
        'Session History',
        style: GoogleFonts.inter(
          fontSize: 18,
          fontWeight: FontWeight.w600,
          color: AppColors.deepDarkBrown,
        ),
      ),
      actions: [
        if (hasAny)
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => _confirmClearAll(context),
              child: Container(
                alignment: Alignment.center,
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                child: Text(
                  'Clear All',
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: AppColors.errorRed,
                  ),
                ),
              ),
            ),
          ),
      ],
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

  Future<void> _confirmClearAll(BuildContext context) async {
    final cubit = context.read<SessionHistoryCubit>();
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;

    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => const _ConfirmActionSheet(
        title: 'Clear all history?',
        message:
            'This hides every entry from your view. The session data '
            "itself isn't deleted — the other party can still see it. "
            "You won't be able to undo this from your side.",
        confirmLabel: 'Clear All',
      ),
    );
    if (confirmed != true || !context.mounted) return;
    final ok = await cubit.hideAll(uid: uid, isUserSide: isUserSide);
    if (!context.mounted) return;
    if (ok) {
      AppSnackBar.success(context, 'History cleared.');
    } else {
      AppSnackBar.error(context, "Couldn't clear history. Try again.");
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
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
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
                    const SizedBox(width: 8),
                    _FilterChip(
                      label: 'Bible',
                      isActive: state.activeFilter == 'bible',
                      onTap: () => cubit.filterByType('bible'),
                    ),
                  ],
                ),
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
                        (entry) => _HistoryRow(
                          entry: entry,
                          isUserSide: isUserSide,
                          onTap: () => _openDetail(context, entry),
                          onLongPress: () =>
                              _confirmDismiss(context, entry),
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

  void _openDetail(BuildContext context, HistoryEntry entry) {
    switch (entry) {
      case RegularSessionEntry(session: final s):
        context.push('/session/detail', extra: {
          'session': s,
          'isUserSide': isUserSide,
        });
      case BibleSessionEntry(session: final s):
        // User taps go to the public-facing detail page; priest taps
        // route to their manage view. Same content, different actions.
        context.push(
          isUserSide ? '/bible/detail/${s.id}' : '/priest/bible/${s.id}',
        );
    }
  }

  Future<void> _confirmDismiss(
    BuildContext context,
    HistoryEntry entry,
  ) async {
    HapticFeedback.mediumImpact();
    final cubit = context.read<SessionHistoryCubit>();
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;

    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => const _ConfirmActionSheet(
        title: 'Remove from history?',
        message:
            "It'll be hidden from your view. The session data itself "
            "isn't deleted, and the other party can still see it.",
        confirmLabel: 'Remove',
      ),
    );
    if (confirmed != true || !context.mounted) return;
    final ok = await cubit.hideOne(
      uid: uid,
      isUserSide: isUserSide,
      entry: entry,
    );
    if (!context.mounted) return;
    if (!ok) {
      AppSnackBar.error(context, "Couldn't remove. Try again.");
    }
  }
}

// ─── Summary card ──────────────────────────────────────────

class _SummaryCard extends StatelessWidget {
  final SessionHistoryLoaded state;
  final bool isUserSide;

  const _SummaryCard({required this.state, required this.isUserSide});

  @override
  Widget build(BuildContext context) {
    // Show whichever unit is non-zero. For most users the regular-
    // session coin counter dominates; bible-only users see the INR
    // counter. When both are non-zero we show the dominant one and
    // call out the other in the subtitle so the card never lies
    // about totals.
    final coinValue = isUserSide ? state.coinsSpent : state.coinsEarned;
    final inrValue = isUserSide ? state.inrSpent : state.inrEarned;
    final primaryLabel = isUserSide ? 'Spent' : 'Earned';
    final primaryValue = _formatPrimaryValue(coinValue, inrValue);

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
            icon: AppIcons.history,
          ),
          const _SummaryDivider(),
          _SummaryStat(
            label: primaryLabel,
            value: primaryValue,
            icon: isUserSide
                ? AppIcons.coins
                : AppIcons.wallet,
          ),
          const _SummaryDivider(),
          _SummaryStat(
            label: 'Avg Rating',
            value: _avgRating(state.allEntries),
            icon: AppIcons.starOutline,
          ),
        ],
      ),
    );
  }

  // Stacks coin + ₹ totals when both are present so the user sees
  // both units; falls back to "—" when neither has been spent /
  // earned (avoids a confusing "0" for a brand-new account).
  String _formatPrimaryValue(int coinValue, int inrValue) {
    if (coinValue == 0 && inrValue == 0) return '—';
    if (inrValue == 0) return '$coinValue';
    if (coinValue == 0) return '₹$inrValue';
    return '$coinValue · ₹$inrValue';
  }

  String _avgRating(List<HistoryEntry> entries) {
    final rated = entries
        .where((e) => e.rating != null && e.rating! > 0)
        .toList();
    if (rated.isEmpty) return '—';
    final avg = rated.fold<double>(0.0, (sum, e) => sum + e.rating!) /
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
          AppIcon(
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

// ─── History row (branches on entry type) ──────────────────

class _HistoryRow extends StatefulWidget {
  final HistoryEntry entry;
  final bool isUserSide;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const _HistoryRow({
    required this.entry,
    required this.isUserSide,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  State<_HistoryRow> createState() => _HistoryRowState();
}

class _HistoryRowState extends State<_HistoryRow> {
  double _scale = 1.0;

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (_) => setState(() => _scale = 0.98),
      onPointerUp: (_) => setState(() => _scale = 1.0),
      onPointerCancel: (_) => setState(() => _scale = 1.0),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        onLongPress: widget.onLongPress,
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
            child: switch (widget.entry) {
              RegularSessionEntry(session: final s) => _RegularCardContent(
                  session: s,
                  isUserSide: widget.isUserSide,
                ),
              BibleSessionEntry(session: final s, registration: final r) =>
                _BibleCardContent(
                  session: s,
                  registration: r,
                  isUserSide: widget.isUserSide,
                  priestRevenueInr:
                      (widget.entry as BibleSessionEntry).priestRevenueInr,
                ),
            },
          ),
        ),
      ),
    );
  }
}

class _RegularCardContent extends StatelessWidget {
  final dynamic session; // SessionModel — kept dynamic to avoid an
                         // explicit import here; the only fields read
                         // are documented inline.
  final bool isUserSide;

  const _RegularCardContent({
    required this.session,
    required this.isUserSide,
  });

  @override
  Widget build(BuildContext context) {
    final s = session;
    final otherName = isUserSide ? s.priestName : s.userName;
    final hasRating = s.userRating != null && s.userRating! > 0;
    final isChat = s.isChat as bool;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: isChat
                    ? AppColors.primaryBrown.withValues(alpha: 0.06)
                    : AppColors.amberGold.withValues(alpha: 0.08),
              ),
              child: AppIcon(
                isChat
                    ? AppIcons.chatOutline
                    : AppIcons.mic,
                size: 16,
                color: isChat
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
                    (otherName as String).isNotEmpty ? otherName : 'Unknown',
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
                    '${isChat ? 'Chat' : 'Voice'} · '
                    '${df.formatFullDate(s.createdAt as DateTime?)}',
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
            _StatusBadge(status: s.status as String),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            if ((s.durationMinutes as int) > 0) ...[
              _DetailChip(
                icon: AppIcons.clock,
                text: '${s.durationMinutes} min',
              ),
              const SizedBox(width: 10),
            ],
            if (s.status == 'completed') ...[
              _DetailChip(
                icon: isUserSide
                    ? AppIcons.coins
                    : AppIcons.wallet,
                text: isUserSide
                    ? '${s.totalCharged} coins'
                    : '₹${s.priestEarnings}',
                valueColor:
                    isUserSide ? null : const Color(0xFF2E7D4F),
              ),
              const SizedBox(width: 10),
            ],
            const Spacer(),
            if (hasRating)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AppIcon(
                    AppIcons.starFilled,
                    size: 14,
                    color: AppColors.amberGold,
                  ),
                  const SizedBox(width: 3),
                  Text(
                    (s.userRating as num).toDouble().toStringAsFixed(1),
                    style: GoogleFonts.inter(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: AppColors.deepDarkBrown,
                    ),
                  ),
                ],
              ),
          ],
        ),
      ],
    );
  }
}

class _BibleCardContent extends StatelessWidget {
  final dynamic session;       // BibleSessionModel
  final dynamic registration;  // BibleRegistration?
  final bool isUserSide;
  final int priestRevenueInr;

  const _BibleCardContent({
    required this.session,
    required this.registration,
    required this.isUserSide,
    required this.priestRevenueInr,
  });

  @override
  Widget build(BuildContext context) {
    final s = session;
    final reg = registration;
    final title = (s.title as String).isNotEmpty
        ? s.title as String
        : 'Bible Session';
    final priestName = s.priestName as String;
    final regStatus = reg?.status as String?;
    final hasUserRating =
        reg?.rating != null && (reg.rating as int) > 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _kBibleAmber.withValues(alpha: 0.1),
              ),
              child: const AppIcon(
                AppIcons.bible,
                size: 16,
                color: _kBibleAmber,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        margin: const EdgeInsets.only(right: 6),
                        decoration: BoxDecoration(
                          color: _kBibleAmber.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          'BIBLE',
                          style: GoogleFonts.inter(
                            fontSize: 9,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.5,
                            color: _kBibleAmber,
                          ),
                        ),
                      ),
                      Expanded(
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: GoogleFonts.inter(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: AppColors.deepDarkBrown,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    isUserSide
                        ? '${priestName.isEmpty ? 'Speaker' : priestName} · '
                            '${df.formatFullDate(s.scheduledAt as DateTime?)}'
                        : df.formatFullDate(s.scheduledAt as DateTime?),
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
            _StatusBadge(
              status: _bibleDisplayStatus(s.status as String, regStatus),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            if ((s.durationMinutes as int) > 0) ...[
              _DetailChip(
                icon: AppIcons.clock,
                text: s.formattedDuration as String,
              ),
              const SizedBox(width: 10),
            ],
            // User side: show their own paid amount when registration
            // exists. Priest side: show the per-session revenue figure
            // computed from paid registrations × price.
            if (isUserSide && (reg?.isPaid == true)) ...[
              _DetailChip(
                icon: AppIcons.rupee,
                text: '₹${s.price}',
              ),
              const SizedBox(width: 10),
            ] else if (!isUserSide && priestRevenueInr > 0) ...[
              _DetailChip(
                icon: AppIcons.wallet,
                text: '₹$priestRevenueInr',
                valueColor: const Color(0xFF2E7D4F),
              ),
              const SizedBox(width: 10),
            ],
            const Spacer(),
            if (hasUserRating)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AppIcon(
                    AppIcons.starFilled,
                    size: 14,
                    color: AppColors.amberGold,
                  ),
                  const SizedBox(width: 3),
                  Text(
                    (reg.rating as int).toDouble().toStringAsFixed(1),
                    style: GoogleFonts.inter(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: AppColors.deepDarkBrown,
                    ),
                  ),
                ],
              ),
          ],
        ),
      ],
    );
  }
}

// Maps the session.status + (optional) user registration.status into
// the single display token that drives the badge colour. Priority:
// session-level cancellation > completion > registration cancellation
// > registration paid/registered > session live/upcoming.
String _bibleDisplayStatus(String sessionStatus, String? regStatus) {
  if (sessionStatus == 'cancelled') return 'cancelled';
  if (sessionStatus == 'completed') return 'completed';
  if (regStatus == 'cancelled') return 'cancelled';
  if (sessionStatus == 'live') return 'live';
  if (regStatus == 'paid') return 'paid';
  if (regStatus == 'registered') return 'registered';
  return sessionStatus;
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
    case 'live':
      return 'Live';
    case 'paid':
      return 'Paid';
    case 'registered':
      return 'Registered';
    case 'upcoming':
      return 'Upcoming';
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
    case 'paid':
      return _kCompletedGreen.withValues(alpha: 0.08);
    case 'live':
      return _kDeclinedRed.withValues(alpha: 0.08);
    case 'declined':
      return _kDeclinedRed.withValues(alpha: 0.08);
    case 'expired':
    case 'cancelled':
      return AppColors.muted.withValues(alpha: 0.08);
    case 'registered':
    case 'upcoming':
      return _kBibleAmber.withValues(alpha: 0.1);
    default:
      return AppColors.muted.withValues(alpha: 0.08);
  }
}

Color _statusTextColor(String status) {
  switch (status) {
    case 'completed':
    case 'active':
    case 'paid':
      return _kCompletedGreen;
    case 'live':
    case 'declined':
      return _kDeclinedRed;
    case 'registered':
    case 'upcoming':
      return _kBibleAmber;
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
        AppIcon(
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

// ─── Confirm action sheet (Clear All + per-row dismiss) ────

class _ConfirmActionSheet extends StatelessWidget {
  final String title;
  final String message;
  final String confirmLabel;

  const _ConfirmActionSheet({
    required this.title,
    required this.message,
    required this.confirmLabel,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Container(
        decoration: const BoxDecoration(
          color: AppColors.surfaceWhite,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.muted.withValues(alpha: 0.25),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 20),
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.errorRed.withValues(alpha: 0.08),
              ),
              child: const AppIcon(
                AppIcons.deleteSweep,
                size: 28,
                color: AppColors.errorRed,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              title,
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: AppColors.deepDarkBrown,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              message,
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
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => Navigator.of(context).pop(false),
                    child: Container(
                      height: 48,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: Colors.transparent,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: AppColors.muted.withValues(alpha: 0.25),
                        ),
                      ),
                      child: Text(
                        'Cancel',
                        style: GoogleFonts.inter(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: AppColors.deepDarkBrown,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => Navigator.of(context).pop(true),
                    child: Container(
                      height: 48,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: AppColors.errorRed,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Text(
                        confirmLabel,
                        style: GoogleFonts.inter(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
                        ),
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
          AppIcon(
            AppIcons.history,
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
                ? 'Your consultation and Bible session history will appear here'
                : "Sessions and Bible sessions you've conducted will appear here",
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
            AppIcon(
              AppIcons.error,
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
