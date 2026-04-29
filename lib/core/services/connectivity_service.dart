// Global connectivity tracker.
//
// Reasons for a singleton-with-stream rather than a per-widget check:
//   • Only one platform-channel subscription per process — opening
//     `Connectivity().onConnectivityChanged` multiple times leaks
//     channels on Android and produces duplicate events.
//   • Auth, sign-in, and the offline banner all need the SAME
//     real-time state — pulling it from one source avoids the case
//     where the banner says "online" while the auth retry says
//     "offline" because they polled at different moments.
//
// Caveat: connectivity_plus reports the *interface* state, not actual
// reachability. A phone on WiFi with no upstream internet (captive
// portal, broken DNS) still reports "wifi" — which is precisely the
// situation we hit on the dev SM E055F. To paper over that, the
// service also surfaces a `recordReachabilityFailure()` hook that
// downstream code (auth, Firestore retries) can call when an actual
// network operation fails — letting the banner reflect "you have
// WiFi but the app can't reach our servers" instead of nothing.

import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

class ConnectivityService {
  static final ConnectivityService _instance = ConnectivityService._();
  factory ConnectivityService() => _instance;
  ConnectivityService._();

  final Connectivity _connectivity = Connectivity();
  StreamSubscription<List<ConnectivityResult>>? _sub;

  // Broadcast so multiple widgets (banner + auth + DI consumers)
  // can listen without fighting over a single-subscription stream.
  final StreamController<bool> _controller =
      StreamController<bool>.broadcast();

  bool _isOnline = true;
  bool _initialized = false;

  // Public read-only state. Default true so the UI doesn't flash
  // an "offline" banner during the very first frame before the
  // platform check returns.
  bool get isOnline => _isOnline;

  // Listen for online/offline transitions. Emits the new boolean
  // state — true = online, false = offline.
  Stream<bool> get onChanged => _controller.stream;

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    try {
      final initial = await _connectivity.checkConnectivity();
      _applyResult(initial);
    } catch (e) {
      debugPrint('[Connectivity] initial check failed: $e');
    }

    _sub = _connectivity.onConnectivityChanged.listen(
      _applyResult,
      onError: (Object e) {
        debugPrint('[Connectivity] stream error: $e');
      },
    );
  }

  void _applyResult(List<ConnectivityResult> result) {
    // connectivity_plus 5+ returns a list (a phone can be on WiFi +
    // mobile simultaneously). We're online if ANY interface is up
    // and not "none".
    final hasInterface = result.any((r) =>
        r != ConnectivityResult.none &&
        r != ConnectivityResult.bluetooth);

    if (hasInterface != _isOnline) {
      _isOnline = hasInterface;
      _controller.add(_isOnline);
      debugPrint('[Connectivity] state → ${_isOnline ? "online" : "offline"}');
    }
  }

  // Allows downstream code that just hit a network failure to flag
  // the banner — useful when the OS reports "wifi connected" but
  // DNS is broken / captive portal blocks us. Non-sticky: the
  // platform stream re-asserts true on the next change.
  void recordReachabilityFailure() {
    if (_isOnline) {
      _isOnline = false;
      _controller.add(false);
      debugPrint('[Connectivity] forced offline by reachability failure');
    }
  }

  // Mostly for tests — production code shouldn't need to dispose
  // a singleton, but exposing it keeps the API symmetric.
  Future<void> dispose() async {
    await _sub?.cancel();
    await _controller.close();
  }
}
