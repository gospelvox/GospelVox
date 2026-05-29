// Inbound deep-link handler.
//
// Listens for OS-routed URIs (both cold-start and warm) and pushes
// the matching in-app route via go_router. Currently handles a
// single scheme — the dummy custom scheme for shared priest profiles:
//
//   gospelvox://priest/<uid>      → /user/priest/<uid>
//
// When we eventually wire up Android App Links / iOS Universal Links
// on a real https://gospelvox.app domain, this same service handles
// those URIs too — the parser only cares about path segments, so a
// universal-link URI like `https://gospelvox.app/priest/<uid>` maps
// to the exact same route without any extra branching.
//
// Singleton so callers (main.dart's bootstrap) and the rest of the
// app reference the same active subscription. Re-init is a no-op
// after the first call; subscription stays alive for the app's
// lifetime.

import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';

import 'package:gospel_vox/core/router/app_router.dart';

class DeepLinkService {
  DeepLinkService._();
  static final DeepLinkService _instance = DeepLinkService._();
  factory DeepLinkService() => _instance;

  final AppLinks _appLinks = AppLinks();
  StreamSubscription<Uri>? _sub;
  bool _initialised = false;

  Future<void> init() async {
    if (_initialised) return;
    _initialised = true;

    // Cold-start: the OS launched the app via a link. AppLinks
    // surfaces it through getInitialAppLink() exactly once.
    try {
      final initial = await _appLinks.getInitialLink();
      if (initial != null) {
        _handle(initial);
      }
    } catch (e) {
      debugPrint('[DeepLink] getInitialLink failed: $e');
    }

    // Warm: app already running when the user taps a deep link.
    _sub = _appLinks.uriLinkStream.listen(
      _handle,
      onError: (Object e) {
        debugPrint('[DeepLink] stream error: $e');
      },
    );
  }

  // Public so the FCM tap handler / other in-app navigators can
  // funnel through the same parser if they ever need to.
  void _handle(Uri uri) {
    debugPrint('[DeepLink] received: $uri');

    final route = _routeFor(uri);
    if (route == null) {
      debugPrint('[DeepLink] no route matched, ignoring');
      return;
    }

    // Push (not replace) so the user can back-button out to wherever
    // they were before. If they're at cold-start with nothing on the
    // stack, go_router falls back to the initial route anyway.
    try {
      appRouter.push(route);
    } catch (e) {
      debugPrint('[DeepLink] router.push failed for $route: $e');
    }
  }

  // Translate an inbound URI to an in-app route string.
  // Accepts both the custom scheme (gospelvox://) and the future
  // https://gospelvox.app URLs so we don't need a second branch
  // when the domain goes live.
  String? _routeFor(Uri uri) {
    final segments =
        uri.pathSegments.where((s) => s.isNotEmpty).toList();
    // The custom scheme parses with `host` as the first segment
    // (e.g. gospelvox://priest/abc → host="priest", path=""), so
    // we prepend host to the segment list when present.
    final all = <String>[
      if (uri.host.isNotEmpty) uri.host,
      ...segments,
    ];

    if (all.length >= 2 && all[0] == 'priest') {
      final id = all[1];
      if (id.isEmpty) return null;
      return '/user/priest/$id';
    }

    return null;
  }

  Future<void> dispose() async {
    await _sub?.cancel();
    _sub = null;
    _initialised = false;
  }
}
