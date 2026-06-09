import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:gospel_vox/core/services/iap_service.dart';
import 'package:gospel_vox/features/user/wallet/bloc/wallet_state.dart';
import 'package:gospel_vox/features/user/wallet/data/wallet_repository.dart';
import 'package:gospel_vox/features/admin/settings/data/coin_pack_model.dart';

// Maps a Firestore pack doc id (pack_<N>) to the matching Play
// product id (coins_<N>). The two are kept aligned by convention:
// the admin who edits one must also edit the other in Play Console.
String? _packIdToProductId(String packId) {
  final match = RegExp(r'^pack_(\d+)$').firstMatch(packId);
  if (match == null) return null;
  return 'coins_${match.group(1)}';
}

class WalletCubit extends Cubit<WalletState> {
  final WalletRepository _repository;
  final IapService _iap;
  StreamSubscription<int>? _balanceSubscription;
  StreamSubscription<IapOutcome>? _iapOutcomeSubscription;
  Map<String, ProductDetails> _storeProducts = const {};

  WalletCubit(this._repository, this._iap) : super(WalletInitial()) {
    // Listen for IAP outcomes for the WHOLE cubit lifetime. The
    // global IapService stream may deliver an outcome triggered by
    // the recharge sheet on a different surface — we still want to
    // refresh the wallet's balance display when this cubit happens
    // to be alive.
    _iapOutcomeSubscription = _iap.outcomes.listen(_onIapOutcome);
  }

  Future<void> loadWallet(String uid) async {
    try {
      emit(WalletLoading());

      final results = await Future.wait([
        _repository.getBalance(uid),
        _repository.getCoinPacks(),
      ]);

      final balance = results[0] as int;
      final packs = results[1] as List<CoinPackModel>;

      // Auto-select the popular pack by default. The welcome-offer
      // card is hidden in this slice — the server-side welcome
      // offer was removed when we cut over to Play Billing, so
      // there's no live SKU to back it. The two welcomeOffer*
      // fields on the state are kept at safe defaults to avoid
      // touching the WalletState shape.
      final popularPack = packs.where((p) => p.isPopular).firstOrNull;

      emit(WalletLoaded(
        balance: balance,
        packs: packs,
        showWelcomeOffer: false,
        welcomeOfferCoins: 0,
        welcomeOfferPrice: 0,
        selectedPackId: popularPack?.id,
      ));

      // Fire-and-forget: query the matching Play product details so
      // future buy() calls have the ProductDetails handy. Failure
      // here is non-fatal — the wallet still renders fine without
      // store-side localized prices.
      unawaited(_warmProductCache(packs));

      // Start listening to real-time balance updates so the chip in
      // the AppBar refreshes the moment the CF finishes crediting,
      // without the user having to pull-to-refresh.
      _balanceSubscription?.cancel();
      _balanceSubscription = _repository.watchBalance(uid).listen(
        (newBalance) {
          final current = state;
          if (current is WalletLoaded) {
            emit(current.copyWith(balance: newBalance));
          }
        },
      );
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
      final productId = _packIdToProductId(p.id);
      if (productId != null) productIds.add(productId);
    }
    if (productIds.isEmpty) return;
    _storeProducts = await _iap.queryProducts(productIds);
  }

  void selectPack(String packId) {
    final current = state;
    if (current is WalletLoaded) {
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
      emit(WalletError(
        "In-app purchases aren't available on this device yet. "
        "Please use an Android device with Google Play.",
      ));
      return;
    }

    final productId = _packIdToProductId(packId);
    if (productId == null) {
      emit(WalletError("Couldn't find this coin pack. Please refresh."));
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
      emit(WalletError(
        "This coin pack isn't available in the Play Store yet. "
        "Please pick another or try again later.",
      ));
      return;
    }

    emit(current.copyWith(isPurchasing: true));
    final started = await _iap.buyConsumable(product);
    if (!started) {
      // buyConsumable already emitted an outcome (unavailable / error)
      // which the listener below handles. Reset isPurchasing so the
      // floating Pay button becomes interactive again.
      final after = state;
      if (after is WalletLoaded && after.isPurchasing) {
        emit(after.copyWith(isPurchasing: false));
      }
    }
  }

  void _onIapOutcome(IapOutcome outcome) {
    if (isClosed) return;

    switch (outcome.kind) {
      case IapOutcomeKind.success:
        final productId = outcome.productId;
        // Figure out the coin count from the productId so the
        // success page can render the celebratory "+N coins"
        // headline. Server is authoritative on newBalance; we just
        // need the delta for the UI text.
        int coinsPurchased = 0;
        final current = state;
        if (current is WalletLoaded && productId != null) {
          final match = RegExp(r'^coins_(\d+)$').firstMatch(productId);
          if (match != null) {
            coinsPurchased = int.tryParse(match.group(1) ?? '') ?? 0;
          }
          _clearPurchasing();
        }
        final newBalance = outcome.newBalance ?? 0;
        emit(WalletPurchaseSuccess(newBalance, coinsPurchased));
        break;

      case IapOutcomeKind.pending:
        // Stay on WalletLoaded so the wallet body remains; hide the
        // spinner and let the in-call UI / wallet page communicate
        // the wait via a snackbar or banner instead.
        _clearPurchasing();
        break;

      case IapOutcomeKind.canceled:
        _clearPurchasing();
        break;

      case IapOutcomeKind.error:
        _clearPurchasing();
        emit(WalletError(
          outcome.message ?? "Couldn't complete your purchase.",
        ));
        break;

      case IapOutcomeKind.unavailable:
        _clearPurchasing();
        emit(WalletError(
          "In-app purchases aren't available on this device yet.",
        ));
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

      final popularPack = packs.where((p) => p.isPopular).firstOrNull;

      emit(WalletLoaded(
        balance: balance,
        packs: packs,
        showWelcomeOffer: false,
        welcomeOfferCoins: 0,
        welcomeOfferPrice: 0,
        selectedPackId: popularPack?.id,
      ));
      unawaited(_warmProductCache(packs));
    } catch (e, st) {
      debugPrint('[Wallet] reloadAfterPurchase failed: $e\n$st');
      if (isClosed) return;
      await loadWallet(uid);
    }
  }

  @override
  Future<void> close() async {
    await _balanceSubscription?.cancel();
    await _iapOutcomeSubscription?.cancel();
    return super.close();
  }
}
