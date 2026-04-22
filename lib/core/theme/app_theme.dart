// Material ThemeData configuration for Gospel Vox
//
// All colours used here come from AppColors. There was drift between
// this file and the palette before — cursor/border/hint colours were
// re-declared as raw hex that had to be kept in sync by hand. Now
// every colour reads from the single source of truth.

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:gospel_vox/core/theme/app_colors.dart';

// Subtle input border tint. Not in AppColors because it's only used
// by the input theme (it's a hairline, not a brand colour). Kept
// private here so the input style stays cohesive without polluting
// the shared palette.
const Color _kInputBorder = Color(0xFFE0D6C8);

class AppTheme {
  static ThemeData get lightTheme {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      scaffoldBackgroundColor: AppColors.warmBeige,
      fontFamily: GoogleFonts.inter().fontFamily,
      colorScheme: ColorScheme.fromSeed(
        seedColor: AppColors.primaryBrown,
        primary: AppColors.primaryBrown,
        secondary: AppColors.amberGold,
        surface: AppColors.white,
        error: AppColors.error,
        brightness: Brightness.light,
      ),
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: AppColors.primaryBrown,
        selectionColor: AppColors.primaryBrown.withValues(alpha: 0.25),
        selectionHandleColor: AppColors.primaryBrown,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.surfaceWhite,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: _kInputBorder, width: 1),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: _kInputBorder, width: 1),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(
            color: AppColors.primaryBrown,
            width: 1.5,
          ),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: AppColors.errorRed, width: 1),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(
            color: AppColors.errorRed,
            width: 1.5,
          ),
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        hintStyle: const TextStyle(color: AppColors.muted, fontSize: 14),
        labelStyle: const TextStyle(color: AppColors.muted, fontSize: 14),
        floatingLabelStyle: const TextStyle(
          color: AppColors.primaryBrown,
          fontSize: 14,
        ),
        prefixIconColor: AppColors.muted,
        suffixIconColor: AppColors.muted,
        errorStyle: const TextStyle(color: AppColors.errorRed, fontSize: 12),
      ),
    );
  }
}
