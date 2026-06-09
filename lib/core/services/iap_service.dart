// Single owner of the in_app_purchase global purchase stream.
//
// Why this lives at app-scope and is registered as a lazy singleton:
// `InAppPurchase.instance.purchaseStream` is a process-wide stream.
// Subscribing to it from multiple widgets means each subscriber
// receives every purchase event — they'd all race to send the same
// {productId, purchaseToken} to verifyCoinPurchase, and we'd get N
// duplicate server calls per real purchase. The server is
// idempotent on purchaseToken so duplicates wouldn't double-credit,
// but they're wasted round-trips and the UX would flicker as N
// success toasts fire.
//
// The fix: one listener, owned by this service, started in main()
// before any UI mounts. The service does the server round-trip and
// publishes a high-level outcome via its OWN broadcast stream.
// Wallet page + recharge sheet subscribe to the outcome stream,
// not to the raw purchase stream.
//
// Scope of THIS slice:
//   • Android only. iOS path is gated and shows a friendly
//     "Coming soon" — the Cloud Function only verifies Play tokens.
//   • Consumables only (coin packs). Non-consumables / subscriptions
//     are not modelled.
//
// Why we consume on BOTH client and server:
//   The server's verifyCoinPurchase calls Android Publisher's
//   purchases.products.consume after crediting. The client also
//   calls Play Billing's consumeAsync after the server returns
//   success. Both are needed because:
//     (a) The plugin's `completePurchase` on Android only
//         ACKNOWLEDGES — for an autoConsume:false buy it does NOT
//         consume. Acknowledged-but-unconsumed consumables stay
//         "owned" by Google → ITEM_ALREADY_OWNED on the next buy
//         of the same SKU.
//     (b) If the server-side consume silently fails (Play API
//         transient), only the client-side consume unsticks the
//         purchase.
//   The race between the two consumes is benign — whichever loses
//   surfaces as "already consumed" / ITEM_NOT_OWNED and is
//   swallowed at the call site.

import 'dart:async';
import 'dart:io' show Platform;

import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:in_app_purchase_android/in_app_purchase_android.dart';
import 'package:gospel_vox/features/user/wallet/data/wallet_repository.dart';

// ─── Public types ────────────────────────────────────────────

/// What kind of outcome we emit to UI subscribers.
enum IapOutcomeKind {
  /// Server confirmed and credited (or recognised the purchase as
  /// already-credited via the idempotency check). `coinsBalance` is
  /// the authoritative new balance to display.
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

class IapOutcome {
  final IapOutcomeKind kind;
  final String? productId;
  final int? newBalance;
  final String? message;

  const IapOutcome._({
    required this.kind,
    this.productId,
    this.newBalance,
    this.message,
  });

  bool get isSuccess => kind == IapOutcomeKind.success;
}

class IapService {
  final InAppPurchase _iap = InAppPurchase.instance;
  final WalletRepository _wallet;

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

  IapService(this._wallet);

  /// Final outcomes after the server round-trip. UI subscribes here.
  Stream<IapOutcome> get outcomes => _outcomes.stream;

  /// True when the device has a working Play Billing connection.
  /// iOS returns false in this slice by design (server cannot
  /// verify StoreKit receipts yet).
  bool get isStoreAvailable => _storeAvailable;

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

    // Pull any unconsumed purchases through the stream so they can
    // be verified + credited + consumed. Critical for two scenarios:
    //   1. App-kill mid-purchase — the user paid, app died before
    //      we could verify, Google still considers the SKU "owned"
    //      until we consume.
    //   2. Server-side credit failed (e.g. misconfigured secret) on
    //      an earlier build — Google has an unconsumed purchase,
    //      our DB has no record, the user sees ITEM_ALREADY_OWNED
    //      on every retry until we explicitly ask Google for the
    //      pending tokens here.
    // queryPurchases only returns active/unconsumed entries, so this
    // is a no-op once the user has no stuck purchases.
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

  /// Starts a consumable purchase. Returns true if the buy was
  /// dispatched to the store; false if the store is unavailable or
  /// the SKU isn't loaded.
  ///
  /// `autoConsume: false` is critical — without it the Android
  /// plugin auto-consumes the purchase before we verify with the
  /// server, which both invalidates the token (verify would fail)
  /// and grants Google "no idea this token even existed" if our
  /// server later wants to consume it. We want the server to be the
  /// authority on whether to grant + consume.
  Future<bool> buyConsumable(ProductDetails product) async {
    if (!_storeAvailable) {
      _outcomes.add(const IapOutcome._(kind: IapOutcomeKind.unavailable));
      return false;
    }
    try {
      // Base `PurchaseParam` is platform-routed correctly by the
      // plugin on Android — no need for the Android-specific
      // GooglePlayPurchaseParam wrapper since we're not setting
      // obfuscatedAccountId or any subscription-change params for a
      // simple consumable.
      final purchaseParam = PurchaseParam(productDetails: product);
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

    try {
      final result = await _wallet.verifyCoinPurchase(
        productId: productId,
        purchaseToken: token,
      );
      _outcomes.add(IapOutcome._(
        kind: IapOutcomeKind.success,
        productId: productId,
        newBalance: result.newBalance,
      ));
      // Terminal success — consume the purchase at Play so the
      // consumable is repurchasable AND the local pending flag is
      // cleared. `_safeConsume` uses the Android-specific consume
      // (acknowledge alone leaves the SKU "owned" and produces
      // ITEM_ALREADY_OWNED on the next buy). A race with the
      // server-side consumeProduct manifests as ITEM_NOT_OWNED on
      // whichever loses — swallowed inside.
      await _safeConsume(purchase);
    } on FirebaseFunctionsException catch (e) {
      // Terminal server-side rejections that won't fix themselves
      // on retry. Clear the queue so the user doesn't see the same
      // error every app launch. Transient codes (internal,
      // unavailable, unauthenticated) deliberately leave the
      // purchase on the queue so the next launch re-verifies.
      final terminal = e.code == 'invalid-argument' ||
          e.code == 'permission-denied' ||
          e.code == 'not-found' ||
          (e.code == 'failed-precondition' &&
              (e.message == 'purchase_not_valid' ||
                  e.message == 'unknown_or_inactive_pack'));
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

  // Success path: explicit Play Billing consume. Required because
  // the plugin's `completePurchase` on Android only ACKNOWLEDGES
  // for an autoConsume:false buy — and acknowledged-but-unconsumed
  // consumables stay "owned" by Google, producing ITEM_ALREADY_OWNED
  // on the next buy of the same SKU. Falls back to completePurchase
  // on non-Android (iOS coin purchases are gated until the StoreKit
  // slice ships). The ITEM_NOT_OWNED race with the server-side
  // consumeProduct is swallowed — Google considers the purchase
  // consumed either way.
  Future<void> _safeConsume(PurchaseDetails purchase) async {
    if (!purchase.pendingCompletePurchase) return;
    try {
      if (Platform.isAndroid) {
        final addition =
            _iap.getPlatformAddition<InAppPurchaseAndroidPlatformAddition>();
        await addition.consumePurchase(purchase);
        return;
      }
      await _iap.completePurchase(purchase);
    } catch (e) {
      debugPrint('[Iap] consume failed (likely server-already-consumed '
          'race, safe to ignore): $e');
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
