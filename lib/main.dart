// Gospel Vox — Global Christian Spiritual Consultation Platform

import 'dart:async';
import 'dart:ui';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:gospel_vox/core/router/app_router.dart';
import 'package:gospel_vox/core/services/connectivity_service.dart';
import 'package:gospel_vox/core/services/injection_container.dart';
import 'package:gospel_vox/core/services/notification_service.dart';
import 'package:gospel_vox/core/theme/app_colors.dart';
import 'package:gospel_vox/core/theme/app_theme.dart';
import 'package:gospel_vox/core/utils/bloc_observer.dart';
import 'package:gospel_vox/core/widgets/offline_banner.dart';
import 'package:gospel_vox/firebase_options.dart';

// Suppresses noise from third-party packages that print directly when
// they can't reach the network. google_fonts in particular calls
// `print()` in its load-failure path, which bypasses the standard
// FlutterError / PlatformDispatcher hooks — the only way to filter
// those is via a Zone-scoped print interceptor wrapping runApp.
bool _isNoisyOfflineError(String line) {
  return line.contains('google_fonts was unable to load font') ||
      line.contains('GoogleFonts.config.allowRuntimeFetching') ||
      line.contains('fonts.gstatic.com') ||
      line.contains('docs.flutter.dev/development/data-and-backend');
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.dark,
    statusBarBrightness: Brightness.light,
    systemNavigationBarColor: AppColors.warmBeige,
    systemNavigationBarIconBrightness: Brightness.dark,
    systemNavigationBarDividerColor: Colors.transparent,
  ));

  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

  // Connectivity tracker — must be ready before runApp so the offline
  // banner shows on the very first frame if the device is offline at
  // launch. Local platform-channel call, no network needed.
  await ConnectivityService().init();

  // Push notifications. init() registers the FCM background handler +
  // listeners synchronously, then fires network-dependent work
  // (token persist, getInitialMessage) without blocking — so a phone
  // with broken DNS still reaches runApp instead of hanging on splash.
  await NotificationService().init();

  await initDependencies();

  Bloc.observer = AppBlocObserver();

  // Catch Flutter framework errors (layout, painting, gestures).
  FlutterError.onError = (details) {
    debugPrint('[GospelVox] FlutterError: ${details.exception}');
    debugPrint('[GospelVox] Stack: ${details.stack}');
  };

  // Catch unhandled async errors that fall outside the framework.
  // Filter google_fonts noise — when offline, the library throws
  // network errors which it ALSO prints separately; the duplication
  // is just visual clutter and the app still renders fallback fonts.
  PlatformDispatcher.instance.onError = (error, stack) {
    final msg = error.toString();
    if (!_isNoisyOfflineError(msg)) {
      debugPrint('[GospelVox] AsyncError: $error');
    }
    return true;
  };

  // Wrap runApp in a Zone that intercepts print() — this is the only
  // way to silence google_fonts' direct `print('Error: ...')` calls
  // from its font-load failure path, since they bypass FlutterError
  // and PlatformDispatcher entirely.
  runZonedGuarded(
    () => runApp(const GospelVoxApp()),
    (error, stack) {
      final msg = error.toString();
      if (!_isNoisyOfflineError(msg)) {
        debugPrint('[GospelVox] ZoneError: $error');
      }
    },
    zoneSpecification: ZoneSpecification(
      print: (self, parent, zone, line) {
        if (_isNoisyOfflineError(line)) return;
        parent.print(zone, line);
      },
    ),
  );
}

class GospelVoxApp extends StatelessWidget {
  const GospelVoxApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'Gospel Vox',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme,
      routerConfig: appRouter,
      // Wrap every screen with the offline banner so the user always
      // gets a visible explanation when network drops, regardless of
      // which route they're on. The banner is a Stack overlay — it
      // doesn't push the page content down, just floats above.
      builder: (context, child) {
        return OfflineBanner(child: child ?? const SizedBox.shrink());
      },
    );
  }
}
