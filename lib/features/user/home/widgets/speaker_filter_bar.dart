// Single source of truth for the speaker filter chips.
//
// Both the Home feed (the 2-card teaser grid) and the "All speakers"
// page behind the "See all" link filter the same priest catalogue by
// the same chips. Before this file existed, the chip list and the
// filter logic lived privately inside home_page.dart, so the "See all"
// destination showed the *unfiltered* list — a user who picked "Online"
// on Home then tapped "See all" was dropped into the full catalogue
// with their choice silently discarded.
//
// Keeping the chip definitions (`kSpeakerFilterChips`) AND the filter
// predicate (`filterSpeakersByChip`) here means the two screens can
// never disagree about which chips exist or what "Online" means.

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:gospel_vox/core/constants/community_roles.dart';
import 'package:gospel_vox/core/theme/app_colors.dart';
import 'package:gospel_vox/core/widgets/app_icons.dart';
import 'package:gospel_vox/features/admin/speakers/data/speaker_model.dart';

// A record keeps the icon + semantic colour bound to the label inline
// so we can't drift label/icon indices apart by editing one list and
// forgetting the other. `iconColor` is reserved for cases (Online →
// green) where the icon carries its own semantic colour; null = inherit
// from the chip's foreground.
typedef SpeakerFilterDef = ({
  String label,
  IconData? icon,
  Color? iconColor,
});

// Muted sage — the canonical "online / active" tint, aliased to
// AppColors.sageOnline so every screen shares one online colour.
const Color kSpeakerOnlineGreen = AppColors.sageOnline;

// The canonical filter-chip set:
//
//   • 'All'    — the no-op default.
//   • 'Online' — availability status, not a role.
//   • the rest — every Christian community role from kCommunityRoles
//                (the same verbatim list a priest picks at registration),
//                minus the 'Other' free-text sentinel which isn't a real,
//                filterable value.
//
// Deriving the role chips straight from kCommunityRoles means the home
// filter can never drift from the registration role list — add a role
// there and it appears here automatically. Non-const because the
// collection-`for` builds it from the imported list at startup.
final List<SpeakerFilterDef> kSpeakerFilterChips = <SpeakerFilterDef>[
  (label: 'All', icon: null, iconColor: null),
  (label: 'Online', icon: AppIcons.wifi, iconColor: kSpeakerOnlineGreen),
  for (final role in kCommunityRoles)
    if (role != kCommunityRoleOther)
      (label: role, icon: null, iconColor: null),
];

// True when `filter` names a real, non-default chip. Used by the
// "All speakers" page to decide whether a filter passed in via the
// route query param should pre-select a chip.
bool isKnownSpeakerFilter(String filter) {
  return kSpeakerFilterChips.any((c) => c.label == filter);
}

// The one and only chip-filter predicate. `base` is the search-filtered
// list the cubit already produced; this layers the chip on top.
//
//   • 'All'    → pass through unchanged.
//   • 'Online' → only priests currently available.
//   • a role   → priests whose stored `communityRole` matches the chip
//                exactly (case-insensitive, trimmed). Exact-match keeps
//                results honest — tapping "Evangelist" shows evangelists,
//                never a pastor who merely mentions evangelism in a bio.
//                A priest who typed a custom 'Other' role simply won't
//                appear under any predefined chip, which is correct.
//
// Legacy fallback: priests who registered before communityRole became
// mandatory have an empty role. Rather than hide them from every chip
// until they edit their profile, those (and only those) are matched
// forgivingly against their denomination / specializations. Priests who
// HAVE a role are always matched exactly, so the fallback can never
// pollute a populated role's results.
List<SpeakerModel> filterSpeakersByChip(
  List<SpeakerModel> base,
  String filter,
) {
  if (filter == 'All') return base;
  if (filter == 'Online') {
    return base.where((p) => p.isAvailable).toList();
  }
  final q = filter.trim().toLowerCase();
  return base.where((p) {
    final role = p.communityRole.trim().toLowerCase();
    if (role.isNotEmpty) return role == q;
    return p.denomination.toLowerCase().contains(q) ||
        p.specializations.any((s) => s.toLowerCase().contains(q));
  }).toList();
}

// Horizontal, single-line strip of filter chips. Stateless — the parent
// owns `active` and reacts to `onSelected`. Visual styling matches the
// Home feed's chip row exactly so the "See all" destination reads as a
// continuation of the same surface, not a different screen.
class SpeakerFilterBar extends StatelessWidget {
  final String active;
  final ValueChanged<String> onSelected;
  final EdgeInsetsGeometry padding;

  const SpeakerFilterBar({
    super.key,
    required this.active,
    required this.onSelected,
    this.padding = const EdgeInsets.symmetric(horizontal: 20),
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 38,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        padding: padding,
        itemCount: kSpeakerFilterChips.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (_, i) {
          final def = kSpeakerFilterChips[i];
          return SpeakerFilterChip(
            label: def.label,
            icon: def.icon,
            iconColor: def.iconColor,
            isActive: active == def.label,
            onTap: () => onSelected(def.label),
          );
        },
      ),
    );
  }
}

// A single filter chip. Carries its own lightweight press-scale so it
// doesn't depend on home_page's private `_PressScale`.
class SpeakerFilterChip extends StatefulWidget {
  final String label;
  final IconData? icon;
  final Color? iconColor;
  final bool isActive;
  final VoidCallback onTap;

  const SpeakerFilterChip({
    super.key,
    required this.label,
    required this.icon,
    required this.iconColor,
    required this.isActive,
    required this.onTap,
  });

  @override
  State<SpeakerFilterChip> createState() => _SpeakerFilterChipState();
}

class _SpeakerFilterChipState extends State<SpeakerFilterChip> {
  bool _pressed = false;

  void _setPressed(bool v) {
    if (_pressed == v) return;
    setState(() => _pressed = v);
  }

  @override
  Widget build(BuildContext context) {
    final isActive = widget.isActive;
    final fg = isActive ? Colors.white : AppColors.deepDarkBrown;
    // On the active chip the icon reads as part of the chip, not its
    // own semantic accent — so the colour collapses to plain white.
    final resolvedIconColor =
        isActive ? Colors.white : (widget.iconColor ?? fg);

    return Listener(
      onPointerDown: (_) => _setPressed(true),
      onPointerUp: (_) => _setPressed(false),
      onPointerCancel: (_) => _setPressed(false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _pressed ? 0.95 : 1.0,
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            height: 32,
            padding: EdgeInsets.symmetric(
              horizontal: widget.icon == null ? 16 : 12,
            ),
            decoration: BoxDecoration(
              gradient: isActive
                  ? const LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      stops: [0.0, 0.5],
                      colors: [
                        Color(0xFF4A2D1C),
                        AppColors.deepDarkBrown,
                      ],
                    )
                  : null,
              color: isActive ? null : AppColors.surfaceWhite,
              borderRadius: BorderRadius.circular(16),
              border: isActive
                  ? null
                  : Border.all(color: AppColors.borderLight, width: 0.5),
              boxShadow: isActive
                  ? [
                      BoxShadow(
                        color: AppColors.deepDarkBrown.withValues(alpha: 0.18),
                        blurRadius: 10,
                        offset: const Offset(0, 3),
                      ),
                    ]
                  : null,
            ),
            alignment: Alignment.center,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (widget.icon != null) ...[
                  AppIcon(widget.icon, size: 15, color: resolvedIconColor),
                  const SizedBox(width: 6),
                ],
                Text(
                  widget.label,
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: fg,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
