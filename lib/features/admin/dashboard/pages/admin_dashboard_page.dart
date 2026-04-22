// Admin dashboard — home hub for the admin role

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import 'package:shimmer/shimmer.dart';

import 'package:gospel_vox/core/services/injection_container.dart';
import 'package:gospel_vox/core/theme/admin_colors.dart';
import 'package:gospel_vox/core/widgets/app_snackbar.dart';
import 'package:gospel_vox/features/admin/dashboard/bloc/dashboard_cubit.dart';
import 'package:gospel_vox/features/admin/dashboard/bloc/dashboard_state.dart';
import 'package:gospel_vox/features/admin/dashboard/data/dashboard_data.dart';
import 'package:gospel_vox/core/router/app_router.dart';
import 'package:gospel_vox/features/auth/data/auth_repository.dart';

final NumberFormat _inr =
    NumberFormat.currency(locale: 'en_IN', symbol: '\u20B9', decimalDigits: 0);

// ═══════════════════════════════════════════════════════════════════════════
// Page
// ═══════════════════════════════════════════════════════════════════════════

class AdminDashboardPage extends StatefulWidget {
  const AdminDashboardPage({super.key});

  @override
  State<AdminDashboardPage> createState() => _AdminDashboardPageState();
}

class _AdminDashboardPageState extends State<AdminDashboardPage> {
  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.dark,
        statusBarBrightness: Brightness.light,
      ),
      child: BlocProvider(
        create: (_) => sl<DashboardCubit>()..loadDashboard(),
        child: Scaffold(
          backgroundColor: AdminColors.background,
          body: SafeArea(
            child: BlocConsumer<DashboardCubit, DashboardState>(
              listener: (context, state) {
                if (state is DashboardError) {
                  AppSnackBar.error(context, state.message);
                }
              },
              builder: (context, state) {
                if (state is DashboardLoaded) {
                  return _Content(data: state.data);
                }
                if (state is DashboardError) {
                  return _ErrorView(
                    message: state.message,
                    onRetry: () =>
                        context.read<DashboardCubit>().loadDashboard(),
                  );
                }
                return const _ShimmerView();
              },
            ),
          ),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Content
// ═══════════════════════════════════════════════════════════════════════════

class _Content extends StatelessWidget {
  final DashboardData data;
  const _Content({required this.data});

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      color: AdminColors.brandBrown,
      onRefresh: () => context.read<DashboardCubit>().refreshDashboard(),
      child: SingleChildScrollView(
        // Admin uses Material-style clamping (not iOS bounce) to
        // keep it visually distinct from the listener side.
        physics: const AlwaysScrollableScrollPhysics(
          parent: ClampingScrollPhysics(),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Header(onSignOut: () async {
              clearCachedRole();
              await sl<AuthRepository>().signOut();
              if (context.mounted) context.go('/select-role');
            }),
            if (data.hasAttentionItems) _AttentionStrip(data: data),
            _OverviewCard(data: data),
            _ManageGrid(data: data),
            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Header + avatar bottom sheet
// ═══════════════════════════════════════════════════════════════════════════

class _Header extends StatefulWidget {
  final VoidCallback onSignOut;
  const _Header({required this.onSignOut});

  @override
  State<_Header> createState() => _HeaderState();
}

class _HeaderState extends State<_Header> {
  bool _pressed = false;

  String _greeting() {
    final h = DateTime.now().hour;
    if (h < 12) return 'Good morning';
    if (h < 17) return 'Good afternoon';
    return 'Good evening';
  }

  void _openProfileSheet() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Drag handle
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: AdminColors.textLight.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              // Admin info
              Row(
                children: [
                  Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: AdminColors.background,
                      shape: BoxShape.circle,
                      border: Border.all(
                          color: AdminColors.brandGold, width: 2),
                    ),
                    child: Center(
                      child: Text('A',
                          style: GoogleFonts.inter(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              color: AdminColors.brandBrown)),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Administrator',
                          style: GoogleFonts.inter(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: AdminColors.textPrimary)),
                      Text('gospelvox1@gmail.com',
                          style: GoogleFonts.inter(
                              fontSize: 12,
                              fontWeight: FontWeight.w400,
                              color: AdminColors.textMuted)),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Container(height: 1, color: AdminColors.borderLight),
              const SizedBox(height: 8),
              // Sign out row
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  Navigator.of(context).pop();
                  widget.onSignOut();
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Row(
                    children: [
                      const Icon(Icons.logout_outlined,
                          size: 20, color: AdminColors.error),
                      const SizedBox(width: 12),
                      Text('Sign Out',
                          style: GoogleFonts.inter(
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                              color: AdminColors.error)),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_greeting(),
                      style: GoogleFonts.inter(
                          fontSize: 13,
                          fontWeight: FontWeight.w400,
                          color: AdminColors.textMuted)),
                  const SizedBox(height: 2),
                  Text('Admin Panel',
                      style: GoogleFonts.inter(
                          fontSize: 24,
                          fontWeight: FontWeight.w700,
                          color: AdminColors.textPrimary)),
                ],
              ),
              GestureDetector(
                onTapDown: (_) => setState(() => _pressed = true),
                onTapUp: (_) => setState(() => _pressed = false),
                onTapCancel: () => setState(() => _pressed = false),
                onTap: _openProfileSheet,
                child: AnimatedScale(
                  scale: _pressed ? 0.95 : 1.0,
                  duration: const Duration(milliseconds: 80),
                  child: Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      shape: BoxShape.circle,
                      border: Border.all(
                          color: AdminColors.brandGold, width: 2),
                    ),
                    child: Center(
                      child: Text('A',
                          style: GoogleFonts.inter(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              color: AdminColors.brandBrown)),
                    ),
                  ),
                ),
              ),
            ],
          ),
          Container(
            margin: const EdgeInsets.only(top: 6),
            width: 48,
            height: 2.5,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(2),
              gradient: const LinearGradient(
                colors: [Color(0xFFBF8840), AdminColors.brandGold],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Attention — 2×2 grid matching reference screenshot
// ═══════════════════════════════════════════════════════════════════════════

// Shared navigation helper. Every sub-page the admin can reach from
// here is potentially a place where a count changes (approve a
// speaker, clear a report, pay a withdrawal). Awaiting the push lets
// us refresh the dashboard the moment the admin comes back, so the
// "Needs Attention" numbers and the Manage badges stay truthful
// without the admin having to pull-to-refresh manually.
Future<void> _pushAndRefresh(BuildContext context, String route) async {
  await context.push(route);
  if (!context.mounted) return;
  context.read<DashboardCubit>().refreshDashboard();
}

class _AttentionStrip extends StatelessWidget {
  final DashboardData data;
  const _AttentionStrip({required this.data});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _Label('NEEDS ATTENTION'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: _AttentionCard(
                      count: data.pendingSpeakers,
                      label: 'Pending\nSpeakers',
                      color: AdminColors.warning,
                      onTap: () =>
                          _pushAndRefresh(context, '/admin/speakers'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _AttentionCard(
                      count: data.pendingMatrimony,
                      label: 'Pending\nMatrimony',
                      color: AdminColors.warning,
                      onTap: () =>
                          _pushAndRefresh(context, '/admin/matrimony'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: _AttentionCard(
                      count: data.openReports,
                      label: 'Open\nReports',
                      color: AdminColors.error,
                      onTap: () =>
                          _pushAndRefresh(context, '/admin/reports'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _AttentionCard(
                      count: data.pendingWithdrawals,
                      label: 'Pending\nWithdrawals',
                      color: AdminColors.warning,
                      onTap: () =>
                          _pushAndRefresh(context, '/admin/withdrawals'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _AttentionCard extends StatefulWidget {
  final int count;
  final String label;
  final Color color;
  final VoidCallback onTap;

  const _AttentionCard({
    required this.count,
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  State<_AttentionCard> createState() => _AttentionCardState();
}

class _AttentionCardState extends State<_AttentionCard> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      onTap: widget.onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedScale(
        scale: _pressed ? 0.97 : 1.0,
        duration: const Duration(milliseconds: 80),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AdminColors.borderLight, width: 1),
            boxShadow: const [
              BoxShadow(
                  color: Color(0x0A000000),
                  blurRadius: 2,
                  offset: Offset(0, 1)),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: Container(
              decoration: BoxDecoration(
                border: Border(
                  left: BorderSide(color: widget.color, width: 3),
                ),
              ),
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(widget.count.toString(),
                      style: GoogleFonts.inter(
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                          color: widget.color)),
                  const SizedBox(height: 4),
                  Text(widget.label,
                      style: GoogleFonts.inter(
                          fontSize: 10,
                          fontWeight: FontWeight.w500,
                          color: AdminColors.textMuted,
                          height: 1.3)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Today's overview — with vertical dividers between metrics
// ═══════════════════════════════════════════════════════════════════════════

class _OverviewCard extends StatelessWidget {
  final DashboardData data;
  const _OverviewCard({required this.data});

  String _fmtCount(int c) =>
      c >= 1000 ? '${(c / 1000).toStringAsFixed(1)}K' : c.toString();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _Label("TODAY'S OVERVIEW"),
        Container(
          margin: const EdgeInsets.symmetric(horizontal: 20),
          decoration: AdminColors.cardDecoration,
          padding: const EdgeInsets.all(20),
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: _Metric(
                      value: _inr.format(data.todayRevenue),
                      label: "Today's Revenue",
                    ),
                  ),
                  Container(
                      width: 1,
                      height: 40,
                      color: AdminColors.borderLight),
                  Expanded(
                    child: _Metric(
                      value: data.activeSessions.toString(),
                      label: 'Active Sessions',
                      badge:
                          data.activeSessions > 0 ? const _LiveDot() : null,
                    ),
                  ),
                  Container(
                      width: 1,
                      height: 40,
                      color: AdminColors.borderLight),
                  Expanded(
                    child: _Metric(
                      value: _fmtCount(data.totalUsers),
                      label: 'Total Users',
                    ),
                  ),
                ],
              ),
              Container(
                margin: const EdgeInsets.symmetric(vertical: 16),
                height: 1,
                color: AdminColors.borderLight,
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('All-Time Revenue',
                      style: GoogleFonts.inter(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          color: AdminColors.textMuted)),
                  Text(_inr.format(data.allTimeRevenue),
                      style: GoogleFonts.inter(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: AdminColors.brandBrown)),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Metric extends StatelessWidget {
  final String value;
  final String label;
  final Widget? badge;
  const _Metric({required this.value, required this.label, this.badge});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(value,
            style: GoogleFonts.inter(
                fontSize: 20,
                fontWeight: FontWeight.w700,
                color: AdminColors.textPrimary)),
        if (badge != null) ...[const SizedBox(height: 2), badge!],
        const SizedBox(height: 4),
        Text(label,
            textAlign: TextAlign.center,
            style: GoogleFonts.inter(
                fontSize: 10,
                fontWeight: FontWeight.w500,
                color: AdminColors.textLight)),
      ],
    );
  }
}

class _LiveDot extends StatelessWidget {
  const _LiveDot();

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 6,
          height: 6,
          decoration: const BoxDecoration(
              color: AdminColors.success, shape: BoxShape.circle),
        ),
        const SizedBox(width: 4),
        Text('Live',
            style: GoogleFonts.inter(
                fontSize: 10,
                fontWeight: FontWeight.w600,
                color: AdminColors.success)),
      ],
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Manage grid — 10 cards, 2 columns
// ═══════════════════════════════════════════════════════════════════════════

class _ManageGrid extends StatelessWidget {
  final DashboardData data;
  const _ManageGrid({required this.data});

  @override
  Widget build(BuildContext context) {
    final items = [
      _MI('\u{1F399}\uFE0F', 'Speakers', 'Approvals & accounts',
          data.pendingSpeakers, '/admin/speakers'),
      _MI('\u{1F465}', 'Users', 'View & manage', 0, '/admin/users'),
      _MI('\u{1F48D}', 'Matrimony', 'Profile approvals',
          data.pendingMatrimony, '/admin/matrimony'),
      _MI('\u{1F6A9}', 'Reports', 'Review queue', data.openReports,
          '/admin/reports'),
      _MI('\u{1F4AC}', 'Sessions', 'Live monitoring', 0,
          '/admin/sessions'),
      _MI('\u{1F4B8}', 'Withdrawals', 'Process payouts',
          data.pendingWithdrawals, '/admin/withdrawals'),
      _MI('\u{1F4CA}', 'Revenue', 'Earnings breakdown', 0,
          '/admin/revenue'),
      _MI('\u{1F4D6}', 'Bible Sessions', 'Session overview', 0,
          '/admin/bible-sessions'),
      _MI('\u{1F6CD}\uFE0F', 'Products', 'Speaker listings', 0,
          '/admin/products'),
      _MI('\u2699\uFE0F', 'Settings', 'Rates & config', 0,
          '/admin/settings'),
      _MI('\u{1FA99}', 'Coin Packs', 'Recharge packs', 0,
          '/admin/coin-packs'),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _Label('MANAGE'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: items.length,
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              crossAxisSpacing: 12,
              mainAxisSpacing: 12,
              childAspectRatio: 1.35,
            ),
            itemBuilder: (context, i) {
              final m = items[i];
              return _ManageCard(
                emoji: m.emoji,
                title: m.title,
                sub: m.sub,
                badge: m.badge,
                onTap: () => _pushAndRefresh(context, m.route),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _MI {
  final String emoji, title, sub, route;
  final int badge;
  const _MI(this.emoji, this.title, this.sub, this.badge, this.route);
}

class _ManageCard extends StatefulWidget {
  final String emoji, title, sub;
  final int badge;
  final VoidCallback onTap;

  const _ManageCard({
    required this.emoji,
    required this.title,
    required this.sub,
    required this.badge,
    required this.onTap,
  });

  @override
  State<_ManageCard> createState() => _ManageCardState();
}

class _ManageCardState extends State<_ManageCard> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      onTap: widget.onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedScale(
        scale: _pressed ? 0.97 : 1.0,
        duration: const Duration(milliseconds: 80),
        child: Container(
          decoration: AdminColors.cardDecoration,
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
          child: Stack(
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: AdminColors.background,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    alignment: Alignment.center,
                    child:
                        Text(widget.emoji, style: const TextStyle(fontSize: 18)),
                  ),
                  const SizedBox(height: 10),
                  Text(widget.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.inter(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: AdminColors.textPrimary)),
                  const SizedBox(height: 2),
                  Text(widget.sub,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.inter(
                          fontSize: 11,
                          fontWeight: FontWeight.w400,
                          color: AdminColors.textLight)),
                ],
              ),
              if (widget.badge > 0)
                Positioned(
                  top: 0,
                  right: 0,
                  child: Container(
                    constraints:
                        const BoxConstraints(minWidth: 22, minHeight: 22),
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    decoration: BoxDecoration(
                      color: AdminColors.error,
                      borderRadius: BorderRadius.circular(11),
                    ),
                    alignment: Alignment.center,
                    child: Text(widget.badge.toString(),
                        style: GoogleFonts.inter(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: Colors.white)),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Shared
// ═══════════════════════════════════════════════════════════════════════════

class _Label extends StatelessWidget {
  final String text;
  const _Label(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 12),
      child: Text(text,
          style: GoogleFonts.inter(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: AdminColors.textLight,
              letterSpacing: 0.8)),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Shimmer
// ═══════════════════════════════════════════════════════════════════════════

class _ShimmerView extends StatelessWidget {
  const _ShimmerView();

  static BoxDecoration _box() => BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(AdminColors.cardRadius));

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      physics: const NeverScrollableScrollPhysics(),
      child: Shimmer.fromColors(
        baseColor: const Color(0xFFE5E7EB),
        highlightColor: const Color(0xFFF3F4F6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 20),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(width: 90, height: 14, decoration: _box()),
                      const SizedBox(height: 8),
                      Container(
                          width: 140, height: 24, decoration: _box()),
                    ],
                  ),
                  Container(
                      width: 42,
                      height: 42,
                      decoration: const BoxDecoration(
                          color: Colors.white, shape: BoxShape.circle)),
                ],
              ),
            ),
            const _Label('NEEDS ATTENTION'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Column(
                children: [
                  Row(children: [
                    Expanded(
                        child: Container(height: 72, decoration: _box())),
                    const SizedBox(width: 10),
                    Expanded(
                        child: Container(height: 72, decoration: _box())),
                  ]),
                  const SizedBox(height: 10),
                  Row(children: [
                    Expanded(
                        child: Container(height: 72, decoration: _box())),
                    const SizedBox(width: 10),
                    Expanded(
                        child: Container(height: 72, decoration: _box())),
                  ]),
                ],
              ),
            ),
            const _Label("TODAY'S OVERVIEW"),
            Container(
                margin: const EdgeInsets.symmetric(horizontal: 20),
                height: 140,
                decoration: _box()),
            const _Label('MANAGE'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: 11,
                gridDelegate:
                    const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  crossAxisSpacing: 12,
                  mainAxisSpacing: 12,
                  childAspectRatio: 1.35,
                ),
                itemBuilder: (_, _) => Container(decoration: _box()),
              ),
            ),
            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Error
// ═══════════════════════════════════════════════════════════════════════════

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
          const Icon(Icons.cloud_off_outlined,
              size: 48, color: AdminColors.textLight),
          const SizedBox(height: 16),
          Text(message,
              style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.w400,
                  color: AdminColors.textMuted)),
          const SizedBox(height: 24),
          TextButton.icon(
            icon: const Icon(Icons.refresh, color: AdminColors.brandBrown),
            label: Text('Try Again',
                style: GoogleFonts.inter(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: AdminColors.brandBrown)),
            onPressed: onRetry,
          ),
        ],
      ),
    );
  }
}
