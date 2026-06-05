// Renders the live "Gospel Vox v<version>" string sourced from
// package_info_plus so the About / Settings footer never drifts away
// from pubspec.yaml. The version is cached in a module-level Future
// so multiple call sites (about page, user settings, priest settings)
// hit PlatformChannels exactly once per process.
//
// While the version is loading we render an empty SizedBox of the
// same line-height as the resolved text — avoids a layout jump when
// the future resolves a few milliseconds after first paint.

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'package:gospel_vox/core/theme/app_colors.dart';

Future<PackageInfo>? _cachedInfo;

Future<PackageInfo> _loadInfo() {
  return _cachedInfo ??= PackageInfo.fromPlatform();
}

class AppVersionText extends StatelessWidget {
  // Optional prefix — "Gospel Vox v" on the settings footer, plain
  // "Version " on the About page. Kept configurable so the two
  // existing visuals don't have to converge.
  final String prefix;
  final TextStyle? style;

  const AppVersionText({
    super.key,
    this.prefix = 'Gospel Vox v',
    this.style,
  });

  @override
  Widget build(BuildContext context) {
    final effectiveStyle = style ??
        GoogleFonts.inter(
          fontSize: 11,
          fontWeight: FontWeight.w400,
          color: AppColors.muted.withValues(alpha: 0.5),
        );

    return FutureBuilder<PackageInfo>(
      future: _loadInfo(),
      builder: (context, snapshot) {
        final version = snapshot.data?.version ?? '';
        return Text(
          version.isEmpty ? '' : '$prefix$version',
          style: effectiveStyle,
        );
      },
    );
  }
}
