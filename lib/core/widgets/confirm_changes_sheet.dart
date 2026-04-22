// Reusable confirmation bottom sheet — shows changed fields before saving

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:gospel_vox/core/theme/admin_colors.dart';

class ChangeItem {
  final String field;
  final String oldValue;
  final String newValue;

  const ChangeItem({
    required this.field,
    required this.oldValue,
    required this.newValue,
  });
}

class ConfirmChangesSheet {
  static Future<bool> show({
    required BuildContext context,
    required String title,
    required List<ChangeItem> changes,
    String confirmLabel = 'Confirm Changes',
    String cancelLabel = 'Cancel',
    bool isDangerous = false,
  }) async {
    final result = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: Colors.white,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => _Sheet(
        title: title,
        changes: changes,
        confirmLabel: confirmLabel,
        cancelLabel: cancelLabel,
        isDangerous: isDangerous,
      ),
    );
    return result ?? false;
  }
}

class _Sheet extends StatelessWidget {
  final String title;
  final List<ChangeItem> changes;
  final String confirmLabel;
  final String cancelLabel;
  final bool isDangerous;

  const _Sheet({
    required this.title,
    required this.changes,
    required this.confirmLabel,
    required this.cancelLabel,
    required this.isDangerous,
  });

  @override
  Widget build(BuildContext context) {
    final accent = isDangerous ? AdminColors.error : AdminColors.brandBrown;
    final valueColor = isDangerous ? AdminColors.error : AdminColors.success;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
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
            Row(
              children: [
                Icon(
                  isDangerous
                      ? Icons.warning_amber_rounded
                      : Icons.checklist_rounded,
                  size: 24,
                  color: accent,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(title,
                      style: GoogleFonts.inter(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                          color: AdminColors.textPrimary)),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text('Review the changes below before confirming.',
                style: GoogleFonts.inter(
                    fontSize: 13,
                    fontWeight: FontWeight.w400,
                    color: AdminColors.textMuted)),
            const SizedBox(height: 20),
            Container(
              decoration: BoxDecoration(
                color: AdminColors.background,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                children: [
                  for (int i = 0; i < changes.length; i++)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 12),
                      decoration: i < changes.length - 1
                          ? const BoxDecoration(
                              border: Border(
                                  bottom: BorderSide(
                                      color: AdminColors.borderLight,
                                      width: 1)))
                          : null,
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(changes[i].field,
                                style: GoogleFonts.inter(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w500,
                                    color: AdminColors.textPrimary)),
                          ),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Text(changes[i].oldValue,
                                  style: GoogleFonts.inter(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w400,
                                      color: AdminColors.textLight,
                                      decoration:
                                          TextDecoration.lineThrough)),
                              const SizedBox(height: 2),
                              Text(changes[i].newValue,
                                  style: GoogleFonts.inter(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                      color: valueColor)),
                            ],
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Center(
              child: Text(
                  '${changes.length} change${changes.length > 1 ? 's' : ''} detected',
                  style: GoogleFonts.inter(
                      fontSize: 11,
                      fontWeight: FontWeight.w400,
                      color: AdminColors.textLight)),
            ),
            const SizedBox(height: 24),
            Row(
              children: [
                Expanded(child: _SheetBtn(
                  label: cancelLabel,
                  bg: Colors.white,
                  fg: AdminColors.textMuted,
                  border: AdminColors.divider,
                  onTap: () => Navigator.pop(context, false),
                )),
                const SizedBox(width: 12),
                Expanded(child: _SheetBtn(
                  label: confirmLabel,
                  bg: accent,
                  fg: Colors.white,
                  onTap: () => Navigator.pop(context, true),
                )),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SheetBtn extends StatefulWidget {
  final String label;
  final Color bg;
  final Color fg;
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
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _pressed ? 0.97 : 1.0,
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
