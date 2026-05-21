// Color palette for the Gospel Vox design system

import 'package:flutter/material.dart';

class AppColors {
  static const Color primaryBrown = Color(0xFF6B3A2A);
  static const Color amberGold = Color(0xFFD4A060);
  static const Color warmBeige = Color(0xFFF4EDE3);
  static const Color muted = Color(0xFF9A8878);
  static const Color white = Color(0xFFFFFFFF);
  static const Color black = Color(0xFF1A1A1A);
  static const Color success = Color(0xFF4CAF50);
  static const Color error = Color(0xFFE53935);
  static const Color warning = Color(0xFFFFB300);

  // User side colors (warm beige palette)
  static const Color background = Color(0xFFF4EDE3);
  static const Color surfaceWhite = Color(0xFFFFFFFF);
  static const Color deepDarkBrown = Color(0xFF3D1F0F);
  static const Color errorRed = Color(0xFFC03828);

  // Home redesign tokens — warm parchment surface, hairline borders.
  static const Color backgroundPrimary = Color(0xFFEDE5D8);
  static const Color surfaceSecondary = Color(0xFFF0E8DF);
  static const Color borderLight = Color(0xFFE0D5C8);

  // Matrimony feature accent. Hot-pink → magenta pair that matches
  // the matrimony coming-soon hero icon, so the centre nav FAB reads
  // as the same colour as the love-heart inside the matrimony page.
  // Gradient direction: loveRoseLight (brighter, top-left) →
  // loveRose (deeper, bottom-right).
  static const Color loveRose = Color(0xFFD70466);
  static const Color loveRoseLight = Color(0xFFFF385C);

  // ─── Home-screen refinement tokens ─────────────────────────
  // Forest-emerald "online / available now" signal — used on the
  // speaker-card status badge, the filter chip's Online icon, and
  // the explore-banner availability dot. Lands between the cool
  // saturated system green that read as foreign on parchment and
  // the dull sage we tried first — vivid enough to actually look
  // alive on a cream card, desaturated enough to still belong to
  // the warm palette.
  //
  // Token name kept as `sageOnline` for downstream call-site
  // compatibility; the value is the canonical online colour. If
  // a future redesign drops the green entirely, change the value
  // here and every use-site (filter chip, status badge, etc.)
  // picks up the new colour without further edits.
  static const Color sageOnline = Color(0xFF3E8E5C);

  // Warm terra-cotta — the unified "urgency / unread" colour. Used by
  // the notification bell badge, missed-request banners, etc. Replaces
  // bright system reds (#CC0000 / #E53E3E) that read as foreign on a
  // warm-cream surface.
  static const Color terraCotta = Color(0xFFA8392B);

  // Slightly warmer than `background` so the floating bottom nav sits
  // a hair forward of the page surface without breaking the cream
  // palette. Also used for any home-screen surface that previously
  // rendered as pure #FFFFFF where the white was reading too cool.
  static const Color surfaceCream = Color(0xFFFAF5EC);

  // Shadow tint base. Warm brown at low alpha reads as a soft lift
  // rather than the cool, flat-grey Material default — keeps the
  // card-on-parchment visual unified with the warm palette.
  static const Color shadowWarm = Color(0xFF140800);

  // Gold gradient pair used on the coin / currency circle. Top-left
  // brighter, bottom-right deeper — gives the gold disc subtle depth
  // without competing with the flatness of surrounding chrome.
  // Prefixed `coin*` so it doesn't clash with the existing `_C.goldLight`
  // SOLID gold accent used elsewhere on the home feed.
  static const Color coinGoldLight = Color(0xFFE0A845);
  static const Color coinGoldDeep = Color(0xFFA67520);
}

// ─── Locked radius scale ────────────────────────────────────
//
// Pick ONE value per role across the home stack so the design reads
// as one system instead of a patchwork. "Stadium" (a pill computed
// from the container height, not a fixed radius) is reserved for
// filter chips, FABs, and status pills.
class AppRadius {
  /// Buttons, inline icon containers.
  static const double small = 12;

  /// Chips inside cards, text fields, small surfaces.
  static const double medium = 16;

  /// Cards, banners, the page-level surfaces.
  static const double large = 20;
}

// ─── Warm shadow recipe ─────────────────────────────────────
//
// Two-layer warm-tinted card shadow. Soft far layer + tight near
// layer — the combination reads as gentle lift on a parchment surface
// without the cool grey "card on a wall" feel of stock Material
// elevation. Use on cards, banners, the bell button, etc.
//
// kept as a top-level getter (not a const list) because BoxShadow's
// constructor is non-const when alpha-mixing through withValues.
List<BoxShadow> get kWarmCardShadow => const [
      BoxShadow(
        color: Color(0x08140800), // ~3% warm brown
        blurRadius: 24,
        offset: Offset(0, 4),
      ),
      BoxShadow(
        color: Color(0x05140800), // ~2% warm brown
        blurRadius: 4,
        offset: Offset(0, 1),
      ),
    ];
