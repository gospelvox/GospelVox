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

  static const _fields = [
    'chatRatePerMinute',
    'voiceRatePerMinute',
    'commissionPercent',
    'bibleSessionCommissionPercent',
    'priestActivationFee',
    'matrimonyListingFee',
    'matrimonyUnlockFee',
    'matrimonyChatTierFee',
    'lowBalanceWarning',
    'minWithdrawal',
    'welcomeOfferPrice',
    'welcomeOfferCoins',
  ];

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
      'bibleSessionCommissionPercent': ('Bible Session Commission', '%'),
      'priestActivationFee': ('Speaker Activation', '₹'),
      'matrimonyListingFee': ('Matrimony Listing', '₹'),
      'matrimonyUnlockFee': ('Matrimony Unlock', '₹'),
      'matrimonyChatTierFee': ('Chat Extension', '₹'),
      'lowBalanceWarning': ('Low Balance Alert', 'coins'),
      'minWithdrawal': ('Min Withdrawal', '₹'),
      'welcomeOfferPrice': ('User Pays', '₹'),
      'welcomeOfferCoins': ('Coins Given', 'coins'),
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
                    'bibleSessionCommissionPercent', '%'),
              ]),
              _section('FEES', [
                _row('Speaker Activation', 'One-time unlock fee',
                    'priestActivationFee', '₹'),
                _row('Matrimony Listing', 'Profile publish fee',
                    'matrimonyListingFee', '₹'),
                _row('Matrimony Unlock', 'Unlock + 50 messages',
                    'matrimonyUnlockFee', '₹'),
                _row('Chat Extension', '200 more messages',
                    'matrimonyChatTierFee', '₹'),
              ]),
              _section('THRESHOLDS', [
                _row('Min Withdrawal', 'Speaker minimum payout',
                    'minWithdrawal', '₹'),
                _row('Low Balance Alert', 'Warn during session',
                    'lowBalanceWarning', 'coins'),
              ]),
              _section('FIRST-TIME OFFER', [
                _row('User Pays', 'Amount charged',
                    'welcomeOfferPrice', '₹'),
                _row('Coins Given', 'Coins credited',
                    'welcomeOfferCoins', 'coins'),
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
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                      color: Colors.white, strokeWidth: 2))
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
            for (final count in [3, 1, 4, 2, 2]) ...[
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
