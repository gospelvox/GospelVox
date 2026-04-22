// Admin-specific color palette — clean, neutral dashboard aesthetic

import 'package:flutter/material.dart';

class AdminColors {
  AdminColors._();

  // Backgrounds
  static const Color background = Color(0xFFF8F9FA);
  static const Color cardSurface = Color(0xFFFFFFFF);

  // Brand (shared with main app)
  static const Color brandBrown = Color(0xFF6B3A2A);
  static const Color brandGold = Color(0xFFD4A060);

  // Text hierarchy
  static const Color textPrimary = Color(0xFF111827);
  static const Color textBody = Color(0xFF374151);
  static const Color textMuted = Color(0xFF6B7280);
  static const Color textLight = Color(0xFF9CA3AF);

  // Borders & dividers
  static const Color divider = Color(0xFFE5E7EB);
  static const Color borderLight = Color(0xFFF0F0F0);
  static const Color inputBackground = Color(0xFFF3F4F6);

  // Status colors.
  //
  // `warning` was a loud #F59E0B orange that clashed with Gospel Vox's
  // warm brown/gold palette. Swapped for brandGold + a tinted bg so
  // "pending / attention" states feel on-brand instead of generic.
  static const Color success = Color(0xFF16A34A);
  static const Color successBg = Color(0xFFF0FDF4);
  static const Color warning = Color(0xFFD4A060);
  static const Color warningBg = Color(0xFFFBF4EA);
  static const Color error = Color(0xFFDC2626);
  static const Color errorBg = Color(0xFFFEF2F2);
  static const Color info = Color(0xFF3B82F6);
  static const Color infoBg = Color(0xFFEFF6FF);

  // Card styling constants
  static const double cardRadius = 14.0;

  static final BoxDecoration cardDecoration = BoxDecoration(
    color: cardSurface,
    borderRadius: BorderRadius.circular(cardRadius),
    border: Border.all(color: borderLight, width: 1),
    boxShadow: const [
      BoxShadow(
        color: Color(0x0A000000),
        blurRadius: 2,
        offset: Offset(0, 1),
      ),
    ],
  );
}
