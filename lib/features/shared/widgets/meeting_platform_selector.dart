// A small segmented pill selector for choosing the meeting platform
// (Google Meet / Zoom / …). Iterates [MeetingPlatform.all], so adding
// a platform there automatically adds a pill here — no edits needed.
//
// Used by both the priest create form and the add-link sheet.

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:gospel_vox/core/theme/app_colors.dart';
import 'package:gospel_vox/features/shared/data/meeting_platform.dart';

class MeetingPlatformSelector extends StatelessWidget {
  final MeetingPlatform selected;
  final ValueChanged<MeetingPlatform> onChanged;
  const MeetingPlatformSelector({
    super.key,
    required this.selected,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (var i = 0; i < MeetingPlatform.all.length; i++) ...[
          if (i > 0) const SizedBox(width: 10),
          Expanded(child: _pill(MeetingPlatform.all[i])),
        ],
      ],
    );
  }

  Widget _pill(MeetingPlatform p) {
    final isSel = p.id == selected.id;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => onChanged(p),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(vertical: 11),
        decoration: BoxDecoration(
          color: isSel
              ? AppColors.primaryBrown.withValues(alpha: 0.10)
              : AppColors.warmBeige.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSel
                ? AppColors.primaryBrown
                : AppColors.muted.withValues(alpha: 0.15),
            width: isSel ? 1.5 : 1,
          ),
        ),
        child: Center(
          child: Text(
            p.label,
            style: GoogleFonts.inter(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: isSel ? AppColors.primaryBrown : AppColors.muted,
            ),
          ),
        ),
      ),
    );
  }
}
