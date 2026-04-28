// Admin user management — read-only list of registered users with
// case-insensitive client-side search across name + email. Mirrors
// the SpeakersListPage shell: shimmer placeholders → loaded list /
// empty state / error retry, all under a single pull-to-refresh.

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
import 'package:gospel_vox/features/admin/users/bloc/admin_users_cubit.dart';
import 'package:gospel_vox/features/admin/users/bloc/admin_users_state.dart';
import 'package:gospel_vox/features/admin/users/data/admin_user_model.dart';

class AdminUsersPage extends StatelessWidget {
  const AdminUsersPage({super.key});

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.dark,
      ),
      child: BlocProvider<AdminUsersCubit>(
        create: (_) => sl<AdminUsersCubit>()..loadUsers(),
        child: const _AdminUsersView(),
      ),
    );
  }
}

class _AdminUsersView extends StatefulWidget {
  const _AdminUsersView();

  @override
  State<_AdminUsersView> createState() => _AdminUsersViewState();
}

class _AdminUsersViewState extends State<_AdminUsersView> {
  final TextEditingController _searchCtrl = TextEditingController();

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AdminColors.background,
      appBar: AppBar(
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
          'User Management',
          style: GoogleFonts.inter(
            fontSize: 18,
            fontWeight: FontWeight.w600,
            color: AdminColors.textPrimary,
          ),
        ),
        centerTitle: false,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(60),
          child: _SearchBar(
            controller: _searchCtrl,
            onChanged: (v) =>
                context.read<AdminUsersCubit>().search(v),
          ),
        ),
      ),
      body: BlocConsumer<AdminUsersCubit, AdminUsersState>(
        listener: (ctx, state) {
          if (state is AdminUsersError) {
            AppSnackBar.error(ctx, state.message);
          }
        },
        builder: (ctx, state) {
          if (state is AdminUsersError) {
            return _ErrorView(
              message: state.message,
              onRetry: () => ctx.read<AdminUsersCubit>().loadUsers(),
            );
          }
          if (state is AdminUsersLoaded) {
            return _UsersList(
              users: state.filtered,
              hasQuery: state.searchQuery.isNotEmpty,
              onRefresh: () =>
                  ctx.read<AdminUsersCubit>().loadUsers(),
            );
          }
          return const _ShimmerList();
        },
      ),
    );
  }
}

// ─── Search bar ────────────────────────────────────────────────
//
// Stateful so the clear-X visibility tracks the controller text.
// As a StatelessWidget the X check (`controller.text.isNotEmpty`)
// only re-evaluates when the parent rebuilds, which it doesn't on
// keystroke — leaving the X stuck off-screen even with text in the
// field. Listening to the controller ourselves and calling setState
// keeps the X honest.

class _SearchBar extends StatefulWidget {
  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  const _SearchBar({required this.controller, required this.onChanged});

  @override
  State<_SearchBar> createState() => _SearchBarState();
}

class _SearchBarState extends State<_SearchBar> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onTextChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onTextChanged);
    super.dispose();
  }

  void _onTextChanged() {
    if (!mounted) return;
    // Empty setState — we only need to flip the X icon
    // visibility, which reads controller.text in build().
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final hasText = widget.controller.text.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Container(
        height: 44,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: AdminColors.inputBackground,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            const Icon(
              Icons.search,
              size: 18,
              color: AdminColors.textMuted,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: widget.controller,
                onChanged: widget.onChanged,
                textInputAction: TextInputAction.search,
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.w400,
                  color: AdminColors.textPrimary,
                ),
                decoration: InputDecoration(
                  isCollapsed: true,
                  border: InputBorder.none,
                  hintText: 'Search by name or email',
                  hintStyle: GoogleFonts.inter(
                    fontSize: 14,
                    fontWeight: FontWeight.w400,
                    color: AdminColors.textLight,
                  ),
                ),
              ),
            ),
            if (hasText)
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  widget.controller.clear();
                  widget.onChanged('');
                },
                child: const Padding(
                  padding: EdgeInsets.all(4),
                  child: Icon(
                    Icons.close,
                    size: 16,
                    color: AdminColors.textMuted,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ─── List body ─────────────────────────────────────────────────

class _UsersList extends StatelessWidget {
  final List<AdminUserModel> users;
  final bool hasQuery;
  final Future<void> Function() onRefresh;

  const _UsersList({
    required this.users,
    required this.hasQuery,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    if (users.isEmpty) {
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
              child: _EmptyState(hasQuery: hasQuery),
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
        itemCount: users.length,
        itemBuilder: (_, i) => _UserCard(user: users[i]),
      ),
    );
  }
}

// ─── User card ─────────────────────────────────────────────────

class _UserCard extends StatelessWidget {
  final AdminUserModel user;
  const _UserCard({required this.user});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      padding: const EdgeInsets.all(14),
      decoration: AdminColors.cardDecoration,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          _Avatar(user: user, size: 44, fontSize: 16),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  user.displayName.isEmpty
                      ? 'Unnamed user'
                      : user.displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: AdminColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  user.email.isEmpty ? 'No email' : user.email,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.inter(
                    fontSize: 12,
                    fontWeight: FontWeight.w400,
                    color: AdminColors.textMuted,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: AdminColors.inputBackground,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '${user.coinBalance} coins',
                  style: GoogleFonts.inter(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: AdminColors.textBody,
                  ),
                ),
              ),
              if (user.joinDate.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  'Joined ${user.joinDate}',
                  style: GoogleFonts.inter(
                    fontSize: 10,
                    fontWeight: FontWeight.w400,
                    color: AdminColors.textLight,
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

// ─── Avatar ────────────────────────────────────────────────────

class _Avatar extends StatelessWidget {
  final AdminUserModel user;
  final double size;
  final double fontSize;

  const _Avatar({
    required this.user,
    required this.size,
    required this.fontSize,
  });

  @override
  Widget build(BuildContext context) {
    final fallback = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        color: AdminColors.inputBackground,
      ),
      child: Text(
        user.initial,
        style: GoogleFonts.inter(
          fontSize: fontSize,
          fontWeight: FontWeight.w700,
          color: AdminColors.textMuted,
        ),
      ),
    );

    if (!user.hasPhoto) return fallback;

    return ClipOval(
      child: CachedNetworkImage(
        imageUrl: user.photoUrl,
        width: size,
        height: size,
        fit: BoxFit.cover,
        placeholder: (_, _) => fallback,
        errorWidget: (_, _, _) => fallback,
      ),
    );
  }
}

// ─── Shimmer placeholder ───────────────────────────────────────

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
                width: 44,
                height: 44,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: AdminColors.inputBackground,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      height: 14,
                      width: 140,
                      decoration: BoxDecoration(
                        color: AdminColors.inputBackground,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      height: 12,
                      width: 100,
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
  final bool hasQuery;
  const _EmptyState({required this.hasQuery});

  @override
  Widget build(BuildContext context) {
    final (icon, title, body) = hasQuery
        ? (
            Icons.search_off,
            'No matches',
            'No users match your search',
          )
        : (
            Icons.people_outline,
            'No users registered yet',
            'New sign-ups will appear here',
          );

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
