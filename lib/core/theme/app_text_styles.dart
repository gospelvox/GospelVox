// Typography scale for the Gospel Vox design system.
//
// This file used to be an empty `class AppTextStyles {}` stub. With no
// shared scale, every screen called `GoogleFonts.inter(...)` inline
// (~150 times) with hand-tuned sizes (13.5 / 12.5 / 10.5 …) and
// weights, so the same logical text role rendered slightly differently
// across screens. These getters are the go-forward source of truth.
//
// Why getters (not const): GoogleFonts.inter() resolves the font at
// runtime, so the resulting TextStyle isn't const. Each getter returns
// a fresh style you can `.copyWith(color: …)` per surface — colour is
// deliberately left to the call site since it varies (brown on cream,
// cream on dark, muted on white, etc.).
//
// Adoption is incremental: existing inline styles keep working; reach
// for these whenever you touch a text widget so the scale spreads.

import 'package:flutter/widgets.dart';
import 'package:google_fonts/google_fonts.dart';

class AppTextStyles {
  AppTextStyles._();

  /// Large page / hero title.
  static TextStyle get h1 => GoogleFonts.inter(
        fontSize: 24,
        fontWeight: FontWeight.w800,
        height: 1.2,
      );

  /// Section / card heading.
  static TextStyle get h2 => GoogleFonts.inter(
        fontSize: 18,
        fontWeight: FontWeight.w700,
        height: 1.25,
      );

  /// Sub-heading / prominent list title.
  static TextStyle get h3 => GoogleFonts.inter(
        fontSize: 16,
        fontWeight: FontWeight.w600,
        height: 1.3,
      );

  /// Default body text.
  static TextStyle get body => GoogleFonts.inter(
        fontSize: 14,
        fontWeight: FontWeight.w500,
        height: 1.4,
      );

  /// Secondary / supporting text.
  static TextStyle get bodyMuted => GoogleFonts.inter(
        fontSize: 13,
        fontWeight: FontWeight.w400,
        height: 1.4,
      );

  /// Small print — captions, timestamps, helper text.
  static TextStyle get caption => GoogleFonts.inter(
        fontSize: 12,
        fontWeight: FontWeight.w500,
        height: 1.3,
      );

  /// Tiny labels — badges, pills, overlines.
  static TextStyle get label => GoogleFonts.inter(
        fontSize: 11,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.2,
      );

  /// Button / primary CTA label.
  static TextStyle get button => GoogleFonts.inter(
        fontSize: 15,
        fontWeight: FontWeight.w700,
      );
}
