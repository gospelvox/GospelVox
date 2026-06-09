// Gospel Vox — Global Christian Spiritual Consultation Platform

import 'dart:async';
import 'dart:ui';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:gospel_vox/core/router/app_router.dart';
import 'package:gospel_vox/core/services/connectivity_service.dart';
import 'package:gospel_vox/core/services/deep_link_service.dart';
import 'package:gospel_vox/core/services/iap_service.dart';
import 'package:gospel_vox/core/services/injection_container.dart';
import 'package:gospel_vox/core/services/notification_service.dart';
import 'package:gospel_vox/core/services/priest_incoming_request_service.dart';
import 'package:gospel_vox/core/theme/app_colors.dart';
import 'package:gospel_vox/core/theme/app_theme.dart';
import 'package:gospel_vox/core/utils/bloc_observer.dart';
import 'package:gospel_vox/core/widgets/bible_session_live_overlay.dart';
import 'package:gospel_vox/core/widgets/missed_request_foreground_banner.dart';
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

  // Global priest-side incoming-call router. Owns the pending-
  // session listener for the priest's whole signed-in lifetime so
  // a call routes to /priest/incoming regardless of which page
  // they're currently on (summary, wallet, settings, my-users).
  // Previously this listener was inside the dashboard widget and
  // disappeared the moment the priest navigated away — calls then
  // silently expired without ringing. Synchronous binding to
  // authStateChanges; no network I/O until a priest signs in.
  PriestIncomingRequestService().init();

  // Inbound deep-link handler — listens for shared
  // gospelvox://priest/<uid> URIs and routes the user to the
  // corresponding profile page. Cold-start link is consumed as
  // part of init(); warm subscription stays alive for the app's
  // lifetime. Initialised after dependencies so the router (the
  // navigation target) is already wired up.
  unawaited(DeepLinkService().init());

  await initDependencies();

  // Start the global Play Billing listener AFTER DI is wired (so the
  // service can resolve WalletRepository) and BEFORE runApp (so no
  // wallet page can mount before the stream subscription exists,
  // which would lose any re-delivered purchases the plugin emits at
  // subscribe time). Fire-and-forget — the service handles its own
  // store-unavailable / non-Android fallback internally and never
  // throws out of init.
  unawaited(sl<IapService>().init());

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
      // Wrap every screen with three persistent overlays — order
      // matters for layering, all float above the active route
      // without pushing it down:
      //   • OfflineBanner — informational pill when connectivity
      //     drops. Innermost so it sits closest to the page content.
      //   • MissedRequestForegroundBanner — slide-down pill when an
      //     FCM missed_request lands while the app is foregrounded.
      //     Middle so it beats the offline banner but yields to a
      //     bible-live overlay if both fire simultaneously.
      //   • BibleSessionLiveOverlay — full-screen call-like UI when
      //     an FCM bible_session_live lands while foregrounded.
      //     Outermost because a session-starting-now moment is more
      //     urgent than either of the other two and must own the
      //     whole screen until the user joins or dismisses.
      builder: (context, child) {
        return BibleSessionLiveOverlay(
          child: MissedRequestForegroundBanner(
            child: OfflineBanner(
              child: child ?? const SizedBox.shrink(),
            ),
          ),
        );
      },
    );
  }
}
