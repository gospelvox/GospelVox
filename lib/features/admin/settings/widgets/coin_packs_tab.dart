// Coin packs tab — list + CRUD for coin packs

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shimmer/shimmer.dart';

import 'package:gospel_vox/core/services/injection_container.dart';
import 'package:gospel_vox/core/theme/admin_colors.dart';
import 'package:gospel_vox/core/widgets/app_snackbar.dart';
import 'package:gospel_vox/core/widgets/confirm_changes_sheet.dart';
import 'package:gospel_vox/features/admin/settings/bloc/coin_packs_cubit.dart';
import 'package:gospel_vox/features/admin/settings/bloc/coin_packs_state.dart';
import 'package:gospel_vox/features/admin/settings/data/coin_pack_model.dart';
import 'package:gospel_vox/features/admin/settings/widgets/pack_edit_sheet.dart';

class CoinPacksTab extends StatefulWidget {
  const CoinPacksTab({super.key});

  @override
  State<CoinPacksTab> createState() => _CoinPacksTabState();
}

class _CoinPacksTabState extends State<CoinPacksTab>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);

    return BlocProvider(
      create: (_) => sl<CoinPacksCubit>()..loadPacks(),
      child: BlocConsumer<CoinPacksCubit, CoinPacksState>(
        listener: (context, state) {
          if (state is CoinPacksError) {
            AppSnackBar.error(context, state.message);
          }
        },
        builder: (context, state) {
          if (state is CoinPacksLoading || state is CoinPacksInitial) {
            return const _PacksShimmer();
          }
          if (state is CoinPacksLoaded) {
            return _PacksList(
              active: state.activePacks,
              inactive: state.inactivePacks,
            );
          }
          return const SizedBox.shrink();
        },
      ),
    );
  }
}

class _PacksList extends StatelessWidget {
  final List<CoinPackModel> active;
  final List<CoinPackModel> inactive;

  const _PacksList({required this.active, required this.inactive});

  void _openAdd(BuildContext context) {
    final cubit = context.read<CoinPacksCubit>();
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => PackEditSheet(cubit: cubit),
    );
  }

  void _openEdit(BuildContext context, CoinPackModel pack) {
    final cubit = context.read<CoinPacksCubit>();
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => PackEditSheet(cubit: cubit, existing: pack),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _AddButton(onTap: () => _openAdd(context)),
          if (active.isNotEmpty) ...[
            const SizedBox(height: 24),
            _sectionLabel('ACTIVE PACKS'),
            const SizedBox(height: 12),
            for (final p in active) ...[
              _PackCard(
                pack: p,
                onEdit: () => _openEdit(context, p),
                onToggle: (val) async {
                  if (!val) {
                    final ok = await ConfirmChangesSheet.show(
                      context: context,
                      title: 'Deactivate Pack',
                      isDangerous: true,
                      changes: [
                        ChangeItem(
                          field: p.label,
                          oldValue: 'Active',
                          newValue: 'Inactive — hidden from users',
                        ),
                      ],
                    );
                    if (!ok) return;
                  }
                  if (context.mounted) {
                    context.read<CoinPacksCubit>().toggleActive(p.id, val);
                  }
                },
              ),
              const SizedBox(height: 12),
            ],
          ],
          if (inactive.isNotEmpty) ...[
            const SizedBox(height: 24),
            _sectionLabel('INACTIVE PACKS'),
            const SizedBox(height: 12),
            for (final p in inactive) ...[
              _PackCard(
                pack: p,
                onEdit: () => _openEdit(context, p),
                onToggle: (val) {
                  context.read<CoinPacksCubit>().toggleActive(p.id, val);
                },
              ),
              const SizedBox(height: 12),
            ],
          ],
          const SizedBox(height: 24),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: AdminColors.infoBg,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                  color: AdminColors.info.withValues(alpha: 0.2)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('\u2139\uFE0F', style: TextStyle(fontSize: 16)),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Pack changes appear instantly in the user wallet screen. Only one pack can be marked Popular at a time.',
                    style: GoogleFonts.inter(
                        fontSize: 12,
                        fontWeight: FontWeight.w400,
                        color: AdminColors.textBody),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 40),
        ],
      ),
    );
  }

  Widget _sectionLabel(String text) => Text(text,
      style: GoogleFonts.inter(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: AdminColors.textLight,
          letterSpacing: 0.8));
}

class _AddButton extends StatefulWidget {
  final VoidCallback onTap;
  const _AddButton({required this.onTap});

  @override
  State<_AddButton> createState() => _AddButtonState();
}

class _AddButtonState extends State<_AddButton> {
  bool _p = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _p = true),
      onTapUp: (_) => setState(() => _p = false),
      onTapCancel: () => setState(() => _p = false),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _p ? 0.97 : 1.0,
        duration: const Duration(milliseconds: 80),
        child: Container(
          width: double.infinity,
          height: 48,
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border.all(color: AdminColors.divider, width: 1.5),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.add, size: 18, color: AdminColors.textBody),
              const SizedBox(width: 8),
              Text('Add New Pack',
                  style: GoogleFonts.inter(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: AdminColors.textBody)),
            ],
          ),
        ),
      ),
    );
  }
}

class _PackCard extends StatelessWidget {
  final CoinPackModel pack;
  final VoidCallback onEdit;
  final ValueChanged<bool> onToggle;

  const _PackCard({
    required this.pack,
    required this.onEdit,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: AdminColors.cardDecoration,
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(pack.label,
                        style: GoogleFonts.inter(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: AdminColors.textPrimary)),
                    if (pack.discountPercent > 0) ...[
                      const SizedBox(height: 2),
                      Text('${pack.discountPercent}% off',
                          style: GoogleFonts.inter(
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                              color: AdminColors.success)),
                    ],
                  ],
                ),
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (pack.isPopular)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                      margin: const EdgeInsets.only(right: 10),
                      decoration: BoxDecoration(
                        color: AdminColors.warningBg,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text('\u2B50 Popular',
                          style: GoogleFonts.inter(
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                              color: AdminColors.warning)),
                    ),
                  Switch.adaptive(
                    value: pack.isActive,
                    activeTrackColor: AdminColors.success,
                    onChanged: onToggle,
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _PackStat('${pack.coins}', 'Coins'),
              _PackStat('\u20B9${pack.price}', 'Price'),
              _PackStat(
                  '\u20B9${pack.oldPrice}', 'Old Price', isStrike: true),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                  '\u20B9${pack.pricePerCoin.toStringAsFixed(2)}/coin',
                  style: GoogleFonts.inter(
                      fontSize: 12,
                      fontWeight: FontWeight.w400,
                      color: AdminColors.textMuted)),
              GestureDetector(
                onTap: onEdit,
                behavior: HitTestBehavior.opaque,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Text('Edit',
                      style: GoogleFonts.inter(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: AdminColors.brandBrown)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PackStat extends StatelessWidget {
  final String value;
  final String label;
  final bool isStrike;

  const _PackStat(this.value, this.label, {this.isStrike = false});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(value,
            style: GoogleFonts.inter(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: isStrike
                  ? AdminColors.textLight
                  : AdminColors.textPrimary,
              decoration:
                  isStrike ? TextDecoration.lineThrough : null,
            )),
        const SizedBox(height: 2),
        Text(label,
            style: GoogleFonts.inter(
                fontSize: 11,
                fontWeight: FontWeight.w400,
                color: AdminColors.textLight)),
      ],
    );
  }
}

class _PacksShimmer extends StatelessWidget {
  const _PacksShimmer();

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.all(20),
      child: Shimmer.fromColors(
        baseColor: const Color(0xFFE5E7EB),
        highlightColor: const Color(0xFFF3F4F6),
        child: Column(
          children: [
            Container(
                height: 48,
                decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12))),
            const SizedBox(height: 24),
            for (int i = 0; i < 4; i++) ...[
              Container(
                  height: 140,
                  decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(14))),
              const SizedBox(height: 12),
            ],
          ],
        ),
      ),
    );
  }
}
