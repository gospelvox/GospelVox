// FCM push notifications + local notification orchestration.
//
// Lifecycle:
//   • init() — called once from main.dart after Firebase.initializeApp.
//     Requests permission, registers handlers, persists the token.
//   • removeToken() — called from AuthRepository.signOut() before
//     FirebaseAuth.signOut(), so a signed-out user stops receiving
//     pushes addressed to their previous account on this device.
//
// Foreground display:
//   FCM does NOT auto-display notifications when the app is open.
//   _onForegroundMessage hands the payload to flutter_local_notifications
//   so the user still sees a banner. Background/terminated states are
//   handled by the OS using the FCM payload directly — that's why the
//   top-level firebaseMessagingBackgroundHandler is intentionally a
//   no-op data sink.
//
// Navigation:
//   We don't navigate from inside the handler — the GoRouter context
//   isn't reliably available in onMessageOpenedApp / getInitialMessage.
//   Instead we stash the route in NotificationService.pendingRoute
//   and the shell pages drain it from initState via a post-frame
//   callback once the router has mounted.

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

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

    // Session requests get their own channel with max importance so
    // the OS heads-up banner + sound fire reliably even under aggressive
    // OEM battery managers (Xiaomi/Oppo/Samsung).
    const sessionChannel = AndroidNotificationChannel(
      'gospel_vox_sessions',
      'Session Requests',
      description: 'Incoming session requests from users',
      importance: Importance.max,
      playSound: true,
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
      onDidReceiveNotificationResponse: (response) {
        _handleNotificationTapFromPayload(response.payload);
      },
    );
  }

  Future<void> _saveToken() async {
    try {
      final token = await _messaging.getToken();
      if (token == null) return;

      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid == null) return;

      // set(merge:true) — not update() — because on a first-time sign-in
      // the auth cubit creates users/{uid} AFTER the user picks a role,
      // which happens after authStateChanges fires this save. update()
      // would throw not-found and we'd never get a second chance to
      // persist this device's token. With merge, we either create a
      // sparse {fcmTokens:[t]} doc that createUserDocument later
      // augments, or augment an existing doc that already has it.
      // Both AuthRepository.createUserDocument and this method use
      // merge, so the writes are commutative.
      //
      // arrayUnion supports the multi-device case — the same user
      // signed in on phone + tablet ends up with both tokens, and the
      // CF helper cleans up stale ones when FCM rejects them.
      await FirebaseFirestore.instance.doc('users/$uid').set({
        'fcmTokens': FieldValue.arrayUnion([token]),
      }, SetOptions(merge: true));

      debugPrint('[FCM] Token saved: ${token.substring(0, 20)}...');
    } catch (e) {
      debugPrint('[FCM] Token error: $e');
    }
  }

  void _onTokenRefresh(String newToken) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;

    try {
      await FirebaseFirestore.instance.doc('users/$uid').set({
        'fcmTokens': FieldValue.arrayUnion([newToken]),
      }, SetOptions(merge: true));
      debugPrint('[FCM] Token refreshed');
    } catch (e) {
      debugPrint('[FCM] Token refresh save failed: $e');
    }
  }

  void _onForegroundMessage(RemoteMessage message) {
    debugPrint('[FCM] Foreground message: ${message.notification?.title}');

    final notification = message.notification;
    if (notification == null) return;

    final type = message.data['type'] as String? ?? '';
    final isSessionRequest = type == 'session_request';
    final channelId = isSessionRequest
        ? 'gospel_vox_sessions'
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
    final route = message.data['route'] as String?;
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
