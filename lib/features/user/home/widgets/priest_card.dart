// Reusable priest card used by the Home feed and the "All speakers"
// page.
//
// Card anatomy (top → bottom):
//
//   • Photo area      – fills the card width with BoxFit.cover; the
//                       online pill overlays the photo's top-left
//                       corner when `priest.isOnline`.
//   • Name            – w700, single line, ellipsis.
//   • Rating · years  – inline plain text with a small star glyph,
//                       no pill background.
//   • Specializations – inline plain text (1-2 specialisations joined
//                       by " · "), no pill background.
//   • Action row      – Call (filled) + Chat (outlined) side-by-side
//                       when `priest.isAvailable`; a single full-
//                       width "Notify me" button when offline.
//
// The info-area text intentionally avoids container chrome — pill
// backgrounds on small text in a narrow card read as visual noise.
//
// Three callbacks drive the action row:
//   • `onCall`   → start a voice session (Call button)
//   • `onChat`   → start a chat session (Chat button)
//   • `onNotify` → subscribe to a "back online" push
//   • `onTap`    → tap anywhere else on the card → priest profile
//
// All four are required because both surfaces that mount this card
// (Home feed, /user/speakers) wire the same SessionPreflight +
// Firestore writes — making any of them optional would invite a
// silent no-op CTA on one surface.

import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:gospel_vox/core/theme/app_colors.dart';
import 'package:gospel_vox/core/widgets/app_icons.dart';
import 'package:gospel_vox/core/widgets/pulsing_dot.dart';
import 'package:gospel_vox/features/admin/speakers/data/speaker_model.dart';

// Card-local design tokens. `onlineGreen` is aliased to AppColors.sageOnline
// so this card shares one canonical "online" colour with the filter chip,
// trust card, and explore banner instead of drifting in saturation.
class _C {
  static const onlineGreen = AppColors.sageOnline;
  static const busyAmber = Color(0xFFD4A060);
  static const muted = Color(0xFF9B7B6E);
  static const darkBrown = Color(0xFF140800);
}

// Default gradient stack used when callers don't supply their own.
// Index into this with `index % length` so each card's gradient stays
// stable across rebuilds. The choice is keyed off card index, not
// priest identity, so adjacent cards never share the same colour.
const List<List<Color>> kPriestGradients = <List<Color>>[
  [Color(0xFF8B6B5A), Color(0xFFC8A882)],
  [Color(0xFF6B7B8B), Color(0xFF9BAAB8)],
  [Color(0xFF8B7B9B), Color(0xFFB8A8C8)],
  [Color(0xFF7B8B6B), Color(0xFFA8B898)],
  [Color(0xFF9B7B6B), Color(0xFFC8B8A8)],
  [Color(0xFF6B8B7B), Color(0xFF98B8A8)],
];

class PriestCard extends StatefulWidget {
  final SpeakerModel priest;
  final List<Color> gradient;
  final VoidCallback onTap;
  final VoidCallback onCall;
  final VoidCallback onChat;
  final VoidCallback onNotify;

  const PriestCard({
    super.key,
    required this.priest,
    required this.gradient,
    required this.onTap,
    required this.onCall,
    required this.onChat,
    required this.onNotify,
  });

  @override
  State<PriestCard> createState() => _PriestCardState();
}

class _PriestCardState extends State<PriestCard> {
  bool _pressed = false;
  // Delayed-press timer. Lets us hold off on showing the card-level
  // press visual until the gesture arena decides whether the user is
  // actually pressing the card or just on their way to tapping a
  // child action button (Call / Chat / Notify).
  Timer? _pressTimer;

  @override
  void dispose() {
    _pressTimer?.cancel();
    super.dispose();
  }

  void _scheduleCardPress() {
    // 60 ms delay — a fast tap on a child button (typical hold time
    // 80-150 ms) resolves through the gesture arena and fires
    // onTapCancel BEFORE this timer fires, so the card never visibly
    // presses. Deliberate card taps land later, where the press
    // appears within ~60 ms of touch-down — still perceived as
    // instant (<100 ms is the threshold for "immediate" feel).
    _pressTimer?.cancel();
    _pressTimer = Timer(const Duration(milliseconds: 60), () {
      if (!mounted) return;
      setState(() => _pressed = true);
    });
  }

  void _releaseCardPress() {
    _pressTimer?.cancel();
    _pressTimer = null;
    if (_pressed) {
      setState(() => _pressed = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // GestureDetector (not Listener) wires the press feedback into
    // Flutter's gesture arena. When the user taps a child action
    // button, the button's own GestureDetector wins the arena and
    // our `onTapCancel` fires before the 60 ms timer can flip the
    // card press visual — so tapping Call/Chat shows ONLY the button
    // press, never the whole-card scale.
    //
    // Tapping anywhere else on the card (photo, name area) still
    // routes through `widget.onTap` and shows the card press the way
    // it did before.
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => _scheduleCardPress(),
      onTapUp: (_) => _releaseCardPress(),
      onTapCancel: _releaseCardPress,
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _pressed ? 0.97 : 1.0,
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOut,
        child: AnimatedOpacity(
          opacity: _pressed ? 0.85 : 1.0,
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
          child: Container(
            decoration: BoxDecoration(
              color: AppColors.surfaceWhite,
              // Locked at the 20-radius "card" tier of AppRadius.
              borderRadius: BorderRadius.circular(AppRadius.large),
              // Two-layer warm-tinted shadow — replaces the flat cool
              // black drop so the card sits in the parchment palette.
              boxShadow: kWarmCardShadow,
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: _buildImage()),
                _buildInfo(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildImage() {
    final priest = widget.priest;
    return Stack(
      fit: StackFit.expand,
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: widget.gradient,
            ),
          ),
        ),
        if (priest.hasPhoto)
          Positioned.fill(
            child: CachedNetworkImage(
              imageUrl: priest.photoUrl,
              fit: BoxFit.cover,
              placeholder: (_, _) => const SizedBox.shrink(),
              errorWidget: (_, _, _) => _BigInitial(priest: priest),
            ),
          )
        else
          _BigInitial(priest: priest),
        // 1px inner border at ~3% black — defines the image edges
        // subtly so light-toned photos don't bleed into the card's
        // info area below. IgnorePointer + Positioned.fill keeps it
        // visually layered without intercepting tap hit-testing.
        const Positioned.fill(
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                border: Border(
                  top: BorderSide(color: Color(0x08000000), width: 1),
                  left: BorderSide(color: Color(0x08000000), width: 1),
                  right: BorderSide(color: Color(0x08000000), width: 1),
                  bottom: BorderSide(color: Color(0x08000000), width: 1),
                ),
              ),
            ),
          ),
        ),
        if (priest.isOnline)
          Positioned(
            top: 10,
            left: 10,
            child: _StatusBadge(priest: priest),
          ),
      ],
    );
  }

  Widget _buildInfo() {
    final priest = widget.priest;
    final specs = _specsLine(priest);
    final hasRatingOrYears =
        priest.rating > 0 || priest.yearsOfExperience > 0;

    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            priest.fullName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: GoogleFonts.inter(
              fontSize: 13.5,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.2,
              color: AppColors.deepDarkBrown,
            ),
          ),
          if (hasRatingOrYears) ...[
            const SizedBox(height: 3),
            _RatingYearsRow(
              rating: priest.rating,
              years: priest.yearsOfExperience,
            ),
          ],
          if (specs != null) ...[
            const SizedBox(height: 2),
            Text(
              specs,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.inter(
                fontSize: 10.5,
                fontWeight: FontWeight.w400,
                color: AppColors.muted,
              ),
            ),
          ],
          const SizedBox(height: 8),
          _buildActions(),
        ],
      ),
    );
  }

  Widget _buildActions() {
    if (widget.priest.isAvailable) {
      return Row(
        children: [
          Expanded(
            child: _ActionButton(
              icon: AppIcons.phone,
              label: 'Call',
              filled: true,
              onTap: widget.onCall,
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: _ActionButton(
              icon: AppIcons.chatOutline,
              label: 'Chat',
              filled: false,
              onTap: widget.onChat,
            ),
          ),
        ],
      );
    }
    // Offline → single full-width "Notify me" CTA.
    return _ActionButton(
      icon: AppIcons.bell,
      label: 'Notify me',
      filled: false,
      muted: true,
      onTap: widget.onNotify,
    );
  }

  // Specialisations as plain text, two at most so the line never
  // becomes a dump. Falls back to the priest's denomination so the
  // card still has a sub-line of identity when specialisations are
  // missing. Returns null when nothing is available — the caller
  // simply omits the line in that case.
  String? _specsLine(SpeakerModel priest) {
    if (priest.specializations.isNotEmpty) {
      return priest.specializations.take(2).join(' · ');
    }
    if (priest.denomination.isNotEmpty) return priest.denomination;
    return null;
  }
}

// Plain-text rating + years line. Star icon, single-decimal rating,
// middle-dot separator, "X+ years". Each segment is conditional so a
// priest with rating but no years (or vice versa) still gets a clean
// line without orphan separators.
class _RatingYearsRow extends StatelessWidget {
  final double rating;
  final int years;

  const _RatingYearsRow({required this.rating, required this.years});

  @override
  Widget build(BuildContext context) {
    final hasRating = rating > 0;
    final hasYears = years > 0;
    final ratingText = rating.toStringAsFixed(1);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (hasRating) ...[
          const AppIcon(
            AppIcons.starFilled,
            size: 13,
            color: AppColors.amberGold,
          ),
          const SizedBox(width: 3),
          Text(
            ratingText,
            style: GoogleFonts.inter(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: AppColors.deepDarkBrown,
              // Tabular figures so "3.7" and "4.0" land on the same
              // baseline width — no horizontal jitter as ratings update.
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
        if (hasRating && hasYears) ...[
          const SizedBox(width: 6),
          Text(
            '·',
            style: GoogleFonts.inter(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: AppColors.muted,
            ),
          ),
          const SizedBox(width: 6),
        ],
        if (hasYears)
          Flexible(
            child: Text(
              '$years+ years',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.inter(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: AppColors.muted,
                // Years numeric also tabular for the same reason.
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
      ],
    );
  }
}

// Compact action button used inside PriestCard. Three visual flavours:
//   • filled:true   → dark brown fill, white icon + label (Call)
//   • filled:false  → transparent fill, dark border, dark icon + label (Chat)
//   • muted:true    → soft fill, no border, faded text (Notify me)
class _ActionButton extends StatefulWidget {
  final IconData icon;
  final String label;
  final bool filled;
  final bool muted;
  final VoidCallback onTap;

  const _ActionButton({
    required this.icon,
    required this.label,
    required this.filled,
    required this.onTap,
    this.muted = false,
  });

  @override
  State<_ActionButton> createState() => _ActionButtonState();
}

class _ActionButtonState extends State<_ActionButton> {
  bool _pressed = false;

  void _setPressed(bool v) {
    if (_pressed == v) return;
    setState(() => _pressed = v);
  }

  @override
  Widget build(BuildContext context) {
    final Color bg;
    final Color fg;
    final BoxBorder? border;

    if (widget.muted) {
      bg = AppColors.surfaceSecondary;
      fg = AppColors.deepDarkBrown.withValues(alpha: 0.75);
      border = null;
    } else if (widget.filled) {
      // Call — primary affordance, stays as a solid dark fill.
      bg = AppColors.deepDarkBrown;
      fg = Colors.white;
      border = null;
    } else {
      // Chat — softer than the prior hard-outlined treatment. A
      // 6%-brown tinted fill with no border keeps the affordance
      // present and tappable while leaving the filled Call button as
      // the visual lead. Keeps the dual-CTA hierarchy without
      // demoting chat to icon-only.
      bg = AppColors.deepDarkBrown.withValues(alpha: 0.06);
      fg = AppColors.deepDarkBrown;
      border = null;
    }

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
          child: AnimatedOpacity(
            opacity: _pressed ? 0.85 : 1.0,
            duration: const Duration(milliseconds: 150),
            curve: Curves.easeOut,
            child: Container(
              height: 30,
              decoration: BoxDecoration(
                color: bg,
                // Buttons lock to the 12-radius "small" tier.
                borderRadius: BorderRadius.circular(AppRadius.small),
                border: border,
              ),
              alignment: Alignment.center,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  AppIcon(widget.icon, size: 13, color: fg),
                  const SizedBox(width: 5),
                  Text(
                    widget.label,
                    style: GoogleFonts.inter(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: fg,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _BigInitial extends StatelessWidget {
  final SpeakerModel priest;
  const _BigInitial({required this.priest});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        priest.initial,
        style: GoogleFonts.inter(
          fontSize: 56,
          // Pulled back from w800 → w700 so the priest card stays
          // inside the locked weight palette (400 / 600 / 700). The
          // 56 px size already carries the visual weight; w800 was
          // adding extra heaviness without legibility gain.
          fontWeight: FontWeight.w700,
          color: Colors.white.withValues(alpha: 0.9),
        ),
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  final SpeakerModel priest;
  const _StatusBadge({required this.priest});

  @override
  Widget build(BuildContext context) {
    final (label, dotColor, textColor, animated) = _spec(priest);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.surfaceCream.withValues(alpha: 0.94),
        borderRadius: BorderRadius.circular(20),
        // Warm tinted shadow keeps the badge sitting on top of the
        // photo without the cool grey "sticker" feel of a flat black
        // drop.
        boxShadow: [
          BoxShadow(
            color: AppColors.shadowWarm.withValues(alpha: 0.10),
            blurRadius: 6,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Online → pulsing dot (subtle 1.5s breathing loop)
          //   so the "available now" signal stays alive on screen.
          //   PulsingDot wraps a single ticker per instance — at most
          //   2 instances on home (one per visible online priest), so
          //   the frame cost is negligible.
          // Busy / Offline → static dot (no animation — these are
          //   passive states; animating them would create noise).
          //
          // Bumped from 6 → 9 px so the dot is actually readable from
          // arm's length and the pulse halo (rendered at size × 1.6
          // by PulsingDot) reads as a clear breathing animation
          // rather than a sub-pixel shimmer. Still proportional to
          // the badge's compact 10 px text.
          if (animated)
            PulsingDot(size: 7, color: dotColor)
          else
            Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: dotColor,
              ),
            ),
          const SizedBox(width: 3),
          Text(
            label,
            style: GoogleFonts.inter(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: textColor,
            ),
          ),
        ],
      ),
    );
  }

  // 4-tuple now — the trailing bool says whether the dot should pulse.
  // Only the "Online & not busy" state animates.
  (String, Color, Color, bool) _spec(SpeakerModel p) {
    if (p.isAvailable) {
      return ('Online', _C.onlineGreen, _C.darkBrown, true);
    }
    if (p.isOnline && p.isBusy) {
      return ('Busy', _C.busyAmber, _C.darkBrown, false);
    }
    return ('Offline', _C.muted, _C.muted, false);
  }
}
