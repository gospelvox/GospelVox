// Spacing scale for the Gospel Vox design system — a 4-pt grid.
//
// This file used to be an empty `class AppSpacing {}` stub, which is
// why every page hand-rolled its own EdgeInsets (13 / 14 / 16 / 20 /
// 24 …) and the left margins quietly drifted page-to-page. These
// named steps are the single source of truth going forward; existing
// hardcoded paddings still work, but new/updated UI should reach for
// these so the rhythm stays consistent.

import 'package:flutter/widgets.dart';

class AppSpacing {
  AppSpacing._();

  // ─── Raw step scale (4-pt grid) ─────────────────────────────
  static const double xxs = 4;
  static const double xs = 8;
  static const double sm = 12;
  static const double md = 16;
  static const double lg = 20;
  static const double xl = 24;
  static const double xxl = 32;
  static const double xxxl = 40;

  // ─── Role tokens ────────────────────────────────────────────
  /// Standard horizontal gutter for a page's scrollable body.
  static const double pageGutter = 20;

  /// Standard vertical padding at the top of a page body.
  static const double pageTop = 16;

  /// Inner padding for cards / tiles.
  static const double cardPadding = 16;

  /// Inner padding for bottom sheets.
  static const double sheetPadding = 20;

  // ─── Ready-made EdgeInsets for the common cases ─────────────
  /// Horizontal-only page gutter (let the body manage its own top/bottom).
  static const EdgeInsets pageH = EdgeInsets.symmetric(horizontal: pageGutter);

  /// Page body padding: gutter on the sides, a little breathing room on top.
  static const EdgeInsets page =
      EdgeInsets.fromLTRB(pageGutter, pageTop, pageGutter, pageGutter);

  /// Card content padding.
  static const EdgeInsets card = EdgeInsets.all(cardPadding);
}
