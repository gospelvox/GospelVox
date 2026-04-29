// User-side Bible tab — replaces the placeholder at index 1 of the
// shell's IndexedStack. Owns its own BibleSessionCubit so that the
// tab's load lifecycle is bounded by the shell's lifetime; the cubit
// is closed in dispose, which kills any in-flight Future before the
// state is re-entered after sign-out.

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shimmer/shimmer.dart';

import 'package:gospel_vox/core/services/injection_container.dart';
import 'package:gospel_vox/core/theme/app_colors.dart';
import 'package:gospel_vox/features/shared/bloc/bible_session_cubit.dart';
import 'package:gospel_vox/features/shared/bloc/bible_session_state.dart';
import 'package:gospel_vox/features/shared/data/bible_session_model.dart';

class BibleTab extends StatefulWidget {
  const BibleTab({super.key});

  @override
  State<BibleTab> createState() => _BibleTabState();
}

class _BibleTabState extends State<BibleTab> {
  late final BibleSessionCubit _cubit;

  @override
  void initState() {
    super.initState();
    _cubit = sl<BibleSessionCubit>()..loadSessions();
  }

  @override
  void dispose() {
    _cubit.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return BlocProvider.value(
      value: _cubit,
      child: Scaffold(
        backgroundColor: AppColors.background,
        body: BlocBuilder<BibleSessionCubit, BibleSessionState>(
          builder: (context, state) {
            return RefreshIndicator(
              color: AppColors.primaryBrown,
              backgroundColor: AppColors.surfaceWhite,
              onRefresh: () => _cubit.refresh(),
              child: _buildBody(context, state),
            );
          },
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context, BibleSessionState state) {
    if (state is BibleSessionLoading || state is BibleSessionInitial) {
      return _LoadingBody(activeTab: 'upcoming');
    }
    if (state is BibleSessionError) {
      return _ErrorBody(
        message: state.message,
        onRetry: _cubit.refresh,
      );
    }
    if (state is BibleSessionLoaded) {
      return _LoadedBody(
        state: state,
        onSwitchTab: _cubit.switchTab,
      );
    }
    return const SizedBox.shrink();
  }
}

// ─── Body — loaded ───────────────────────────────────────────────

class _LoadedBody extends StatelessWidget {
  final BibleSessionLoaded state;
  final void Function(String tab) onSwitchTab;

  const _LoadedBody({
    required this.state,
    required this.onSwitchTab,
  });

  @override
  Widget build(BuildContext context) {
    final list = state.activeList;
    return CustomScrollView(
      physics: const AlwaysScrollableScrollPhysics(
        parent: BouncingScrollPhysics(),
      ),
      slivers: [
        const SliverToBoxAdapter(child: _Header()),
        SliverToBoxAdapter(
          child: _TabBar(
            activeTab: state.activeTab,
            onSwitchTab: onSwitchTab,
          ),
        ),
        SliverToBoxAdapter(
          child: _CountLabel(
            count: list.length,
            tab: state.activeTab,
          ),
        ),
        if (list.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: _EmptyBibleSessions(tab: state.activeTab),
          )
        else
          SliverList.builder(
            itemCount: list.length,
            itemBuilder: (_, i) => _BibleSessionCard(
              session: list[i],
              onTap: () =>
                  context.push('/bible/detail/${list[i].id}'),
            ),
          ),
        const SliverToBoxAdapter(child: SizedBox(height: 100)),
      ],
    );
  }
}

// ─── Body — loading ──────────────────────────────────────────────

class _LoadingBody extends StatelessWidget {
  final String activeTab;
  const _LoadingBody({required this.activeTab});

  @override
  Widget build(BuildContext context) {
    final baseColor = AppColors.muted.withValues(alpha: 0.14);
    final highlightColor = AppColors.warmBeige;

    return CustomScrollView(
      physics: const AlwaysScrollableScrollPhysics(
        parent: BouncingScrollPhysics(),
      ),
      slivers: [
        const SliverToBoxAdapter(child: _Header()),
        SliverToBoxAdapter(
          child: _TabBar(activeTab: activeTab, onSwitchTab: (_) {}),
        ),
        SliverToBoxAdapter(
          child: _CountLabel(count: 0, tab: activeTab),
        ),
        SliverList.builder(
          itemCount: 4,
          itemBuilder: (_, i) => Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
            child: Shimmer.fromColors(
              baseColor: baseColor,
              highlightColor: highlightColor,
              child: Container(
                height: 160,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
            ),
          ),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 100)),
      ],
    );
  }
}

// ─── Body — error ────────────────────────────────────────────────

class _ErrorBody extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _ErrorBody({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    // Wrapped in a scrollable so the RefreshIndicator above still
    // works as a pull-to-retry — without that the user has no way
    // to recover except restarting the app.
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(
        parent: BouncingScrollPhysics(),
      ),
      padding: const EdgeInsets.fromLTRB(32, 80, 32, 32),
      children: [
        Icon(
          Icons.error_outline_rounded,
          size: 44,
          color: AppColors.errorRed,
        ),
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
        Center(
          child: GestureDetector(
            onTap: onRetry,
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 22,
                vertical: 10,
              ),
              decoration: BoxDecoration(
                color: AppColors.primaryBrown,
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
        ),
      ],
    );
  }
}

// ─── Header ──────────────────────────────────────────────────────

class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              "Bible Sessions",
              style: GoogleFonts.inter(
                fontSize: 24,
                fontWeight: FontWeight.w800,
                color: AppColors.deepDarkBrown,
                letterSpacing: -0.3,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Tab bar (Upcoming / Past / All) ─────────────────────────────

class _TabBar extends StatelessWidget {
  final String activeTab;
  final void Function(String tab) onSwitchTab;

  const _TabBar({
    required this.activeTab,
    required this.onSwitchTab,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
      child: Container(
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: const Color(0xFFF7F5F2),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            _TabButton(
              label: "Upcoming",
              isActive: activeTab == 'upcoming',
              onTap: () => onSwitchTab('upcoming'),
            ),
            _TabButton(
              label: "Past",
              isActive: activeTab == 'past',
              onTap: () => onSwitchTab('past'),
            ),
            _TabButton(
              label: "All",
              isActive: activeTab == 'all',
              onTap: () => onSwitchTab('all'),
            ),
          ],
        ),
      ),
    );
  }
}

class _TabButton extends StatelessWidget {
  final String label;
  final bool isActive;
  final VoidCallback onTap;

  const _TabButton({
    required this.label,
    required this.isActive,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: isActive ? Colors.white : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            boxShadow: isActive
                ? [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.06),
                      blurRadius: 4,
                      offset: const Offset(0, 1),
                    ),
                  ]
                : const [],
          ),
          child: Center(
            child: Text(
              label,
              style: GoogleFonts.inter(
                fontSize: 13,
                fontWeight:
                    isActive ? FontWeight.w600 : FontWeight.w500,
                color: isActive
                    ? AppColors.deepDarkBrown
                    : AppColors.muted,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Count label ─────────────────────────────────────────────────

class _CountLabel extends StatelessWidget {
  final int count;
  final String tab;

  const _CountLabel({required this.count, required this.tab});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            "$count ${tab.toUpperCase()}",
            style: GoogleFonts.inter(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: AppColors.muted,
              letterSpacing: 0.8,
            ),
          ),
          Text(
            "Tap card to view details",
            style: GoogleFonts.inter(
              fontSize: 11,
              fontWeight: FontWeight.w400,
              color: AppColors.muted.withValues(alpha: 0.5),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Empty state ─────────────────────────────────────────────────

class _EmptyBibleSessions extends StatelessWidget {
  final String tab;
  const _EmptyBibleSessions({required this.tab});

  String get _title {
    switch (tab) {
      case 'upcoming':
        return 'No upcoming sessions';
      case 'past':
        return 'No past sessions yet';
      case 'all':
      default:
        return 'No Bible sessions yet';
    }
  }

  String get _subtitle {
    switch (tab) {
      case 'upcoming':
        return 'Check back soon — speakers add new\nsessions every week.';
      case 'past':
        return "You'll see completed sessions here\nonce some have wrapped up.";
      case 'all':
      default:
        return "When speakers schedule sessions,\nyou'll find them all here.";
    }
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.menu_book_outlined,
              size: 56,
              color: AppColors.muted.withValues(alpha: 0.25),
            ),
            const SizedBox(height: 16),
            Text(
              _title,
              style: GoogleFonts.inter(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: AppColors.deepDarkBrown.withValues(alpha: 0.8),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              _subtitle,
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(
                fontSize: 13,
                fontWeight: FontWeight.w400,
                color: AppColors.muted,
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Session card ────────────────────────────────────────────────

class _BibleSessionCard extends StatefulWidget {
  final BibleSessionModel session;
  final VoidCallback onTap;

  const _BibleSessionCard({
    required this.session,
    required this.onTap,
  });

  @override
  State<_BibleSessionCard> createState() => _BibleSessionCardState();
}

class _BibleSessionCardState extends State<_BibleSessionCard> {
  double _scale = 1.0;

  // Forest-green status pill colour for "upcoming" — AppColors.success
  // is too vivid for the warm brown palette used everywhere on the
  // user side.
  static const Color _kUpcomingGreen = Color(0xFF059669);

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final statusText = session.isUpcoming
        ? session.startsInText
        : session.isCancelled
            ? 'Cancelled'
            : 'Completed';
    final statusColor = session.isUpcoming
        ? _kUpcomingGreen
        : session.isCancelled
            ? AppColors.errorRed
            : AppColors.muted;

    return GestureDetector(
      onTapDown: (_) => setState(() => _scale = 0.98),
      onTapUp: (_) => setState(() => _scale = 1.0),
      onTapCancel: () => setState(() => _scale = 1.0),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _scale,
        duration: const Duration(milliseconds: 100),
        child: Container(
          margin: const EdgeInsets.fromLTRB(20, 0, 20, 12),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AppColors.surfaceWhite,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: AppColors.muted.withValues(alpha: 0.06),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.03),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.primaryBrown.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      "BIBLE SESSION",
                      style: GoogleFonts.inter(
                        fontSize: 9,
                        fontWeight: FontWeight.w700,
                        color: AppColors.primaryBrown,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                session.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.inter(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: AppColors.deepDarkBrown,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                session.category.isNotEmpty
                    ? "${session.category} · ${session.description}"
                    : session.description,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.inter(
                  fontSize: 12,
                  fontWeight: FontWeight.w400,
                  color: AppColors.muted,
                ),
              ),
              const SizedBox(height: 12),
              // Date / time / registered. Wrap so a long date string
              // doesn't overflow on 320-wide devices — instead the
              // bottom row drops onto a new line.
              Wrap(
                spacing: 14,
                runSpacing: 6,
                children: [
                  _MetaChip(
                    icon: Icons.calendar_today_outlined,
                    text: session.formattedDate,
                  ),
                  _MetaChip(
                    icon: Icons.access_time_rounded,
                    text: session.formattedTime,
                  ),
                  _MetaChip(
                    icon: Icons.people_outline_rounded,
                    text: "${session.registrationCount} registered",
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Flexible(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: statusColor.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        statusText,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.inter(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: statusColor,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    "₹${session.price}",
                    style: GoogleFonts.inter(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: AppColors.deepDarkBrown,
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

class _MetaChip extends StatelessWidget {
  final IconData icon;
  final String text;

  const _MetaChip({required this.icon, required this.text});

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
        const SizedBox(width: 5),
        Text(
          text,
          style: GoogleFonts.inter(
            fontSize: 12,
            fontWeight: FontWeight.w400,
            color: AppColors.muted,
          ),
        ),
      ],
    );
  }
}
