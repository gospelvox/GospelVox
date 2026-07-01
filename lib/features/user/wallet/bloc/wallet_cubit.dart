import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:gospel_vox/core/config/iap_products.dart';
import 'package:gospel_vox/core/services/iap_service.dart';
import 'package:gospel_vox/core/services/purchase_watchdog.dart';
import 'package:gospel_vox/features/user/wallet/bloc/wallet_state.dart';
import 'package:gospel_vox/features/user/wallet/data/wallet_repository.dart';
import 'package:gospel_vox/features/admin/settings/data/coin_pack_model.dart';

/// A one-shot, transient message the wallet page should surface as a
/// snackbar WITHOUT replacing the wallet body. Used for payment-time
/// problems (store unavailable, verification rejected) and "payment is
/// processing" hints — situations where the wallet must stay on screen
/// and fully interactive (pack grid + selection) rather than collapsing
/// into the full-screen error/retry view, which is reserved for a
/// genuine initial-load failure.
enum WalletNoticeKind { error, info }

class WalletNotice {
  final WalletNoticeKind kind;
  final String message;
  const WalletNotice._(this.kind, this.message);
  factory WalletNotice.error(String message) =>
      WalletNotice._(WalletNoticeKind.error, message);
  factory WalletNotice.info(String message) =>
      WalletNotice._(WalletNoticeKind.info, message);
}

class WalletCubit extends Cubit<WalletState> {
  final WalletRepository _repository;
  final IapService _iap;
  StreamSubscription<int>? _balanceSubscription;
  StreamSubscription<IapOutcome>? _iapOutcomeSubscription;
  Map<String, ProductDetails> _storeProducts = const {};

  // Side-effect channel for transient snackbars (see WalletNotice). Kept
  // separate from the state stream so a payment error / pending hint can
  // be shown while the wallet's live state stays WalletLoaded — the page
  // listens via `notices` and shows a snackbar without losing the body.
  final StreamController<WalletNotice> _notices =
      StreamController<WalletNotice>.broadcast();

  // The user's last explicit pack pick this session. Used to keep their
  // chosen pack selected across a pull-to-refresh or a post-purchase
  // reload instead of snapping back to the "popular" default.
  String? _lastSelectedPackId;

  // True only between the user tapping the wallet's own Pay button and
  // that purchase reaching a terminal outcome. Gates the celebratory
  // success screen so a background/restored purchase (or one started
  // from the recharge sheet) credits silently instead of hijacking the
  // wallet with a "Payment Successful" takeover. Pending deliberately
  // leaves this true so the eventual settlement still celebrates.
  bool _purchaseInFlight = false;

  // UI-only safety net. If Google Play never reports a terminal event
  // (most often: the user dismisses the Play sheet with the back
  // gesture, which Android doesn't always surface as a cancellation),
  // the overlay + back-button block would otherwise stay on forever.
  // 30 s sits above the 20 s verifyCoinPurchase timeout so this can
  // never fire while a real verification is in flight — see
  // PurchaseWatchdog. It only ever flips our local UI flag; it never
  // touches Play Billing or the verify CF.
  final PurchaseWatchdog _watchdog =
      PurchaseWatchdog(timeout: const Duration(seconds: 30));
  // Last uid passed to loadWallet. Cached so _onIapOutcome can fire
  // reloadAfterPurchase on success without forcing the call site to
  // thread the uid through a second time. Set on every loadWallet
  // entry; remains null only in the (impossible-in-practice) window
  // between cubit construction and the wallet page calling loadWallet
  // in its initState.
  String? _uid;

  WalletCubit(this._repository, this._iap) : super(WalletInitial()) {
    // Listen for IAP outcomes for the WHOLE cubit lifetime. The
    // global IapService stream may deliver an outcome triggered by
    // the recharge sheet on a different surface — we still want to
    // refresh the wallet's balance display when this cubit happens
    // to be alive.
    _iapOutcomeSubscription = _iap.outcomes.listen(_onIapOutcome);
  }

  /// Transient snackbar messages (payment errors / processing hints).
  /// The page subscribes and renders them without replacing the wallet
  /// body — see WalletNotice.
  Stream<WalletNotice> get notices => _notices.stream;

  // Choose which pack should be selected after a (re)load. Preference:
  // (1) the selection currently live on screen, (2) the user's last
  // explicit pick this session, (3) the popular pack as the default.
  // This stops a pull-to-refresh or post-purchase reload from silently
  // snapping the user off a pack they deliberately chose.
  String? _resolveSelection(List<CoinPackModel> packs) {
    final live = state;
    final prior =
        (live is WalletLoaded ? live.selectedPackId : null) ??
        _lastSelectedPackId;
    if (prior != null && packs.any((p) => p.id == prior)) {
      return prior;
    }
    return packs.where((p) => p.isPopular).firstOrNull?.id;
  }

  Future<void> loadWallet(String uid) async {
    _uid = uid;
    try {
      emit(WalletLoading());

      final results = await Future.wait([
        _repository.getBalance(uid),
        _repository.getCoinPacks(),
      ]);

      final balance = results[0] as int;
      final packs = results[1] as List<CoinPackModel>;

      // Keep the user's chosen pack if they had one; otherwise default
      // to the popular pack (the behaviour on a fresh first load).
      emit(
        WalletLoaded(
          balance: balance,
          packs: packs,
          selectedPackId: _resolveSelection(packs),
        ),
      );

      // Fire-and-forget: query the matching Play product details so
      // future buy() calls have the ProductDetails handy. Failure
      // here is non-fatal — the wallet still renders fine without
      // store-side localized prices.
      unawaited(_warmProductCache(packs));

      // Start listening to real-time balance updates so the chip in
      // the AppBar refreshes the moment the CF finishes crediting,
      // without the user having to pull-to-refresh.
      _balanceSubscription?.cancel();
      _balanceSubscription = _repository.watchBalance(uid).listen((newBalance) {
        final current = state;
        if (current is WalletLoaded) {
          emit(current.copyWith(balance: newBalance));
        }
      });
    } on TimeoutException {
      if (isClosed) return;
      emit(WalletError("Taking too long. Check your connection."));
    } catch (e) {
      if (isClosed) return;
      emit(WalletError("Failed to load wallet."));
    }
  }

  Future<void> _warmProductCache(List<CoinPackModel> packs) async {
    final productIds = <String>{};
    for (final p in packs) {
      final productId = IapProducts.packIdToProductId(p.id);
      if (productId != null) productIds.add(productId);
    }
    if (productIds.isEmpty) return;
    _storeProducts = await _iap.queryProducts(productIds);
  }

  void selectPack(String packId) {
    final current = state;
    if (current is WalletLoaded) {
      _lastSelectedPackId = packId;
      emit(current.copyWith(selectedPackId: packId));
    }
  }

  /// Kicks off a Play Billing purchase for the given pack. UI flips
  /// to `isPurchasing` immediately; the final outcome lands later
  /// via `_onIapOutcome` (could be success, pending, error, cancel).
  Future<void> purchasePack(String packId) async {
    final current = state;
    if (current is! WalletLoaded) return;

    if (!_iap.isStoreAvailable) {
      // Surface as a snackbar and keep the wallet on screen — a
      // store-availability problem shouldn't collapse the pack grid
      // into a full-screen error.
      _notices.add(
        WalletNotice.error(
          "In-app purchases aren't available on this device yet. "
          "Please use an Android device with Google Play.",
        ),
      );
      return;
    }

    final productId = IapProducts.packIdToProductId(packId);
    if (productId == null) {
      _notices.add(
        WalletNotice.error("Couldn't find this coin pack. Please refresh."),
      );
      return;
    }

    // Make sure we have the ProductDetails — query lazily if the
    // warm-cache call hasn't completed yet (slow network at app
    // start, etc).
    var product = _storeProducts[productId];
    if (product == null) {
      _storeProducts = {
        ..._storeProducts,
        ...await _iap.queryProducts({productId}),
      };
      product = _storeProducts[productId];
    }
    if (product == null) {
      _notices.add(
        WalletNotice.error(
          "This coin pack isn't available in the Play Store yet. "
          "Please pick another or try again later.",
        ),
      );
      return;
    }

    // Mark that THIS surface kicked off the buy, so only this purchase's
    // success drives the celebration screen (see _purchaseInFlight).
    _purchaseInFlight = true;
    emit(current.copyWith(isPurchasing: true));
    final started = await _iap.buyConsumable(product);
    if (!started) {
      // buyConsumable already emitted an outcome (unavailable / error)
      // which the listener below handles. Clear the in-flight flag and
      // reset isPurchasing so the floating Pay button becomes
      // interactive again.
      _purchaseInFlight = false;
      final after = state;
      if (after is WalletLoaded && after.isPurchasing) {
        emit(after.copyWith(isPurchasing: false));
      }
      return;
    }
    // Buy dispatched to the store. Arm the watchdog so the overlay
    // can't strand the user if no outcome ever comes back.
    _watchdog.arm(_onWatchdogExpired);
  }

  // Fired only when a buy went to the store but no IapOutcome arrived
  // within the foreground budget (the dropped-event case). Drops the
  // overlay + re-enables back, and reassures the user. The purchase,
  // if it ever completes, still credits via the live outcome listener
  // and/or restorePurchases on next launch — this is purely the UI
  // unsticking itself.
  void _onWatchdogExpired() {
    if (isClosed) return;
    _purchaseInFlight = false;
    _clearPurchasing();
    _notices.add(
      WalletNotice.info(
        "This is taking longer than expected. If you were charged, your "
        "coins will arrive shortly — no need to pay again.",
      ),
    );
  }

  void _onIapOutcome(IapOutcome outcome) {
    if (isClosed) return;

    // Ignore outcomes for products this cubit doesn't own. After
    // the IapService multi-product refactor, every surface listens
    // to the same broadcast stream — activation/bible outcomes
    // would otherwise fan out here and the success branch would
    // emit WalletPurchaseSuccess with `coinsPurchased = 0`,
    // navigating to a celebratory "+0 coins" success screen.
    //
    // `unavailable` outcomes carry no productId (they're emitted
    // globally when the store isn't available) and we still want
    // to surface those — so the null-productId case falls through
    // to the switch below intentionally.
    final pid = outcome.productId;
    if (pid != null && !IapProducts.allCoinPacks.contains(pid)) {
      return;
    }

    // A terminal/non-terminal outcome for OUR product (or a global
    // unavailable) arrived — the screen is about to update either way,
    // so stand the watchdog down.
    _watchdog.disarm();

    switch (outcome.kind) {
      case IapOutcomeKind.success:
        // Was this the buy the user just started from THIS wallet's Pay
        // button? Only then do we celebrate. A background/restored
        // purchase (verified on app launch) or one started from the
        // recharge sheet must credit silently — not throw a "Payment
        // Successful" takeover over a wallet the user is merely browsing.
        final wasUserInitiated = _purchaseInFlight;
        _purchaseInFlight = false;
        _clearPurchasing();
        final uid = _uid;

        if (wasUserInitiated) {
          // Figure out the coin count from the productId so the success
          // page can render the celebratory "+N coins" headline. Server
          // is authoritative on newBalance; we just need the delta text.
          final productId = outcome.productId;
          int coinsPurchased = 0;
          if (productId != null) {
            final match = RegExp(r'^coins_(\d+)$').firstMatch(productId);
            if (match != null) {
              coinsPurchased = int.tryParse(match.group(1) ?? '') ?? 0;
            }
          }
          emit(WalletPurchaseSuccess(outcome.newBalance ?? 0, coinsPurchased));
        }

        // Refresh balance + packs for BOTH paths. On the user-initiated
        // path this gets the wallet back to a populated WalletLoaded
        // behind the success screen (no stranded shimmer). On the
        // background/restore path it silently updates the balance with
        // no celebration and no double-handling with the recharge sheet.
        // Fire-and-forget: reloadAfterPurchase catches its own failures
        // and falls back to loadWallet internally.
        if (uid != null) {
          unawaited(reloadAfterPurchase(uid));
        }
        break;

      case IapOutcomeKind.pending:
        // Deferred/slow payment (e.g. a UPI mandate). Stay on
        // WalletLoaded, drop the overlay, and tell the user it's
        // processing — leaving _purchaseInFlight true so the eventual
        // settlement still celebrates as their purchase.
        _clearPurchasing();
        _notices.add(
          WalletNotice.info(
            "Payment is processing. Your coins will arrive shortly.",
          ),
        );
        break;

      case IapOutcomeKind.canceled:
        _purchaseInFlight = false;
        _clearPurchasing();
        break;

      case IapOutcomeKind.error:
        // A verification/store error is transient and the server is
        // idempotent — surface it as a snackbar and keep the wallet
        // (and the user's pack selection) on screen rather than
        // replacing the body with a full-screen error+retry.
        _purchaseInFlight = false;
        _clearPurchasing();
        _notices.add(
          WalletNotice.error(
            outcome.message ?? "Couldn't complete your purchase.",
          ),
        );
        break;

      case IapOutcomeKind.unavailable:
        _purchaseInFlight = false;
        _clearPurchasing();
        _notices.add(
          WalletNotice.error(
            "In-app purchases aren't available on this device yet.",
          ),
        );
        break;
    }
  }

  void _clearPurchasing() {
    final current = state;
    if (current is WalletLoaded && current.isPurchasing) {
      emit(current.copyWith(isPurchasing: false));
    }
  }

  // Re-fetches packs + balance after a purchase so the wallet view
  // is fresh when the user returns from the success screen. Kept as
  // a public API because the wallet page wires it to pull-to-
  // refresh as well as the post-success bounce-back.
  Future<void> reloadAfterPurchase(String uid) async {
    try {
      final results = await Future.wait([
        _repository.getBalance(uid),
        _repository.getCoinPacks(),
      ]);

      if (isClosed) return;

      final balance = results[0] as int;
      final packs = results[1] as List<CoinPackModel>;

      emit(
        WalletLoaded(
          balance: balance,
          packs: packs,
          selectedPackId: _resolveSelection(packs),
        ),
      );
      unawaited(_warmProductCache(packs));
    } catch (e, st) {
      debugPrint('[Wallet] reloadAfterPurchase failed: $e\n$st');
      if (isClosed) return;
      await loadWallet(uid);
    }
  }

  @override
  Future<void> close() async {
    _watchdog.disarm();
    await _balanceSubscription?.cancel();
    await _iapOutcomeSubscription?.cancel();
    await _notices.close();
    return super.close();
  }
}
