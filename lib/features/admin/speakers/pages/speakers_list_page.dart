// Admin speaker management list — tabbed view of pending / active /
// suspended speakers.
//
// The TabBar is wrapped in a rounded pill container rather than the
// default underline because this dashboard follows a Linear-style
// "segmented control" aesthetic throughout. Counts are shown inline
// on each tab so the admin can see their pending queue without
// switching tabs.

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shimmer/shimmer.dart';

import 'package:gospel_vox/core/services/injection_container.dart';
import 'package:gospel_vox/core/theme/admin_colors.dart';
import 'package:gospel_vox/core/widgets/app_snackbar.dart';
import 'package:gospel_vox/features/admin/speakers/bloc/speakers_cubit.dart';
import 'package:gospel_vox/features/admin/speakers/bloc/speakers_state.dart';
import 'package:gospel_vox/features/admin/speakers/data/speaker_model.dart';

class SpeakersListPage extends StatelessWidget {
  const SpeakersListPage({super.key});

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.dark,
      ),
      child: BlocProvider<SpeakersCubit>(
        create: (_) => sl<SpeakersCubit>()..loadSpeakers(),
        child: const _SpeakersListView(),
      ),
    );
  }
}

class _SpeakersListView extends StatefulWidget {
  const _SpeakersListView();

  @override
  State<_SpeakersListView> createState() => _SpeakersListViewState();
}

class _SpeakersListViewState extends State<_SpeakersListView>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _openDetail(BuildContext ctx, SpeakerModel s) async {
    // push<bool> — detail page pops `true` after a successful
    // approve/reject/suspend so we know to refresh the lists.
    final changed = await ctx.push<bool>('/admin/speakers/${s.uid}');
    if (!mounted) return;
    if (changed == true) {
      // ignore: use_build_context_synchronously
      ctx.read<SpeakersCubit>().loadSpeakers();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AdminColors.background,
      appBar: _buildAppBar(context),
      body: BlocConsumer<SpeakersCubit, SpeakersState>(
        listener: (ctx, state) {
          if (state is SpeakersError) {
            AppSnackBar.error(ctx, state.message);
          }
        },
        builder: (ctx, state) {
          if (state is SpeakersError) {
            return _ErrorView(
              message: state.message,
              onRetry: () => ctx.read<SpeakersCubit>().loadSpeakers(),
            );
          }

          if (state is SpeakersLoaded) {
            return TabBarView(
              controller: _tabController,
              children: [
                _SpeakerList(
                  speakers: state.pending,
                  tabKey: 'pending',
                  onTap: (s) => _openDetail(ctx, s),
                  onRefresh: () =>
                      ctx.read<SpeakersCubit>().loadSpeakers(),
                ),
                _SpeakerList(
                  speakers: state.approved,
                  tabKey: 'active',
                  onTap: (s) => _openDetail(ctx, s),
                  onRefresh: () =>
                      ctx.read<SpeakersCubit>().loadSpeakers(),
                ),
                _SpeakerList(
                  speakers: state.suspended,
                  tabKey: 'suspended',
                  onTap: (s) => _openDetail(ctx, s),
                  onRefresh: () =>
                      ctx.read<SpeakersCubit>().loadSpeakers(),
                ),
              ],
            );
          }

          // Loading or Initial — three shimmer tabs so the user sees
          // the layout before the data arrives.
          return TabBarView(
            controller: _tabController,
            children: const [
              _ShimmerList(),
              _ShimmerList(),
              _ShimmerList(),
            ],
          );
        },
      ),
    );
  }

  PreferredSizeWidget _buildAppBar(BuildContext context) {
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
        'Speaker Management',
        style: GoogleFonts.inter(
          fontSize: 18,
          fontWeight: FontWeight.w600,
          color: AdminColors.textPrimary,
        ),
      ),
      centerTitle: false,
      bottom: PreferredSize(
        preferredSize: const Size.fromHeight(60),
        child: BlocBuilder<SpeakersCubit, SpeakersState>(
          buildWhen: (prev, curr) =>
              prev.runtimeType != curr.runtimeType ||
              (prev is SpeakersLoaded &&
                  curr is SpeakersLoaded &&
                  prev.counts != curr.counts),
          builder: (_, state) {
            final counts = state is SpeakersLoaded
                ? state.counts
                : const <String, int>{};
            return _TabBarPill(
              controller: _tabController,
              counts: counts,
            );
          },
        ),
      ),
    );
  }
}

// ─── App bar pill-style tab bar ────────────────────────────────

class _TabBarPill extends StatelessWidget {
  final TabController controller;
  final Map<String, int> counts;

  const _TabBarPill({required this.controller, required this.counts});

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
            _TabLabel(label: 'Pending', count: counts['pending'] ?? 0),
            _TabLabel(label: 'Active', count: counts['approved'] ?? 0),
            _TabLabel(
              label: 'Suspended',
              count: counts['suspended'] ?? 0,
            ),
          ],
        ),
      ),
    );
  }
}

class _TabLabel extends StatelessWidget {
  final String label;
  final int count;
  const _TabLabel({required this.label, required this.count});

  @override
  Widget build(BuildContext context) {
    return Tab(
      height: 38,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (count > 0) ...[
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 6,
                vertical: 2,
              ),
              decoration: BoxDecoration(
                color: label == 'Pending'
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

// ─── List body for each tab ────────────────────────────────────

class _SpeakerList extends StatelessWidget {
  final List<SpeakerModel> speakers;
  final String tabKey; // pending | active | suspended
  final void Function(SpeakerModel) onTap;
  final Future<void> Function() onRefresh;

  const _SpeakerList({
    required this.speakers,
    required this.tabKey,
    required this.onTap,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    if (speakers.isEmpty) {
      return RefreshIndicator(
        color: AdminColors.brandBrown,
        onRefresh: onRefresh,
        // A scrollable child is required so pull-to-refresh works
        // when the list is empty.
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(
            parent: ClampingScrollPhysics(),
          ),
          children: [
            SizedBox(
              height: MediaQuery.of(context).size.height * 0.6,
              child: _EmptyState(tabKey: tabKey),
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
        itemCount: speakers.length,
        itemBuilder: (_, i) => _SpeakerListCard(
          speaker: speakers[i],
          onTap: () => onTap(speakers[i]),
        ),
      ),
    );
  }
}

// ─── List card ─────────────────────────────────────────────────

class _SpeakerListCard extends StatefulWidget {
  final SpeakerModel speaker;
  final VoidCallback onTap;

  const _SpeakerListCard({required this.speaker, required this.onTap});

  @override
  State<_SpeakerListCard> createState() => _SpeakerListCardState();
}

class _SpeakerListCardState extends State<_SpeakerListCard> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final s = widget.speaker;
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
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              _Avatar(speaker: s, size: 48, fontSize: 18),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            s.fullName.isEmpty
                                ? 'Unnamed speaker'
                                : s.fullName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: GoogleFonts.inter(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: AdminColors.textPrimary,
                            ),
                          ),
                        ),
                        if (s.status != 'pending') ...[
                          const SizedBox(width: 8),
                          _StatusBadge(status: s.status),
                        ],
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      _subtitleFor(s),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.inter(
                        fontSize: 12,
                        fontWeight: FontWeight.w400,
                        color: AdminColors.textMuted,
                      ),
                    ),
                    if (s.status == 'pending' && s.timeAgo.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        'Applied ${s.timeAgo}',
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
              const Icon(
                Icons.chevron_right,
                size: 20,
                color: AdminColors.textLight,
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _subtitleFor(SpeakerModel s) {
    final parts = <String>[];
    if (s.denomination.isNotEmpty) parts.add(s.denomination);
    if (s.location.isNotEmpty) parts.add(s.location);
    if (parts.isEmpty) return 'No details provided';
    return parts.join(' · ');
  }
}

// ─── Avatar with cached image + letter fallback ───────────────

class _Avatar extends StatelessWidget {
  final SpeakerModel speaker;
  final double size;
  final double fontSize;

  const _Avatar({
    required this.speaker,
    required this.size,
    required this.fontSize,
  });

  @override
  Widget build(BuildContext context) {
    // CachedNetworkImage is worth the extra lines here: admins
    // scrolling through long lists otherwise re-download the same
    // avatars on every rebuild, which is expensive on mobile data.
    final fallback = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        color: AdminColors.inputBackground,
      ),
      child: Text(
        speaker.initial,
        style: GoogleFonts.inter(
          fontSize: fontSize,
          fontWeight: FontWeight.w700,
          color: AdminColors.textMuted,
        ),
      ),
    );

    if (!speaker.hasPhoto) return fallback;

    return ClipOval(
      child: CachedNetworkImage(
        imageUrl: speaker.photoUrl,
        width: size,
        height: size,
        fit: BoxFit.cover,
        placeholder: (_, _) => fallback,
        errorWidget: (_, _, _) => fallback,
      ),
    );
  }
}

// ─── Status badge ──────────────────────────────────────────────

class _StatusBadge extends StatelessWidget {
  final String status;
  const _StatusBadge({required this.status});

  @override
  Widget build(BuildContext context) {
    final (bg, fg, label) = switch (status) {
      'approved' => (AdminColors.successBg, AdminColors.success, 'Active'),
      'suspended' => (
          AdminColors.errorBg,
          AdminColors.error,
          'Suspended'
        ),
      'rejected' => (
          AdminColors.errorBg,
          AdminColors.error,
          'Rejected'
        ),
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

// ─── Shimmer list skeleton ─────────────────────────────────────

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
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: AdminColors.inputBackground,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      height: 14,
                      width: 160,
                      decoration: BoxDecoration(
                        color: AdminColors.inputBackground,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      height: 12,
                      width: 110,
                      decoration: BoxDecoration(
                        color: AdminColors.inputBackground,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Empty state ───────────────────────────────────────────────

class _EmptyState extends StatelessWidget {
  final String tabKey;
  const _EmptyState({required this.tabKey});

  @override
  Widget build(BuildContext context) {
    final (icon, title, body) = switch (tabKey) {
      'pending' => (
          Icons.inbox_outlined,
          'No pending applications',
          'New applications will appear here',
        ),
      'active' => (
          Icons.people_outline,
          'No active speakers',
          'Approved speakers will appear here',
        ),
      'suspended' => (
          Icons.block_outlined,
          'No suspended speakers',
          'Suspended speakers will appear here',
        ),
      _ => (Icons.search_off, 'Nothing here', ''),
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

// ─── Error retry view ──────────────────────────────────────────

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
