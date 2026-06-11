// Single owner of the in_app_purchase global purchase stream.
//
// Why this lives at app-scope and is registered as a lazy singleton:
// `InAppPurchase.instance.purchaseStream` is a process-wide stream.
// Subscribing to it from multiple widgets means each subscriber
// receives every purchase event — they'd all race to send the same
// {productId, purchaseToken} to a verifier, and we'd get N duplicate
// server calls per real purchase. The server is idempotent on
// purchaseToken so duplicates wouldn't double-credit, but they're
// wasted round-trips and the UX would flicker as N success toasts
// fire.
//
// The fix: one listener, owned by this service, started in main()
// before any UI mounts. The service dispatches each purchase to the
// verifier registered for its productId (a CF round-trip), and
// publishes a high-level outcome via its OWN broadcast stream. UI
// surfaces subscribe to the outcome stream — not to the raw
// purchaseStream — and FILTER by productId so a coin-related surface
// doesn't react to an activation outcome that happened elsewhere.
//
// Multi-product:
//   • Coin packs are consumables. Verifier returns consume-mode and
//     newBalance; client calls consumeAsync after success.
//   • Priest activation is a non-consumable. Verifier returns
//     acknowledge-mode and isActivated=true; client calls
//     acknowledgePurchase after success (NOT consume — consuming a
//     non-consumable would let the priest "buy" activation again).
//   • Bible session entry is a consumable. Same pattern as coins,
//     but verifier returns meetingLink instead of newBalance.
//
// Scope of THIS slice:
//   • Android only. iOS path is gated and shows a friendly
//     "Coming soon" — the Cloud Functions only verify Play tokens.
//
// Why we consume / acknowledge on BOTH client and server:
//   The server's verify CFs each call Android Publisher's
//   purchases.products.{consume,acknowledge} after crediting. The
//   client also calls the matching Play Billing API after the
//   server returns success. Both are needed because:
//     (a) The plugin's `completePurchase` on Android maps to
//         `acknowledgePurchase`. For consumables that is the WRONG
//         API — acknowledged-but-unconsumed consumables stay
//         "owned" by Google → ITEM_ALREADY_OWNED on the next buy.
//     (b) If the server-side call silently fails (Play API
//         transient), only the client-side call unsticks the SKU.
//   The race between the two is benign — whichever loses surfaces
//   as "already consumed" / ITEM_NOT_OWNED and is swallowed.
//
// IMPORTANT — pendingCompletePurchase guard:
//   The Android plugin sets `pendingCompletePurchase = !isAcknowledged`.
//   A restored purchase that was previously acknowledged-but-never-
//   consumed arrives with pendingCompletePurchase = false. The guard
//   stays OUT of `_safeConsume` specifically because that's the
//   exact case where we need to consume. The guard is preserved in
//   `_safeComplete` and `_safeAcknowledge` where it's correct.

import 'dart:async';
import 'dart:io' show Platform;

import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:in_app_purchase_android/in_app_purchase_android.dart';

// ─── Public types ────────────────────────────────────────────

/// What kind of outcome we emit to UI subscribers.
enum IapOutcomeKind {
  /// Server confirmed and credited (or recognised the purchase as
  /// already-processed via the idempotency check). The relevant
  /// field on `IapOutcome` (newBalance / meetingLink / isActivated)
  /// will be populated by the verifier for the corresponding
  /// product type.
  success,

  /// User cancelled the Play sheet. Not an error — UI should
  /// silently dismiss any in-flight spinner.
  canceled,

  /// Play reported the purchase as pending (deferred payment,
  /// voucher settlement, etc.). UI should show a "processing"
  /// hint and stop the spinner; the eventual success will arrive
  /// on a subsequent stream emission.
  pending,

  /// Either Play returned PurchaseStatus.error OR the server
  /// rejected the verify call. `message` is user-facing.
  error,

  /// Play / store is unavailable on this device (no Play Services,
  /// iOS without StoreKit config, emulator without billing). UI
  /// should fall back to a friendly "Coming soon" / "Try again
  /// later" message and not offer a retry.
  unavailable,
}

/// Result emitted on the outcomes broadcast stream. Field
/// population is product-type-specific:
///   • Coin purchase success → `newBalance` set.
///   • Priest activation success → `isActivated` set.
///   • Bible session success → `meetingLink` set.
///   • Error / cancel / pending / unavailable → those three are
///     null; `message` carries any user-facing text.
class IapOutcome {
  final IapOutcomeKind kind;
  final String? productId;
  final int? newBalance;
  final String? message;
  final String? meetingLink;
  final bool? isActivated;

  const IapOutcome._({
    required this.kind,
    this.productId,
    this.newBalance,
    this.message,
    this.meetingLink,
    this.isActivated,
  });

  bool get isSuccess => kind == IapOutcomeKind.success;
}

/// What to do on Play after a successful server-side credit.
///   • `consume` — releases the SKU at Google so it can be
///     repurchased (coin packs, bible session entry).
///   • `acknowledge` — keeps the SKU "owned" forever (priest
///     activation, any non-consumable). Acknowledged purchases
///     are restored on a fresh install via `restorePurchases`.
enum IapConsumeMode { consume, acknowledge }

/// Carrier for what a verifier hands back to IapService. The
/// verifier owns the server-side concerns (which CF to call, what
/// to do with the returned shape); this struct is the bridge that
/// lets IapService decide which fields to populate on the outcome
/// and whether to consume vs acknowledge on Play.
class IapVerifyResult {
  final IapConsumeMode consumeMode;
  final int? newBalance;
  final String? meetingLink;
  final bool? isActivated;

  const IapVerifyResult({
    required this.consumeMode,
    this.newBalance,
    this.meetingLink,
    this.isActivated,
  });
}

/// One verifier per SKU. Calls its domain's CF, returns the
/// IapVerifyResult, THROWS on failure — `_verifyAndEmit`'s
/// FirebaseFunctionsException / TimeoutException / generic catch
/// blocks are the single place all verifier failures get
/// classified into terminal vs transient.
///
/// `sessionId` is the optional per-product context — currently used
/// only by the Bible verifier, which requires it (the CF needs the
/// session to credit). `_verifyAndEmit` extracts it from the
/// purchase's `obfuscatedAccountId` (Android `applicationUserName`
/// set at buy time). Coin and activation verifiers ignore it.
/// Adding it as an optional named parameter is purely additive on
/// the typedef — closures that already accepted only productId +
/// purchaseToken need a one-line signature update with sessionId
/// ignored.
typedef IapVerifier = Future<IapVerifyResult> Function({
  required String productId,
  required String purchaseToken,
  String? sessionId,
});

class IapService {
  final InAppPurchase _iap = InAppPurchase.instance;

  StreamSubscription<List<PurchaseDetails>>? _sub;
  final StreamController<IapOutcome> _outcomes =
      StreamController<IapOutcome>.broadcast();

  bool _initialised = false;
  bool _storeAvailable = false;

  // ProductDetails cache. The wallet page queries up-front so the
  // pack tiles can show localized store prices instead of falling
  // back to the Firestore INR price. Cached at service scope so the
  // recharge sheet (a different surface) doesn't re-query.
  final Map<String, ProductDetails> _productCache = {};

  // Per-productId verifier registry. Populated by DI after both
  // this service and each per-domain repository are constructed
  // (see injection_container.dart). Exact-match keying — no regex
  // — because the catalogue is a fixed allowlist (IapProducts).
  // A purchase whose productId is missing here is treated as
  // unknown-and-terminal (see `_verifyAndEmit`) so it doesn't
  // loop forever on every app launch.
  final Map<String, IapVerifier> _verifiers = {};

  IapService();

  /// Final outcomes after the server round-trip. UI subscribes here.
  Stream<IapOutcome> get outcomes => _outcomes.stream;

  /// True when the device has a working Play Billing connection.
  /// iOS returns false in this slice by design (server cannot
  /// verify StoreKit receipts yet).
  bool get isStoreAvailable => _storeAvailable;

  /// Register a verifier for a specific SKU. Call after DI has
  /// constructed both this service and the verifier's owning
  /// repository. Idempotent — re-registering replaces the prior
  /// verifier.
  void registerVerifier(String productId, IapVerifier verifier) {
    _verifiers[productId] = verifier;
  }

  /// Initialise the global listener. MUST be called exactly once,
  /// before any UI tries to buy. Idempotent — safe to call twice.
  Future<void> init() async {
    if (_initialised) return;
    _initialised = true;

    // Hard gate: iOS does not have a server verifier yet. We still
    // construct the service so `outcomes` is a valid stream UI can
    // listen to without null-checks, but every buy attempt will
    // synthesise an `unavailable` outcome.
    if (!Platform.isAndroid) {
      _storeAvailable = false;
      return;
    }

    try {
      _storeAvailable = await _iap.isAvailable();
    } catch (e) {
      debugPrint('[Iap] isAvailable check failed: $e');
      _storeAvailable = false;
    }
    if (!_storeAvailable) return;

    // Subscribe FIRST so any purchases pushed by the restore call
    // below land on our handler. The plugin's _purchaseUpdatedController
    // only emits on (a) real-time PurchasesUpdatedListener callbacks
    // from launchBillingFlow, or (b) explicit restorePurchases()
    // calls — subscription alone does NOT trigger re-delivery.
    _sub = _iap.purchaseStream.listen(
      _onPurchasesUpdated,
      onDone: () => _sub?.cancel(),
      onError: (Object e) {
        debugPrint('[Iap] purchaseStream error: $e');
      },
    );

    // Pull any unconsumed/unacknowledged purchases through the
    // stream so they can be verified + credited + finalised.
    // Critical for two scenarios:
    //   1. App-kill mid-purchase — the user paid, app died before
    //      we could verify, Google still considers the SKU "owned"
    //      until we consume/acknowledge.
    //   2. Server-side credit failed (e.g. misconfigured secret) on
    //      an earlier build — Google has an unconsumed purchase,
    //      our DB has no record, the user sees ITEM_ALREADY_OWNED
    //      on every retry until we explicitly ask Google for the
    //      pending tokens here.
    // queryPurchases only returns active entries, so this is a
    // no-op once the user has no stuck purchases.
    try {
      await _iap.restorePurchases();
    } catch (e) {
      debugPrint('[Iap] restorePurchases failed (will retry on next '
          'app launch): $e');
    }
  }

  /// Best-effort product query. Caches in-memory. Returns an empty
  /// map on store-unavailable.
  Future<Map<String, ProductDetails>> queryProducts(
    Set<String> productIds,
  ) async {
    if (!_storeAvailable) return const {};
    final missing = productIds.where((id) => !_productCache.containsKey(id));
    if (missing.isEmpty) {
      return {
        for (final id in productIds)
          if (_productCache[id] != null) id: _productCache[id]!,
      };
    }
    try {
      final response = await _iap.queryProductDetails(missing.toSet());
      for (final p in response.productDetails) {
        _productCache[p.id] = p;
      }
      // `notFoundIDs` means the SKU isn't defined / active in Play
      // Console for this build's package name. We don't poison the
      // cache with a sentinel — the caller falls back to the
      // Firestore INR price. Logging it loudly so launch ops can
      // diagnose a missing Play product faster than a 3-star review.
      if (response.notFoundIDs.isNotEmpty) {
        debugPrint(
          '[Iap] queryProducts: not found in store: ${response.notFoundIDs}',
        );
      }
    } catch (e) {
      debugPrint('[Iap] queryProducts failed: $e');
    }
    return {
      for (final id in productIds)
        if (_productCache[id] != null) id: _productCache[id]!,
    };
  }

  /// Starts a consumable purchase (coin packs, bible session entry).
  /// Returns true if the buy was dispatched to the store; false if
  /// the store is unavailable or the buy threw.
  ///
  /// `autoConsume: false` is critical — without it the Android
  /// plugin auto-consumes the purchase before we verify with the
  /// server, which both invalidates the token (verify would fail)
  /// and leaves Google with "no idea this token even existed" if
  /// our server later wants to consume it. We want the server to
  /// be the authority on whether to grant + consume.
  ///
  /// `applicationUserName` is forwarded to the plugin as the Play
  /// `obfuscatedAccountId`. Used by the Bible flow to encode the
  /// sessionId on the purchase itself — survives app crashes and
  /// restored deliveries, so `_verifyAndEmit` can route credit to
  /// the right session on recovery. Coins don't pass it (null →
  /// no-op at Play's side).
  Future<bool> buyConsumable(
    ProductDetails product, {
    String? applicationUserName,
  }) async {
    if (!_storeAvailable) {
      _outcomes.add(const IapOutcome._(kind: IapOutcomeKind.unavailable));
      return false;
    }
    try {
      final purchaseParam = PurchaseParam(
        productDetails: product,
        applicationUserName: applicationUserName,
      );
      return await _iap.buyConsumable(
        purchaseParam: purchaseParam,
        autoConsume: false,
      );
    } catch (e) {
      debugPrint('[Iap] buyConsumable threw: $e');
      _outcomes.add(IapOutcome._(
        kind: IapOutcomeKind.error,
        productId: product.id,
        message: "Couldn't open the Play sheet. Please try again.",
      ));
      return false;
    }
  }

  /// Starts a non-consumable purchase (priest activation). Returns
  /// true if the buy was dispatched to the store; false if the
  /// store is unavailable or the buy threw.
  ///
  /// Mirrors `buyConsumable` exactly, but underlying call is
  /// `_iap.buyNonConsumable` so Play's local-purchase tracking
  /// treats the SKU as a permanent entitlement instead of a
  /// repurchasable consumable. The corresponding post-credit
  /// finalisation is `_safeAcknowledge` (NOT `_safeConsume`) —
  /// dispatched in `_verifyAndEmit` based on the verifier's
  /// returned `IapConsumeMode`.
  Future<bool> buyNonConsumable(ProductDetails product) async {
    if (!_storeAvailable) {
      _outcomes.add(const IapOutcome._(kind: IapOutcomeKind.unavailable));
      return false;
    }
    try {
      final purchaseParam = PurchaseParam(productDetails: product);
      return await _iap.buyNonConsumable(purchaseParam: purchaseParam);
    } catch (e) {
      debugPrint('[Iap] buyNonConsumable threw: $e');
      _outcomes.add(IapOutcome._(
        kind: IapOutcomeKind.error,
        productId: product.id,
        message: "Couldn't open the Play sheet. Please try again.",
      ));
      return false;
    }
  }

  // ── The single purchase listener. ──────────────────────────

  Future<void> _onPurchasesUpdated(List<PurchaseDetails> purchases) async {
    for (final purchase in purchases) {
      await _handleSinglePurchase(purchase);
    }
  }

  Future<void> _handleSinglePurchase(PurchaseDetails purchase) async {
    switch (purchase.status) {
      case PurchaseStatus.pending:
        _outcomes.add(IapOutcome._(
          kind: IapOutcomeKind.pending,
          productId: purchase.productID,
        ));
        return;

      case PurchaseStatus.canceled:
        _outcomes.add(IapOutcome._(
          kind: IapOutcomeKind.canceled,
          productId: purchase.productID,
        ));
        // Canceled purchases still want completePurchase to clear
        // the local pending flag — see plugin docs.
        await _safeComplete(purchase);
        return;

      case PurchaseStatus.error:
        final msg = purchase.error?.message ??
            "The purchase couldn't be completed.";
        _outcomes.add(IapOutcome._(
          kind: IapOutcomeKind.error,
          productId: purchase.productID,
          message: msg,
        ));
        await _safeComplete(purchase);
        return;

      case PurchaseStatus.purchased:
      case PurchaseStatus.restored:
        await _verifyAndEmit(purchase);
        return;
    }
  }

  Future<void> _verifyAndEmit(PurchaseDetails purchase) async {
    // The Play purchase token used by the Android Publisher API
    // lives on `verificationData.serverVerificationData`. `purchaseID`
    // is the Play orderId (e.g. "GPA.XXXX-…") and is NOT what the
    // server-side verify call wants.
    final token = purchase.verificationData.serverVerificationData;
    final productId = purchase.productID;

    if (token.isEmpty) {
      _outcomes.add(IapOutcome._(
        kind: IapOutcomeKind.error,
        productId: productId,
        message: "Missing purchase token from store.",
      ));
      await _safeComplete(purchase);
      return;
    }

    final verifier = _verifiers[productId];
    if (verifier == null) {
      // Unknown product — no domain registered a verifier for this
      // SKU. Terminal so the purchase doesn't loop on every app
      // launch. The most likely cause is a Play Console SKU that
      // the current client version doesn't know about yet (e.g. a
      // newly launched product whose client constants haven't
      // shipped), so the user-facing copy hints at the fix.
      debugPrint('[Iap] no verifier registered for productId="$productId"');
      _outcomes.add(IapOutcome._(
        kind: IapOutcomeKind.error,
        productId: productId,
        message: "This product isn't supported by your app version. "
            "Please update and try again.",
      ));
      await _safeComplete(purchase);
      return;
    }

    // Extract Play's obfuscatedAccountId (Android — set via
    // PurchaseParam.applicationUserName at buy time). The Bible
    // verifier needs the sessionId persisted with the purchase so
    // that an app-crash-and-restore-purchases round-trip still
    // credits the right session on recovery. Android-only because
    // the plugin's iOS path doesn't expose an equivalent field;
    // coins and activation pass null here either way (they ignore
    // sessionId).
    String? sessionId;
    if (Platform.isAndroid && purchase is GooglePlayPurchaseDetails) {
      sessionId = purchase.billingClientPurchase.obfuscatedAccountId;
    }

    try {
      final result = await verifier(
        productId: productId,
        purchaseToken: token,
        sessionId: sessionId,
      );
      _outcomes.add(IapOutcome._(
        kind: IapOutcomeKind.success,
        productId: productId,
        newBalance: result.newBalance,
        meetingLink: result.meetingLink,
        isActivated: result.isActivated,
      ));
      // Finalise on Play per the verifier's verdict. Consume for
      // consumables (coins, bible), acknowledge for non-consumables
      // (priest activation). See the IapConsumeMode comment for
      // why these are distinct.
      switch (result.consumeMode) {
        case IapConsumeMode.consume:
          await _safeConsume(purchase);
          break;
        case IapConsumeMode.acknowledge:
          await _safeAcknowledge(purchase);
          break;
      }
    } on FirebaseFunctionsException catch (e) {
      // Terminal server-side rejections won't fix themselves on
      // retry. Clear the queue so the user doesn't see the same
      // error every app launch. Transient codes (internal,
      // unavailable, unauthenticated) deliberately leave the
      // purchase on the queue so the next launch re-verifies.
      //
      // All `failed-precondition` codes are now terminal — multiple
      // product types share this path, and a server-side
      // precondition failure means the server definitively rejected
      // this token (e.g. unknown_or_inactive_pack for coins,
      // purchase_not_valid for any product, "Unsupported product
      // for activation" for activation). Safe for coins because
      // every failed-precondition path the coin CF emits is genuinely
      // terminal.
      final terminal = e.code == 'invalid-argument' ||
          e.code == 'permission-denied' ||
          e.code == 'not-found' ||
          e.code == 'failed-precondition';
      _outcomes.add(IapOutcome._(
        kind: IapOutcomeKind.error,
        productId: productId,
        message: _humaniseCfError(e),
      ));
      if (terminal) {
        await _safeComplete(purchase);
      }
    } on TimeoutException {
      _outcomes.add(IapOutcome._(
        kind: IapOutcomeKind.error,
        productId: productId,
        message: "Verification timed out. We'll retry when you reopen the app.",
      ));
      // Don't complete — retry on next launch.
    } catch (e) {
      debugPrint('[Iap] verify failed (transient): $e');
      _outcomes.add(IapOutcome._(
        kind: IapOutcomeKind.error,
        productId: productId,
        message: "Couldn't verify your purchase. We'll retry shortly.",
      ));
      // Don't complete — retry on next launch.
    }
  }

  // Success-on-CONSUMABLE path: explicit Play Billing consume.
  // Required because the plugin's `completePurchase` on Android
  // only ACKNOWLEDGES for an autoConsume:false buy — and
  // acknowledged-but-unconsumed consumables stay "owned" by
  // Google, producing ITEM_ALREADY_OWNED on the next buy of the
  // same SKU. Falls back to completePurchase on non-Android (iOS
  // coin / bible purchases are gated until the StoreKit slice
  // ships).
  //
  // Critical: we DO NOT early-exit on `!pendingCompletePurchase`
  // here. The Android plugin computes
  // `pendingCompletePurchase = !isAcknowledged` — so a restored
  // purchase that was previously acknowledged-but-never-consumed
  // (the exact state every early broken-secret test left behind)
  // arrives with `pendingCompletePurchase == false`. Honouring
  // that guard would short-circuit the very rescue this method
  // exists to perform. consumeAsync is idempotent server-side —
  // a duplicate call on an already-consumed token errors with
  // "already consumed", which the catch below swallows.
  Future<void> _safeConsume(PurchaseDetails purchase) async {
    try {
      if (Platform.isAndroid) {
        final addition =
            _iap.getPlatformAddition<InAppPurchaseAndroidPlatformAddition>();
        await addition.consumePurchase(purchase);
        return;
      }
      if (purchase.pendingCompletePurchase) {
        await _iap.completePurchase(purchase);
      }
    } catch (e) {
      debugPrint('[Iap] consume failed (likely server-already-consumed '
          'race or already-consumed token, safe to ignore): $e');
    }
  }

  // Success-on-NON-CONSUMABLE path: acknowledge only. The plugin's
  // `completePurchase` IS the acknowledge call on Android, which is
  // the right API for a non-consumable. We KEEP the
  // `pendingCompletePurchase` guard here — for non-consumables it
  // tracks acknowledge state correctly, and skipping the no-op
  // round-trip is a small win. `_safeConsume` is the special case
  // that has to ignore the guard, not this method.
  Future<void> _safeAcknowledge(PurchaseDetails purchase) async {
    if (!purchase.pendingCompletePurchase) return;
    try {
      await _iap.completePurchase(purchase);
    } catch (e) {
      debugPrint('[Iap] acknowledge failed (safe to ignore): $e');
    }
  }

  // Non-success path: just clear the plugin's local pending flag.
  // Calling consume here would be wrong — there's nothing valid to
  // consume on a canceled / errored purchase.
  Future<void> _safeComplete(PurchaseDetails purchase) async {
    if (!purchase.pendingCompletePurchase) return;
    try {
      await _iap.completePurchase(purchase);
    } catch (e) {
      debugPrint('[Iap] completePurchase failed: $e');
    }
  }

  String _humaniseCfError(FirebaseFunctionsException e) {
    switch (e.code) {
      case 'unauthenticated':
        return 'Please sign out and sign in, then retry your purchase.';
      case 'failed-precondition':
        if (e.message == 'purchase_not_valid') {
          return 'Google Play could not validate this purchase.';
        }
        if (e.message == 'unknown_or_inactive_pack') {
          return 'This coin pack is temporarily unavailable. Contact support.';
        }
        return e.message ?? 'Purchase rejected by server.';
      case 'invalid-argument':
        return 'Purchase data was incomplete. Contact support if charged.';
      case 'internal':
        return "Couldn't credit your coins right now. We'll retry shortly.";
      default:
        return e.message ?? 'Verification failed.';
    }
  }

  Future<void> dispose() async {
    await _sub?.cancel();
    await _outcomes.close();
  }
}
