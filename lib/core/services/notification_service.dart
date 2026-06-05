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

// Foreground-only payload that drives the call-like Bible session
// live overlay. Fires from _onForegroundMessage when a CF push of
// type=bible_session_live arrives. The overlay (mounted at
// MaterialApp.router.builder) listens to bibleSessionLiveEvent and
// covers the whole screen with a Join/Decline UI, similar in
// urgency to an incoming call.
//
// Photo URL is not currently included in the CF push payload — we
// fall back to an initial-letter avatar on the overlay. Adding the
// photo would require a CF deploy; the overlay is a 3-second
// decision moment where the initial fallback reads cleanly enough.
class BibleSessionLiveEvent {
  final String id;
  final String sessionId;
  final String sessionTitle;
  final String priestName;
  final String priestPhotoUrl;
  final int price;

  const BibleSessionLiveEvent({
    required this.id,
    required this.sessionId,
    required this.sessionTitle,
    required this.priestName,
    this.priestPhotoUrl = '',
    required this.price,
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
  // Flips true the first time requestPermissionsIfNeeded() runs in this
  // process. Permission dialogs are intentionally NOT triggered from
  // init() — Play Store reviewers (and Apple HIG 4.5.4) flag apps that
  // prompt for push permission at cold-start before the user has done
  // anything. Asking once after sign-in, when the user has demonstrated
  // they want to engage with the app, is both better UX and policy-safe.
  bool _permissionsRequested = false;

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

  // Fires when an FCM message of type=bible_session_live arrives
  // while the app is in foreground. The BibleSessionLiveOverlay
  // (mounted at MaterialApp.router.builder, OUTER to the missed-
  // request banner so it wins z-order) listens and renders a full-
  // screen call-like UI with Join Meeting / Not Now buttons + a
  // vibration loop. Same pattern as foregroundMissedRequestEvent —
  // the overlay clears the notifier after the user acts (or after
  // a 60-second auto-dismiss), and the service only ever pushes
  // new events.
  static final ValueNotifier<BibleSessionLiveEvent?>
      bibleSessionLiveEvent = ValueNotifier(null);

  Future<void> init() async {
    if (_isInitialized) return;
    _isInitialized = true;

    // Background handler registration MUST happen before any await —
    // Firebase needs it set up before the runtime forks the background
    // isolate. Synchronous, no network.
    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);

    // Local-notifications channel setup — pure platform-channel work,
    // no network required, no permission required. Channels can be
    // created before the user grants permission; they simply won't be
    // used to display anything until permission lands.
    await _setupLocalNotifications();

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

  // Triggers the system-level push-permission dialog. Called from each
  // role-specific shell page (user_shell_page, priest_dashboard_page,
  // admin_dashboard_page) on first mount — by the time those screens
  // are visible, the user has signed in and picked a role, which is
  // the right UX moment to ask. Idempotent and gated by a process-wide
  // flag so re-mounting the shell (tab switches, hot reload) does not
  // re-prompt.
  //
  // Safe to call from any context — failure is swallowed, the app
  // still functions; the user just won't receive pushes until they
  // re-grant from system Settings.
  Future<void> requestPermissionsIfNeeded() async {
    if (_permissionsRequested) return;
    _permissionsRequested = true;

    try {
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
    } catch (e) {
      debugPrint('[FCM] requestPermission failed: $e');
    }

    // Android-only: ask for the runtime notification permission
    // (Android 13 / API 33+) and the battery-optimisation exemption.
    // Both are idempotent — request() returns the existing grant
    // without showing a dialog if the user already granted, and
    // returns the existing denial without nagging if the user
    // permanently refused. We fire-and-forget so a slow user
    // dismissing the dialog doesn't block the shell mount.
    //
    // The battery-optimisation exemption is what keeps Samsung /
    // Xiaomi / Realme from killing the app within seconds of
    // backgrounding. Without this, FCM messages stop being
    // delivered to a backgrounded priest in under a minute on
    // those OEMs and incoming requests silently disappear.
    if (!kIsWeb && Platform.isAndroid) {
      unawaited(_requestAndroidPermissionsSafely());
    }
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

    // Bible session went LIVE — fires a full-screen call-like
    // overlay with Join Meeting / Not Now and a vibration loop.
    // Same rationale as missed_request: a system heads-up doesn't
    // reliably pop on OEM-themed Android while foregrounded, and a
    // session-just-started moment is high-urgency for a registered
    // user (they've been waiting). We deliberately suppress the
    // local-notification fallback below in this case so we don't
    // double up on the tray + overlay.
    //
    // Background / killed: the CF push still uses the default FCM
    // channel and Android renders the system notification itself —
    // tap routes to /bible/detail/{id} via _onNotificationTap.
    if (type == 'bible_session_live') {
      final data = message.data;
      // Diagnostic — surfaces in `flutter run` / adb logcat so a
      // priest-side test can confirm the foreground push actually
      // reached this device. Useful for triaging "overlay didn't
      // fire" reports where the FCM might not have arrived at all.
      debugPrint(
        '[NotifService] bible_session_live received: $data',
      );
      bibleSessionLiveEvent.value = BibleSessionLiveEvent(
        id: message.messageId ??
            DateTime.now().microsecondsSinceEpoch.toString(),
        sessionId: (data['sessionId'] as String?) ?? '',
        sessionTitle: (data['sessionTitle'] as String?) ?? 'Bible Session',
        priestName: (data['priestName'] as String?) ?? 'Speaker',
        priestPhotoUrl: (data['priestPhotoUrl'] as String?) ?? '',
        price: int.tryParse((data['price'] as String?) ?? '') ?? 0,
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
    String? route;
    if (type == 'missed_request') {
      route = '/priest/missed-requests';
    } else if (dataRoute != null && dataRoute.isNotEmpty) {
      route = dataRoute;
    } else if (type.startsWith('bible_session_')) {
      // Defensive fallback for Bible pushes that arrive without an
      // explicit route field (every CF in the bible/ folder DOES
      // include one today — this branch catches a hypothetical
      // future writer that doesn't, so the tap still lands on the
      // right detail page). User-facing types route to the user
      // detail page; priest-side life-cycle types to the priest
      // manage page.
      route = _fallbackBibleRouteForType(type, message.data);
    }
    _handleNotificationTapFromPayload(route);
  }

  // Resolves a /bible/detail/{id} vs /priest/bible/{id} fallback for
  // Bible CF pushes that omit an explicit `route`. Returns null when
  // the sessionId is missing — better to no-op than to route to a
  // detail page with an empty id and crash the route loader.
  String? _fallbackBibleRouteForType(
    String type,
    Map<String, dynamic> data,
  ) {
    final sessionId = (data['sessionId'] as String?) ?? '';
    if (sessionId.isEmpty) return null;
    // Types that target the priest (writer / host of the session).
    const priestSide = <String>{
      'bible_session_payment_received',
      'bible_session_link_reminder',
      'bible_session_link_urgent',
      'bible_session_golive',
      'bible_session_starting_priest',
      'bible_session_completed',
      'bible_session_auto_completed',
      'bible_session_first_registration',
      'bible_session_full',
      // User-rated-your-bible-session pushes route to the priest's
      // own session-detail page where the attendee + rating list
      // lives. The push payload includes an explicit `route` field
      // so this fallback is rarely hit, but keeping the set in sync
      // protects against a future writer that forgets the route.
      'bible_session_reviewed',
    };
    return priestSide.contains(type)
        ? '/priest/bible/$sessionId'
        : '/bible/detail/$sessionId';
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
