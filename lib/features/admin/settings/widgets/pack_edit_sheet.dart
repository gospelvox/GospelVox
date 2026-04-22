// Add / edit coin pack bottom sheet

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:gospel_vox/core/theme/admin_colors.dart';
import 'package:gospel_vox/core/widgets/confirm_changes_sheet.dart';
import 'package:gospel_vox/features/admin/settings/bloc/coin_packs_cubit.dart';
import 'package:gospel_vox/features/admin/settings/data/coin_pack_model.dart';

class PackEditSheet extends StatefulWidget {
  final CoinPacksCubit cubit;
  final CoinPackModel? existing;

  const PackEditSheet({super.key, required this.cubit, this.existing});

  bool get isEdit => existing != null;

  @override
  State<PackEditSheet> createState() => _PackEditSheetState();
}

class _PackEditSheetState extends State<PackEditSheet> {
  late final TextEditingController _labelCtrl;
  late final TextEditingController _coinsCtrl;
  late final TextEditingController _priceCtrl;
  bool _isPopular = false;
  String? _labelErr, _coinsErr, _priceErr;

  @override
  void initState() {
    super.initState();
    final p = widget.existing;
    _labelCtrl = TextEditingController(text: p?.label ?? '');
    _coinsCtrl = TextEditingController(text: p != null ? '${p.coins}' : '');
    _priceCtrl = TextEditingController(text: p != null ? '${p.price}' : '');
    _isPopular = p?.isPopular ?? false;
  }

  @override
  void dispose() {
    _labelCtrl.dispose();
    _coinsCtrl.dispose();
    _priceCtrl.dispose();
    super.dispose();
  }

  bool _validate() {
    final lErr = _labelCtrl.text.trim().isEmpty ? 'Label is required' : null;
    final coins = int.tryParse(_coinsCtrl.text.trim());
    final cErr =
        (coins == null || coins <= 0) ? 'Enter valid coin amount' : null;
    final price = int.tryParse(_priceCtrl.text.trim());
    final pErr = (price == null || price <= 0) ? 'Enter valid price' : null;

    setState(() {
      _labelErr = lErr;
      _coinsErr = cErr;
      _priceErr = pErr;
    });

    return lErr == null && cErr == null && pErr == null;
  }

  Future<void> _save() async {
    if (!_validate()) return;

    final pack = CoinPackModel(
      id: widget.existing?.id ?? 'pack_${_coinsCtrl.text.trim()}',
      coins: int.parse(_coinsCtrl.text.trim()),
      price: int.parse(_priceCtrl.text.trim()),
      label: _labelCtrl.text.trim(),
      order: widget.existing?.order ?? 99,
      isPopular: _isPopular,
      isActive: widget.existing?.isActive ?? true,
    );

    if (widget.isEdit) {
      final changes = <ChangeItem>[];
      final old = widget.existing!;
      if (old.label != pack.label) {
        changes.add(ChangeItem(
            field: 'Label', oldValue: old.label, newValue: pack.label));
      }
      if (old.coins != pack.coins) {
        changes.add(ChangeItem(
            field: 'Coins',
            oldValue: '${old.coins}',
            newValue: '${pack.coins}'));
      }
      if (old.price != pack.price) {
        changes.add(ChangeItem(
            field: 'Price',
            oldValue: '₹${old.price}',
            newValue: '₹${pack.price}'));
      }
      if (old.isPopular != pack.isPopular) {
        changes.add(ChangeItem(
            field: 'Popular',
            oldValue: old.isPopular ? 'Yes' : 'No',
            newValue: pack.isPopular ? 'Yes' : 'No'));
      }

      if (changes.isEmpty) {
        if (mounted) Navigator.pop(context);
        return;
      }

      final ok = await ConfirmChangesSheet.show(
        context: context,
        title: 'Update Pack',
        changes: changes,
      );
      if (!ok || !mounted) return;

      await widget.cubit.updatePack(pack);
    } else {
      await widget.cubit.addPack(pack);
    }

    if (_isPopular) {
      await widget.cubit.setPopular(pack.id);
    }

    if (mounted) Navigator.pop(context);
  }

  Future<void> _delete() async {
    final old = widget.existing!;
    final ok = await ConfirmChangesSheet.show(
      context: context,
      title: 'Delete Pack',
      isDangerous: true,
      changes: [
        ChangeItem(
          field: old.label,
          oldValue: '${old.coins} coins for ₹${old.price}',
          newValue: 'Permanently deleted',
        ),
      ],
    );
    if (!ok || !mounted) return;
    await widget.cubit.deletePack(old.id);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final viewInsets = MediaQuery.of(context).viewInsets.bottom;

    return GestureDetector(
      onTap: () => FocusScope.of(context).unfocus(),
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: EdgeInsets.only(bottom: viewInsets),
        child: Container(
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
          child: SafeArea(
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
                        color: AdminColors.divider,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text(widget.isEdit ? 'Edit Pack' : 'Add New Pack',
                      style: GoogleFonts.inter(
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                          color: AdminColors.textPrimary)),
                  const SizedBox(height: 24),
                  _label('Pack Label'),
                  const SizedBox(height: 8),
                  _field(_labelCtrl, 'e.g. Starter',
                      error: _labelErr),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _label('Coins'),
                            const SizedBox(height: 8),
                            _field(_coinsCtrl, '100',
                                isNum: true, error: _coinsErr),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _label('Price (₹)'),
                            const SizedBox(height: 8),
                            _field(_priceCtrl, '99',
                                isNum: true, error: _priceErr),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('Mark as Popular',
                          style: GoogleFonts.inter(
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                              color: AdminColors.textPrimary)),
                      Switch.adaptive(
                        value: _isPopular,
                        activeTrackColor: AdminColors.success,
                        onChanged: (v) => setState(() => _isPopular = v),
                      ),
                    ],
                  ),
                  Text(
                    'Setting this pack as Popular will unmark the current one.',
                    style: GoogleFonts.inter(
                        fontSize: 11,
                        fontWeight: FontWeight.w400,
                        color: AdminColors.textLight),
                  ),
                  const SizedBox(height: 24),
                  Row(
                    children: [
                      if (widget.isEdit) ...[
                        Expanded(
                          child: _SheetBtn(
                            label: 'Delete',
                            bg: Colors.white,
                            fg: AdminColors.error,
                            border: AdminColors.error,
                            onTap: _delete,
                          ),
                        ),
                        const SizedBox(width: 12),
                      ],
                      Expanded(
                        child: _SheetBtn(
                          label: widget.isEdit ? 'Update Pack' : 'Add Pack',
                          bg: AdminColors.brandBrown,
                          fg: Colors.white,
                          onTap: _save,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _label(String text) => Text(text,
      style: GoogleFonts.inter(
          fontSize: 13,
          fontWeight: FontWeight.w500,
          color: AdminColors.textMuted));

  Widget _field(TextEditingController ctrl, String hint,
      {bool isNum = false, String? error}) {
    return TextField(
      controller: ctrl,
      keyboardType: isNum ? TextInputType.number : TextInputType.text,
      style: GoogleFonts.inter(
          fontSize: 14, color: AdminColors.textPrimary),
      decoration: InputDecoration(
        hintText: hint,
        errorText: error,
        filled: true,
        fillColor: AdminColors.inputBackground,
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide.none),
        focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide:
                const BorderSide(color: AdminColors.brandBrown, width: 1)),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        isDense: true,
      ),
    );
  }
}

class _SheetBtn extends StatefulWidget {
  final String label;
  final Color bg, fg;
  final Color? border;
  final VoidCallback onTap;

  const _SheetBtn({
    required this.label,
    required this.bg,
    required this.fg,
    this.border,
    required this.onTap,
  });

  @override
  State<_SheetBtn> createState() => _SheetBtnState();
}

class _SheetBtnState extends State<_SheetBtn> {
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
          height: 48,
          decoration: BoxDecoration(
            color: widget.bg,
            borderRadius: BorderRadius.circular(12),
            border: widget.border != null
                ? Border.all(color: widget.border!, width: 1.5)
                : null,
          ),
          alignment: Alignment.center,
          child: Text(widget.label,
              style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: widget.fg)),
        ),
      ),
    );
  }
}
