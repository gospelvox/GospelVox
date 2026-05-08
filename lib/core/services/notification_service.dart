// FCM push notifications + local notification orchestration.
//
// Lifecycle:
//   • init() — called once from main.dart after Firebase.initializeApp.
//     Requests permission, registers handlers, persists the token.
//   • removeToken() — called from AuthRepository.signOut() before
//     FirebaseAuth.signOut(), so a signed-out user stops receiving
//     pushes addressed to their previous account on this device.
//
// Display strategy:
//   FCM messages carry both a `notification` block (rendered by the
//   Android system when the app is backgrounded / killed) and a `data`
//   block (delivered to onMessage in foreground or to the background
//   handler otherwise). The CF picks the right channel id at send
//   time — gospel_vox_sessions_v2 for incoming session requests so
//   sound + vibrate fire at max importance, gospel_vox_default for
//   everything else.
//
//   Foreground: _onForegroundMessage shows a parallel local notification
//   so the priest still sees a tray entry (Android suppresses FCM-
//   rendered notifications while the app is foregrounded). The
//   dashboard's pending-request Firestore stream is the source of
//   truth for in-app routing — the local notification is purely a
//   tray record of what the priest already saw on screen.
//
//   Background / killed: Android auto-renders the FCM notification.
//   The Dart background handler is a debug-only no-op for normal
//   types — we deliberately do NOT show our own local notification
//   from there, because data-only FCM messages don't reliably wake
//   the background isolate on Samsung / Xiaomi / Realme. Tapping the
//   FCM-rendered notification routes through onMessageOpenedApp (or
//   getInitialMessage on cold start) → _onNotificationTap → sets
//   pendingRoute → dashboard drains it on mount.
//
// Channel ID note:
//   Android caches notification channel settings on first creation —
//   updates to importance / sound / vibrate are silently ignored
//   thereafter. The session-request channel id is bumped to
//   gospel_vox_sessions_v2 to force a fresh channel with the correct
//   max-importance + sound + vibrate settings on installs that came
//   up before those settings were wired.
//
// Navigation:
//   We don't navigate from inside the handler — the GoRouter context
//   isn't reliably available in onMessageOpenedApp / getInitialMessage.
//   Instead we stash the route in NotificationService.pendingRoute
//   and the shell pages drain it from initState via a post-frame
//   callback once the router has mounted.

import 'dart:async';
import 'dart:io' show Platform;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';

// Top-level background handler — Firebase requires this to be a
// top-level function (not a class method, not a closure) because it
// runs in a separate isolate spun up by the OS when the app is
// backgrounded or terminated. The isolate has no access to instance
// state, so we keep this minimal — the OS auto-displays the
// notification from the FCM payload itself.
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(
  RemoteMessage message,
) async {
  debugPrint('[FCM] Background message: ${message.messageId}');
}

// Foreground-only payload that drives the missed-request in-app
// overlay banner mounted at MaterialApp.router.builder. Built
// from the FCM message inside _onForegroundMessage and pushed
// through NotificationService.foregroundMissedRequestEvent so a
// custom slide-down banner can react regardless of OEM heads-up
// behaviour. NOT used for any other notification type — system
// notifications still handle session_request/follow_up/etc.
//
// `id` is the FCM message id when present, otherwise the current
// timestamp. Used as a ValueKey on the banner so back-to-back
// missed requests slide a fresh card in instead of merging.
class MissedRequestForegroundEvent {
  final String id;
  final String title;
  final String body;
  final String route;

  const MissedRequestForegroundEvent({
    required this.id,
    required this.title,
    required this.body,
    required this.route,
  });
}

class NotificationService {
  static final NotificationService _instance = NotificationService._();
  factory NotificationService() => _instance;
  NotificationService._();

  final FirebaseMessaging _messaging = FirebaseMessaging.instance;
  final FlutterLocalNotificationsPlugin _localNotifications =
      FlutterLocalNotificationsPlugin();

  bool _isInitialized = false;

  // Pending notification-tap route. Drained by the shell pages on
  // mount so a tap that wakes the app from terminated state still
  // navigates correctly once GoRouter is ready.
  static String? pendingRoute;

  // Fires when an FCM message of type=missed_request arrives while
  // the app is in foreground. The MissedRequestForegroundBanner
  // overlay (mounted at MaterialApp.router.builder) listens and
  // slides a custom in-app banner down — necessary because OEMs
  // like Xiaomi/Realme/Oppo suppress Importance.high heads-up
  // notifications when the app is foregrounded, leaving the priest
  // with no visible signal otherwise. The notifier is a static
  // ValueNotifier so the banner widget can listen without needing
  // to plumb a service instance through the widget tree.
  //
  // Setting back to null after the banner has shown is the banner's
  // responsibility; the service only ever pushes new events.
  static final ValueNotifier<MissedRequestForegroundEvent?>
      foregroundMissedRequestEvent = ValueNotifier(null);

  Future<void> init() async {
    if (_isInitialized) return;
    _isInitialized = true;

    // Background handler registration MUST happen before any await —
    // Firebase needs it set up before the runtime forks the background
    // isolate. Synchronous, no network.
    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);

    // Permission dialog — local, fast. Returns the user's choice.
    final settings = await _messaging.requestPermission(
      alert: true,
      badge: true,
      sound: true,
      provisional: false,
      announcement: false,
      carPlay: false,
      criticalAlert: false,
    );

    debugPrint('[FCM] Permission: ${settings.authorizationStatus}');

    if (settings.authorizationStatus == AuthorizationStatus.denied) {
      debugPrint('[FCM] User denied notification permission');
      return;
    }

    // Local-notifications channel setup — pure platform-channel work,
    // no network required.
    await _setupLocalNotifications();

    // Android-only: ask for the runtime notification permission
    // (Android 13 / API 33+) and the battery-optimisation exemption.
    // Both are idempotent — request() returns the existing grant
    // without showing a dialog if the user already granted, and
    // returns the existing denial without nagging if the user
    // permanently refused. We fire-and-forget so a slow user
    // dismissing the dialog doesn't block runApp.
    //
    // The battery-optimisation exemption is what keeps Samsung /
    // Xiaomi / Realme from killing the app within seconds of
    // backgrounding. Without this, FCM messages stop being
    // delivered to a backgrounded priest in under a minute on
    // those OEMs and incoming requests silently disappear.
    if (!kIsWeb && Platform.isAndroid) {
      unawaited(_requestAndroidPermissionsSafely());
    }

    // Register all stream listeners synchronously. Doing this BEFORE
    // any network call ensures we never miss a foreground / tap event
    // even if the device is offline at startup. authStateChanges
    // ensures the token gets saved on first-time sign-in (currentUser
    // is null when init runs before runApp).
    _messaging.onTokenRefresh.listen(_onTokenRefresh);
    FirebaseMessaging.onMessage.listen(_onForegroundMessage);
    FirebaseMessaging.onMessageOpenedApp.listen(_onNotificationTap);
    FirebaseAuth.instance.authStateChanges().listen((user) {
      if (user != null) _saveToken();
    });

    // From here down, every call may need network. We deliberately do
    // NOT await — so a phone with no connectivity (DNS failure, plane
    // mode, captive portal) still reaches runApp instead of hanging
    // on the splash screen forever. The token save will retry via the
    // authStateChanges listener once the user signs in (or via
    // onTokenRefresh once FCM rotates the token), and the cold-start
    // tap path tolerates a few seconds of lateness.
    unawaited(_saveTokenWithTimeout());
    unawaited(_drainInitialMessageWithTimeout());
    unawaited(_drainLocalLaunchDetailsWithTimeout());
    unawaited(_setForegroundOptionsSafely());
  }

  Future<void> _saveTokenWithTimeout() async {
    try {
      await _saveToken().timeout(const Duration(seconds: 8));
    } catch (e) {
      debugPrint('[FCM] _saveToken timed out or failed: $e');
    }
  }

  Future<void> _drainInitialMessageWithTimeout() async {
    try {
      final initialMessage = await _messaging
          .getInitialMessage()
          .timeout(const Duration(seconds: 5));
      if (initialMessage != null) {
        _onNotificationTap(initialMessage);
      }
    } catch (e) {
      debugPrint('[FCM] getInitialMessage timed out or failed: $e');
    }
  }

  // Cold-start path for a tap on a LOCAL notification we shown
  // (e.g. a foreground-rendered notification that was still in
  // the tray when the app got killed and the priest tapped it
  // afterwards). FCM-rendered notifications for session_request
  // are drained by getInitialMessage above; this is the parallel
  // path for plugin-rendered ones. Payload is the plain route
  // string (set by _onForegroundMessage) so we just stash it.
  Future<void> _drainLocalLaunchDetailsWithTimeout() async {
    try {
      final details = await _localNotifications
          .getNotificationAppLaunchDetails()
          .timeout(const Duration(seconds: 5));
      if (details == null || !details.didNotificationLaunchApp) return;
      final response = details.notificationResponse;
      if (response == null) return;
      _handleNotificationTapFromPayload(response.payload);
    } catch (e) {
      debugPrint('[FCM] getNotificationAppLaunchDetails failed: $e');
    }
  }

  Future<void> _requestAndroidPermissionsSafely() async {
    try {
      // Notification permission. The FirebaseMessaging.requestPermission
      // call earlier in init() handles the Android 13 dialog already on
      // recent firebase_messaging versions, but routing through
      // permission_handler too is harmless (idempotent) and gives us
      // a uniform code path if the FCM plugin's behaviour changes.
      await Permission.notification.request();
    } catch (e) {
      debugPrint('[FCM] notification permission request failed: $e');
    }
    try {
      // Battery-optimisation exemption — opens a system settings
      // sheet asking the user to allow the app to ignore battery
      // optimisations. Without this, OEM background-killers
      // (Xiaomi / Realme / Oppo / aggressive Samsung profiles)
      // terminate the app within seconds of backgrounding and FCM
      // messages stop being delivered to a backgrounded priest.
      // Asking once is enough — denial remembered by the OS until
      // the user changes it from Settings.
      await Permission.ignoreBatteryOptimizations.request();
    } catch (e) {
      debugPrint('[FCM] battery-optimisation request failed: $e');
    }
  }

  Future<void> _setForegroundOptionsSafely() async {
    try {
      await _messaging
          .setForegroundNotificationPresentationOptions(
            alert: true,
            badge: true,
            sound: true,
          )
          .timeout(const Duration(seconds: 5));
    } catch (e) {
      debugPrint('[FCM] setForegroundNotificationPresentationOptions: $e');
    }
  }

  Future<void> _setupLocalNotifications() async {
    const androidChannel = AndroidNotificationChannel(
      'gospel_vox_default',
      'General',
      description: 'Gospel Vox notifications',
      importance: Importance.high,
      playSound: true,
    );

    // Session-request channel — id is bumped to v2 to force a fresh
    // channel with max-importance + sound + vibrate on installs that
    // came up before those settings were wired. Android caches
    // channel settings on first creation; v2 is the only way to
    // reach existing devices without an uninstall. The legacy
    // gospel_vox_sessions channel still exists on those devices
    // but is no longer targeted from anywhere.
    const sessionChannel = AndroidNotificationChannel(
      'gospel_vox_sessions_v2',
      'Session Requests',
      description: 'Incoming chat and call requests',
      importance: Importance.max,
      playSound: true,
      enableVibration: true,
    );

    final androidPlugin =
        _localNotifications.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();

    await androidPlugin?.createNotificationChannel(androidChannel);
    await androidPlugin?.createNotificationChannel(sessionChannel);

    await _localNotifications.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        // iOS permissions were requested via FirebaseMessaging above —
        // asking again here would prompt the user twice.
        iOS: DarwinInitializationSettings(
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
        ),
      ),
      // Tap on a foreground-shown local notification — payload is
      // the plain route string set by _onForegroundMessage. Stash it
      // and let the shell pages drain via pendingRoute on mount.
      onDidReceiveNotificationResponse: (response) {
        _handleNotificationTapFromPayload(response.payload);
      },
    );
  }

  // Public wrapper. Called from AuthRepository.createUserDocument
  // immediately AFTER the user doc is created on first sign-in, so
  // the FCM token lands on the freshly-created doc instead of
  // waiting for the next app start / token refresh.
  Future<void> saveToken() => _saveToken();

  Future<void> _saveToken() async {
    try {
      final token = await _messaging.getToken();
      if (token == null) return;

      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid == null) return;

      // update() — not set(merge:true) — because the user doc may
      // not exist yet on the very first sign-in. set(merge:true) on
      // a non-existent doc is treated as a CREATE by Firestore
      // rules, and the users-collection CREATE rule REQUIRES
      // coinBalance==0 AND role in ["user","priest"] — neither of
      // which an FCM-only payload includes. That race is what made
      // first-tap Google sign-in surface a "Something went wrong"
      // error: this write got PERMISSION_DENIED before the auth
      // cubit's createUserDocument could land.
      //
      // update() instead fails fast with a not-found if the doc
      // doesn't exist, which we catch and silently skip. The token
      // gets persisted by createUserDocument's explicit saveToken
      // call right after it creates the doc, OR on the next app
      // start when the doc is guaranteed to exist.
      //
      // arrayUnion still supports the multi-device case — the same
      // user signed in on phone + tablet ends up with both tokens,
      // and the CF helper cleans up stale ones when FCM rejects
      // them.
      await FirebaseFirestore.instance.doc('users/$uid').update({
        'fcmTokens': FieldValue.arrayUnion([token]),
      });

      debugPrint('[FCM] Token saved: ${token.substring(0, 20)}...');
    } on FirebaseException catch (e) {
      if (e.code == 'not-found') {
        debugPrint(
          '[FCM] User doc not yet created — token save will retry '
          'after createUserDocument',
        );
        return;
      }
      debugPrint('[FCM] Token save Firebase error: $e');
    } catch (e) {
      debugPrint('[FCM] Token error: $e');
    }
  }

  void _onTokenRefresh(String newToken) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;

    try {
      // Same rule-friendly update() (not set merge:true) as
      // _saveToken — see that method's comment for why. A token
      // refresh against a missing doc means we're in the brief
      // window between sign-in and createUserDocument; skip and
      // let the post-create explicit saveToken catch it up.
      await FirebaseFirestore.instance.doc('users/$uid').update({
        'fcmTokens': FieldValue.arrayUnion([newToken]),
      });
      debugPrint('[FCM] Token refreshed');
    } on FirebaseException catch (e) {
      if (e.code == 'not-found') {
        debugPrint('[FCM] Token refresh: user doc missing — skipping');
        return;
      }
      debugPrint('[FCM] Token refresh Firebase error: $e');
    } catch (e) {
      debugPrint('[FCM] Token refresh save failed: $e');
    }
  }

  void _onForegroundMessage(RemoteMessage message) {
    debugPrint('[FCM] Foreground message: ${message.notification?.title}');

    final notification = message.notification;
    if (notification == null) return;

    final type = message.data['type'] as String? ?? '';

    // Missed-request gets a custom in-app overlay banner instead of
    // a system local-notification — Importance.high doesn't reliably
    // pop a heads-up while the app is foregrounded on OEM-themed
    // Android (Xiaomi / Realme / Oppo / some Samsung), and the
    // priest needs an unmistakable in-app signal that someone tried
    // to reach them. The Firestore notification doc + FCM data
    // payload are still both intact, so the inbox + dashboard
    // banner + push-while-backgrounded paths are unaffected.
    if (type == 'missed_request') {
      foregroundMissedRequestEvent.value = MissedRequestForegroundEvent(
        id: message.messageId ??
            DateTime.now().microsecondsSinceEpoch.toString(),
        title: notification.title ?? 'Missed Request',
        body: notification.body ?? 'Someone tried to reach you',
        route: (message.data['route'] as String?) ?? '/priest/my-users',
      );
      return;
    }

    final isSessionRequest = type == 'session_request';
    final channelId = isSessionRequest
        ? 'gospel_vox_sessions_v2'
        : 'gospel_vox_default';
    final channelName = isSessionRequest ? 'Session Requests' : 'General';

    _localNotifications.show(
      id: notification.hashCode,
      title: notification.title,
      body: notification.body,
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          channelId,
          channelName,
          importance: isSessionRequest
              ? Importance.max
              : Importance.high,
          priority: isSessionRequest ? Priority.max : Priority.high,
          icon: '@mipmap/ic_launcher',
        ),
        iOS: const DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
        ),
      ),
      payload: message.data['route'] as String?,
    );
  }

  void _onNotificationTap(RemoteMessage message) {
    // missed_request always lands on the dedicated missed-requests
    // page. The CF still writes the legacy "/priest/my-users" deep
    // link in the FCM data payload, so we override it here for both
    // the background-resume tap (onMessageOpenedApp) and the cold-
    // start tap (getInitialMessage) since both share this handler.
    final type = message.data['type'] as String? ?? '';
    final dataRoute = message.data['route'] as String?;
    final route = type == 'missed_request'
        ? '/priest/missed-requests'
        : dataRoute;
    _handleNotificationTapFromPayload(route);
  }

  void _handleNotificationTapFromPayload(String? route) {
    if (route == null || route.isEmpty) return;
    pendingRoute = route;
    debugPrint('[FCM] Pending navigation: $route');
  }

  Future<void> removeToken() async {
    try {
      final token = await _messaging.getToken();
      final uid = FirebaseAuth.instance.currentUser?.uid;

      if (token != null && uid != null) {
        await FirebaseFirestore.instance.doc('users/$uid').update({
          'fcmTokens': FieldValue.arrayRemove([token]),
        });
      }

      await _messaging.deleteToken();
      debugPrint('[FCM] Token removed on sign out');
    } catch (e) {
      debugPrint('[FCM] Token removal failed: $e');
    }
  }
}
