// A UI-only safety net for in-app purchase surfaces.
//
// ── The problem it solves ──────────────────────────────────────
// Every payment surface (wallet, recharge sheet, priest activation,
// bible entry) flips a local "busy" flag the instant a buy is
// dispatched to Google Play, and only clears that flag when an
// IapOutcome arrives on the global IapService stream. On the wallet
// the flag also disables the back button (PopScope) so the user can't
// navigate away mid-verification.
//
// That is correct as long as the store ALWAYS reports a terminal
// event. It doesn't. The well-known gap on Android is the user
// dismissing the Play sheet with the back gesture: the
// `in_app_purchase` plugin does not reliably emit a `canceled` event
// in that path. No event → the busy flag (and the back-button block)
// would stay on forever → the screen is stuck with no escape.
//
// ── What this does ─────────────────────────────────────────────
// It arms a timer when a buy starts and, if no outcome has disarmed
// it in time, calls a single `onExpire` callback whose ONLY job is to
// reset the caller's local busy UI state. That's it.
//
// ── Why it can NEVER affect the payment / billing ──────────────
// This class does not import or call Google Play Billing or any Cloud
// Function. It owns a Timer and a lifecycle observer; on expiry it
// flips a Dart bool in the caller. The real purchase keeps flowing on
// its own path: the app-scope IapService listener stays subscribed
// and will still verify + credit whenever (if) the store finally
// replies — even after the busy UI was released — and a genuinely
// dropped purchase is reconciled by `restorePurchases` on the next app
// launch. Releasing the UI early therefore can only ever UNBLOCK a
// stuck screen; it can never cancel, drop, or double-handle a payment.
//
// ── Why it never fires during a real verification ──────────────
// Each verify Cloud Function call is wrapped in a hard client-side
// timeout (coins / activation 20 s, bible 30 s). So whenever a verify
// is actually running, IapService emits an outcome — success OR a
// timeout error — within that window, which disarms this watchdog.
// Callers pass a `timeout` set ABOVE their verify ceiling, so the
// watchdog only ever fires in the true "store sent nothing" case
// where there is no verification in flight to interfere with.
//
// ── Why it counts FOREGROUND time only ─────────────────────────
// While the Play sheet is open our app is backgrounded, and the user
// may legitimately spend a long time there (entering a card, an OTP,
// a UPI mandate). Counting wall-clock from the tap would fire the
// timer mid-payment. Instead the timer is paused while the app is not
// in the foreground and resumes when the user returns — so the only
// time that counts is time the user is actually looking at our
// (potentially stuck) screen.

import 'dart:async';

import 'package:flutter/widgets.dart';

class PurchaseWatchdog with WidgetsBindingObserver {
  PurchaseWatchdog({Duration timeout = const Duration(seconds: 30)})
      : _timeout = timeout;

  // How much FOREGROUND time may elapse with no outcome before we
  // release the busy UI. Must be larger than the surface's verify
  // timeout so a legitimate in-flight verification always wins the
  // race and disarms us first.
  final Duration _timeout;

  // Accumulates only while the app is in the foreground (start/stop
  // across lifecycle transitions). `elapsed` is total foreground time
  // since arm().
  final Stopwatch _foreground = Stopwatch();

  void Function()? _onExpire;
  Timer? _timer;
  bool _armed = false;

  bool get isArmed => _armed;

  /// Start watching. Call right after a buy has been dispatched to the
  /// store (i.e. `buyConsumable` / `buyNonConsumable` returned true).
  /// Idempotent — re-arming cancels any prior cycle first.
  void arm(void Function() onExpire) {
    disarm();
    _onExpire = onExpire;
    _armed = true;
    WidgetsBinding.instance.addObserver(this);
    _foreground.reset();
    // Guard the race where the Play sheet has already backgrounded us
    // by the time arm() runs (so the `paused` event fired before our
    // observer was added). Only start counting if we're actually in
    // the foreground; otherwise wait for the `resumed` event. A null
    // state (very early in app life) is treated as foreground.
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (lifecycle == null || lifecycle == AppLifecycleState.resumed) {
      _foreground.start();
      _scheduleFromRemaining();
    }
  }

  /// Stop watching. Call on EVERY outcome that belongs to this surface
  /// (success / pending / canceled / error / unavailable) and from
  /// dispose()/close(). Idempotent and safe to call when not armed.
  void disarm() {
    _armed = false;
    _onExpire = null;
    _timer?.cancel();
    _timer = null;
    _foreground
      ..stop()
      ..reset();
    WidgetsBinding.instance.removeObserver(this);
  }

  void _scheduleFromRemaining() {
    _timer?.cancel();
    final remaining = _timeout - _foreground.elapsed;
    if (remaining <= Duration.zero) {
      _fire();
      return;
    }
    _timer = Timer(remaining, _fire);
  }

  void _fire() {
    if (!_armed) return;
    // Snapshot then disarm BEFORE invoking, so the callback (which may
    // emit/setState) runs against a fully reset watchdog and a late
    // outcome's disarm() is a harmless no-op.
    final cb = _onExpire;
    disarm();
    cb?.call();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_armed) return;
    switch (state) {
      case AppLifecycleState.resumed:
        // Back in the foreground (e.g. returned from the Play sheet).
        // Resume counting and reschedule for the remaining budget.
        if (!_foreground.isRunning) _foreground.start();
        _scheduleFromRemaining();
        break;
      case AppLifecycleState.inactive:
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        // Not in the foreground (Play sheet open, app switched away,
        // incoming call, etc.). Freeze the budget so a long, genuine
        // payment interaction never trips the watchdog.
        _foreground.stop();
        _timer?.cancel();
        _timer = null;
        break;
    }
  }
}
