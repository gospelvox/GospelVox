// Configuration tab — editable admin settings with change tracking

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shimmer/shimmer.dart';

import 'package:gospel_vox/core/theme/admin_colors.dart';
import 'package:gospel_vox/core/widgets/app_snackbar.dart';
import 'package:gospel_vox/core/widgets/confirm_changes_sheet.dart';
import 'package:gospel_vox/features/admin/settings/bloc/settings_cubit.dart';
import 'package:gospel_vox/features/admin/settings/bloc/settings_state.dart';
import 'package:gospel_vox/core/widgets/app_loading_widget.dart';

class ConfigurationTab extends StatefulWidget {
  const ConfigurationTab({super.key});

  @override
  State<ConfigurationTab> createState() => _ConfigurationTabState();
}

class _ConfigurationTabState extends State<ConfigurationTab>
    with AutomaticKeepAliveClientMixin {
  final Map<String, int> _original = {};
  final Map<String, TextEditingController> _ctrls = {};
  bool _hasChanges = false;

  // Only fields the app actually reads post-Play-Billing. Removed (dead
  // after the migration, read nowhere at runtime): matrimony*Fee ×3
  // (matrimony is Coming Soon), lowBalanceWarning (warning is a hardcoded
  // 5-min threshold), welcomeOffer* ×2 (offer disabled at cutover). Their
  // Firestore values are left untouched — only hidden from this UI — so
  // re-enabling those features later just means re-adding their rows.
  static const _fields = [
    'chatRatePerMinute',
    'voiceRatePerMinute',
    'commissionPercent',
    'bibleCommissionPercent',
    'priestActivationFee',
    'minWithdrawal',
  ];

  // Per-field validation bounds, enforced on save. `min` is the lowest
  // ALLOWED value. Rates/thresholds must be ≥1 (a 0 rate would mean free
  // sessions / a 0 floor); commission % is 0–100 (0 = priest keeps all).
  // priestActivationFee is intentionally absent — it's display-only (the
  // real charge is the Play SKU) and is shown read-only, so there's
  // nothing for the admin to mis-enter.
  static const _bounds = <String, ({int min, int max, String label})>{
    'chatRatePerMinute': (min: 1, max: 100000, label: 'Chat Rate'),
    'voiceRatePerMinute': (min: 1, max: 100000, label: 'Voice Rate'),
    'commissionPercent': (min: 0, max: 100, label: 'Commission'),
    'bibleCommissionPercent':
        (min: 0, max: 100, label: 'Bible Commission'),
    'minWithdrawal': (min: 1, max: 10000000, label: 'Min Withdrawal'),
  };

  // Returns the first validation error (for an AppSnackBar) or null when
  // every field is within bounds. Blocks blank, non-numeric, 0-where-not-
  // allowed, and out-of-range values from ever reaching app_config.
  String? _validate() {
    for (final entry in _bounds.entries) {
      final b = entry.value;
      final text = _ctrls[entry.key]?.text.trim() ?? '';
      final val = int.tryParse(text);
      if (val == null) {
        return '${b.label} must be a whole number.';
      }
      if (val < b.min) {
        return b.min == 0
            ? "${b.label} can't be negative."
            : '${b.label} must be at least ${b.min}.';
      }
      if (val > b.max) {
        return "${b.label} can't be more than ${b.max}.";
      }
    }
    return null;
  }

  @override
  bool get wantKeepAlive => true;

  @override
  void dispose() {
    for (final c in _ctrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _populateFrom(Map<String, dynamic> data) {
    for (final key in _fields) {
      final val = (data[key] as num?)?.toInt() ?? 0;
      _original[key] = val;
      _ctrls.putIfAbsent(key, () => TextEditingController());
      _ctrls[key]!.text = val.toString();
    }
    _hasChanges = false;
  }

  void _checkChanges() {
    bool changed = false;
    for (final key in _fields) {
      final cur = int.tryParse(_ctrls[key]?.text ?? '') ?? 0;
      if (cur != (_original[key] ?? 0)) {
        changed = true;
        break;
      }
    }
    if (changed != _hasChanges) setState(() => _hasChanges = changed);
  }

  List<ChangeItem> _getChangedItems() {
    final items = <ChangeItem>[];
    final labels = {
      'chatRatePerMinute': ('Chat Rate', 'coins/min'),
      'voiceRatePerMinute': ('Voice Rate', 'coins/min'),
      'commissionPercent': ('Commission', '%'),
      'bibleCommissionPercent': ('Bible Session Commission', '%'),
      'priestActivationFee': ('Speaker Activation', '₹'),
      'minWithdrawal': ('Min Withdrawal', '₹'),
    };

    for (final key in _fields) {
      final oldVal = _original[key] ?? 0;
      final newVal = int.tryParse(_ctrls[key]?.text ?? '') ?? 0;
      if (oldVal != newVal) {
        final info = labels[key] ?? (key, '');
        items.add(ChangeItem(
          field: info.$1,
          oldValue: '$oldVal ${info.$2}',
          newValue: '$newVal ${info.$2}',
        ));
      }
    }
    return items;
  }

  Future<void> _save() async {
    // Validate BEFORE the confirm sheet — the old code did
    // `int.tryParse(text) ?? 0`, which silently wrote 0 for a blank or
    // bad value. Now a bad value is caught and surfaced instead.
    final validationError = _validate();
    if (validationError != null) {
      if (mounted) AppSnackBar.error(context, validationError);
      return;
    }

    final changes = _getChangedItems();
    if (changes.isEmpty) {
      if (mounted) AppSnackBar.info(context, 'No changes to save');
      return;
    }

    final confirmed = await ConfirmChangesSheet.show(
      context: context,
      title: 'Save Configuration',
      changes: changes,
    );

    if (!confirmed || !mounted) return;

    final data = <String, dynamic>{};
    for (final key in _fields) {
      data[key] = int.tryParse(_ctrls[key]?.text ?? '') ?? 0;
    }
    context.read<SettingsCubit>().saveSettings(data);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);

    return BlocConsumer<SettingsCubit, SettingsState>(
      listener: (context, state) {
        if (state is SettingsLoaded) {
          _populateFrom(state.data);
        } else if (state is SettingsSaved) {
          AppSnackBar.success(context, 'Settings saved successfully');
        } else if (state is SettingsError) {
          AppSnackBar.error(context, state.message);
        }
      },
      builder: (context, state) {
        if (state is SettingsLoading || state is SettingsInitial) {
          return const _ConfigShimmer();
        }

        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _section('SESSION RATES', [
                _row('Chat Rate', 'Coins deducted per minute',
                    'chatRatePerMinute', 'coins/min'),
                _row('Voice Rate', 'Coins deducted per minute',
                    'voiceRatePerMinute', 'coins/min'),
                _row('Commission', 'Platform cut from sessions',
                    'commissionPercent', '%'),
              ]),
              _section('BIBLE SESSIONS', [
                _row('Bible Commission',
                    'Platform cut from bookings',
                    'bibleCommissionPercent', '%'),
              ]),
              _section('FEES', [
                // Read-only: the real charge is the `priest_activation`
                // Play SKU. This Firestore value is only used to stamp the
                // audit record, so it's shown for reference (set in Play
                // Console) and not editable — prevents it drifting from
                // what Play actually charges.
                _readOnlyRow('Speaker Activation', 'priestActivationFee', '₹'),
              ]),
              _section('THRESHOLDS', [
                _row('Min Withdrawal', 'Speaker minimum payout',
                    'minWithdrawal', '₹'),
              ]),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                child: _hasChanges
                    ? Column(
                        key: const ValueKey('save'),
                        children: [
                          const SizedBox(height: 24),
                          _SaveButton(onTap: _save,
                              isSaving: state is SettingsSaving),
                          const SizedBox(height: 8),
                          Text(
                            'Changes apply to new sessions. Active sessions keep locked rates.',
                            textAlign: TextAlign.center,
                            style: GoogleFonts.inter(
                                fontSize: 11,
                                fontWeight: FontWeight.w400,
                                color: AdminColors.textLight),
                          ),
                        ],
                      )
                    : const SizedBox.shrink(key: ValueKey('empty')),
              ),
              const SizedBox(height: 40),
            ],
          ),
        );
      },
    );
  }

  Widget _section(String label, List<Widget> rows) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 20),
        Text(label,
            style: GoogleFonts.inter(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: AdminColors.textLight,
                letterSpacing: 0.8)),
        const SizedBox(height: 12),
        Container(
          decoration: AdminColors.cardDecoration,
          child: Column(
            children: [
              for (int i = 0; i < rows.length; i++) ...[
                rows[i],
                if (i < rows.length - 1)
                  const Divider(
                      height: 1, color: AdminColors.borderLight),
              ],
            ],
          ),
        ),
      ],
    );
  }

  // Read-only display row for a Play-controlled value. Shows the current
  // Firestore value (for reference) but offers no input — the real price
  // lives in the Play Console, and editing it here would only corrupt the
  // audit record.
  Widget _readOnlyRow(String title, String key, String suffix) {
    final value = _original[key];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(title,
                        style: GoogleFonts.inter(
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                            color: AdminColors.textPrimary)),
                    const SizedBox(width: 6),
                    const Icon(Icons.lock_outline,
                        size: 12, color: AdminColors.textLight),
                  ],
                ),
                const SizedBox(height: 2),
                Text('Set in Play Console',
                    style: GoogleFonts.inter(
                        fontSize: 11,
                        fontWeight: FontWeight.w400,
                        color: AdminColors.textLight)),
              ],
            ),
          ),
          Text(value == null ? '—' : '$suffix$value',
              style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: AdminColors.textMuted)),
        ],
      ),
    );
  }

  Widget _row(String title, String sub, String key, String suffix) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: GoogleFonts.inter(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: AdminColors.textPrimary)),
                const SizedBox(height: 2),
                Text(sub,
                    style: GoogleFonts.inter(
                        fontSize: 11,
                        fontWeight: FontWeight.w400,
                        color: AdminColors.textLight)),
              ],
            ),
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 64,
                height: 36,
                child: TextField(
                  controller: _ctrls[key],
                  keyboardType: TextInputType.number,
                  textAlign: TextAlign.right,
                  style: GoogleFonts.inter(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: AdminColors.textPrimary),
                  decoration: InputDecoration(
                    filled: true,
                    fillColor: AdminColors.inputBackground,
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide.none),
                    focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: const BorderSide(
                            color: AdminColors.brandBrown, width: 1)),
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 8),
                    isDense: true,
                  ),
                  onChanged: (_) => _checkChanges(),
                ),
              ),
              const SizedBox(width: 6),
              Text(suffix,
                  style: GoogleFonts.inter(
                      fontSize: 12,
                      fontWeight: FontWeight.w400,
                      color: AdminColors.textMuted)),
            ],
          ),
        ],
      ),
    );
  }
}

class _SaveButton extends StatefulWidget {
  final VoidCallback onTap;
  final bool isSaving;
  const _SaveButton({required this.onTap, required this.isSaving});

  @override
  State<_SaveButton> createState() => _SaveButtonState();
}

class _SaveButtonState extends State<_SaveButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      onTap: widget.isSaving ? null : widget.onTap,
      child: AnimatedScale(
        scale: _pressed ? 0.97 : 1.0,
        duration: const Duration(milliseconds: 80),
        child: Container(
          width: double.infinity,
          height: 52,
          decoration: BoxDecoration(
            color: AdminColors.brandBrown,
            borderRadius: BorderRadius.circular(12),
          ),
          alignment: Alignment.center,
          child: widget.isSaving
              ? const SizedBox(
                  width: 32,
                  height: 32,
                  child: AppLoader())
              : Text('Save All Changes',
                  style: GoogleFonts.inter(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: Colors.white)),
        ),
      ),
    );
  }
}

class _ConfigShimmer extends StatelessWidget {
  const _ConfigShimmer();

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.all(20),
      child: Shimmer.fromColors(
        baseColor: const Color(0xFFE5E7EB),
        highlightColor: const Color(0xFFF3F4F6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final count in [3, 1, 1, 1]) ...[
              const SizedBox(height: 20),
              Container(width: 100, height: 12, color: Colors.white),
              const SizedBox(height: 12),
              Container(
                height: 52.0 * count + (count - 1),
                decoration: BoxDecoration(
                  color: Colors.white,
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
