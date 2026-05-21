// Canonical iOS-style back button for every user-facing page.
//
// Why a shared widget: pages previously rolled their own back button.
// Some used Material's plain `AppIcons.back` in an `IconButton`,
// some used `AppIcons.back` in a 36x36 circle, others in
// a 40x40 circle. The visual rhythm broke every time a user
// navigated between two pages with different styles. This widget
// makes every back button identical: same icon, same size, same
// container, same shadow, same haptic, same pop behavior.
//
// Place in the leading slot of an AppBar (or a top header Row) and
// pad outwards as the layout requires; do NOT wrap in another circle.
// The widget already includes the press feedback and the canPop guard,
// so callers shouldn't add their own.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import 'package:gospel_vox/core/theme/app_colors.dart';
import 'package:gospel_vox/core/widgets/app_icons.dart';

class AppBackButton extends StatelessWidget {
  // Override the default pop behavior — useful on confirm-before-exit
  // flows where the page wants to intercept the back action.
  final VoidCallback? onTap;
  // Override icon tint. Defaults to deepDarkBrown for the warm-beige
  // theme; admin / dark-on-light surfaces can pass their own color.
  final Color? color;
  // Override background tint. Defaults to surfaceWhite so the button
  // reads as a floating chip over the warm-beige background.
  final Color? backgroundColor;

  const AppBackButton({
    super.key,
    this.onTap,
    this.color,
    this.backgroundColor,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        HapticFeedback.lightImpact();
        if (onTap != null) {
          onTap!();
          return;
        }
        if (context.canPop()) context.pop();
      },
      child: Container(
        width: 40,
        height: 40,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: backgroundColor ?? AppColors.surfaceWhite,
          boxShadow: [
            BoxShadow(
              blurRadius: 8,
              offset: const Offset(0, 2),
              color: Colors.black.withValues(alpha: 0.04),
            ),
          ],
        ),
        child: AppIcon(
          AppIcons.back,
          size: 16,
          color: color ?? AppColors.deepDarkBrown,
        ),
      ),
    );
  }
}
