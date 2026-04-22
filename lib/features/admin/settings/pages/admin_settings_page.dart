// Admin settings — tabbed screen (Configuration + Coin Packs)

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:gospel_vox/core/services/injection_container.dart';
import 'package:gospel_vox/core/theme/admin_colors.dart';
import 'package:gospel_vox/features/admin/settings/bloc/settings_cubit.dart';
import 'package:gospel_vox/features/admin/settings/widgets/coin_packs_tab.dart';
import 'package:gospel_vox/features/admin/settings/widgets/configuration_tab.dart';

class AdminSettingsPage extends StatefulWidget {
  final int initialTab;

  const AdminSettingsPage({super.key, this.initialTab = 0});

  @override
  State<AdminSettingsPage> createState() => _AdminSettingsPageState();
}

class _AdminSettingsPageState extends State<AdminSettingsPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(
      length: 2,
      vsync: this,
      initialIndex: widget.initialTab,
    );
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.dark,
        statusBarBrightness: Brightness.light,
      ),
      child: BlocProvider(
        create: (_) => sl<SettingsCubit>()..loadSettings(),
        child: Scaffold(
          backgroundColor: AdminColors.background,
          appBar: AppBar(
            backgroundColor: Colors.white,
            elevation: 0,
            surfaceTintColor: Colors.transparent,
            scrolledUnderElevation: 0,
            leading: GestureDetector(
              onTap: () => context.pop(),
              behavior: HitTestBehavior.opaque,
              child: const Padding(
                padding: EdgeInsets.all(12),
                child: Icon(Icons.arrow_back, color: AdminColors.textPrimary, size: 22),
              ),
            ),
            title: Text('Settings',
                style: GoogleFonts.inter(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: AdminColors.textPrimary)),
            centerTitle: false,
            bottom: PreferredSize(
              preferredSize: const Size.fromHeight(56),
              child: Container(
                margin: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  color: AdminColors.inputBackground,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: TabBar(
                  controller: _tabController,
                  indicator: BoxDecoration(
                    color: AdminColors.brandBrown,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  indicatorSize: TabBarIndicatorSize.tab,
                  dividerColor: Colors.transparent,
                  labelColor: Colors.white,
                  labelStyle: GoogleFonts.inter(
                      fontSize: 13, fontWeight: FontWeight.w600),
                  unselectedLabelColor: AdminColors.textMuted,
                  unselectedLabelStyle: GoogleFonts.inter(
                      fontSize: 13, fontWeight: FontWeight.w500),
                  tabs: const [
                    Tab(text: '\u2699\uFE0F Configuration'),
                    Tab(text: '\u{1FA99} Coin Packs'),
                  ],
                ),
              ),
            ),
          ),
          body: TabBarView(
            controller: _tabController,
            children: const [
              ConfigurationTab(),
              CoinPacksTab(),
            ],
          ),
        ),
      ),
    );
  }
}
