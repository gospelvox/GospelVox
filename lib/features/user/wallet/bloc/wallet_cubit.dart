import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:gospel_vox/features/user/wallet/bloc/wallet_state.dart';
import 'package:gospel_vox/features/user/wallet/data/wallet_repository.dart';
import 'package:gospel_vox/features/admin/settings/data/coin_pack_model.dart';

class WalletCubit extends Cubit<WalletState> {
  final WalletRepository _repository;
  StreamSubscription<int>? _balanceSubscription;

  WalletCubit(this._repository) : super(WalletInitial());

  Future<void> loadWallet(String uid) async {
    try {
      emit(WalletLoading());

      final results = await Future.wait([
        _repository.getBalance(uid),
        _repository.getCoinPacks(),
        _repository.hasEverPurchased(uid),
        _repository.getWelcomeOffer(),
      ]);

      final balance = results[0] as int;
      final packs = results[1] as List<CoinPackModel>;
      final hasPurchased = results[2] as bool;
      final welcomeOffer = results[3] as Map<String, int>;

      // Auto-select the popular pack by default
      final popularPack = packs.where((p) => p.isPopular).firstOrNull;

      emit(WalletLoaded(
        balance: balance,
        packs: packs,
        showWelcomeOffer: !hasPurchased,
        welcomeOfferCoins: welcomeOffer['coins'] ?? 100,
        welcomeOfferPrice: welcomeOffer['price'] ?? 29,
        selectedPackId: popularPack?.id,
      ));

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

  void selectPack(String packId) {
    final current = state;
    if (current is WalletLoaded) {
      emit(current.copyWith(selectedPackId: packId));
    }
  }

  // Creates a Razorpay order on the server and returns the details
  // the page needs to open the checkout sheet. We deliberately do
  // NOT emit a new state here — the page already shows a localised
  // spinner on the Pay button, and emitting WalletPurchasing would
  // unmount the pack grid behind the sheet, making cancellation feel
  // jarring. Returns null on failure; caller handles UX.
  Future<CoinOrder?> createOrder({required String packId}) async {
    try {
      return await _repository.createCoinOrder(packId: packId);
    } on TimeoutException {
      // Do NOT emit WalletError — it would replace the whole wallet
      // body with a full-screen error and destroy the pack selection.
      // The page overlays a localised snackbar instead.
      debugPrint('[Wallet] createOrder timed out');
      return null;
    } catch (e, st) {
      // Dump the raw CF error to logcat so "cloud function not deployed",
      // "Razorpay keys missing", or a cold-start timeout is diagnosable
      // without a remote debugger.
      debugPrint('[Wallet] createOrder failed: $e\n$st');
      return null;
    }
  }

  // Called after Razorpay returns a successful payment. This is the
  // critical step: payment already happened on Razorpay's side, so
  // any failure here means the user was charged but didn't get coins.
  // The paymentId is surfaced in the error message so support can
  // manually resolve these edge cases without the user having to
  // remember an opaque transaction ID.
  Future<void> verifyAndCreditPurchase({
    required String uid,
    required String razorpayPaymentId,
    required String razorpayOrderId,
    required String razorpaySignature,
    required CoinPackModel pack,
  }) async {
    // Flip the in-place purchasing flag so the processing overlay can
    // sit on top of the rendered wallet body. A separate WalletPurchasing
    // state used to tear down the pack grid and flash empty behind the
    // overlay — the flag keeps everything mounted.
    final current = state;
    if (current is WalletLoaded) {
      emit(current.copyWith(isPurchasing: true));
    }

    try {
      final newBalance = await _repository.verifyCoinPurchase(
        razorpayPaymentId: razorpayPaymentId,
        razorpayOrderId: razorpayOrderId,
        razorpaySignature: razorpaySignature,
        packId: pack.id,
      );
      // Emit success first so the page's listener can push the
      // celebratory screen using newBalance + coinsPurchased.
      if (isClosed) return;
      emit(WalletPurchaseSuccess(newBalance, pack.coins));

      // Then — CRITICAL — rebuild the WalletLoaded state before the
      // user returns from the success page. Previously this was a
      // fire-and-forget from the page listener, which left the wallet
      // stuck on WalletPurchaseSuccess (→ empty/shimmer body) if the
      // reload failed or lost the race with the user tapping
      // Continue. Awaiting it here guarantees the cubit is in
      // WalletLoaded by the time anything is popped back to.
      if (!isClosed) {
        await reloadAfterPurchase(uid);
      }
    } on TimeoutException {
      // Money almost certainly left the user's account. Show the
      // paymentId prominently so they have something actionable to
      // paste into a support message.
      if (isClosed) return;
      _clearPurchasing();
      emit(WalletError(
        "Payment verification timed out. If charged, contact support "
        "with reference: $razorpayPaymentId",
      ));
    } catch (e) {
      if (isClosed) return;
      _clearPurchasing();
      emit(WalletError(
        "Verification failed. If charged, contact support "
        "with reference: $razorpayPaymentId",
      ));
    }
  }

  // On a verification failure we want to restore the normal wallet UI
  // behind the failure sheet — if isPurchasing stays true, the user
  // sees the overlay still dimming the page after the sheet dismisses.
  void _clearPurchasing() {
    final current = state;
    if (current is WalletLoaded && current.isPurchasing) {
      emit(current.copyWith(isPurchasing: false));
    }
  }

  // Runs right after verifyCoinPurchase succeeds, to rebuild the
  // WalletLoaded state before the user returns from the success
  // screen. We refetch packs + welcome-offer eligibility because
  // the welcome offer must disappear once the user has any purchase
  // on record. The balance stream is deliberately left running —
  // cancelling it would briefly leave the AppBar chip stale.
  //
  // If this reload fails (network flap, Firestore slow, etc.) we
  // CANNOT just log-and-swallow: the cubit would stay on
  // WalletPurchaseSuccess and the wallet page body would render
  // empty/shimmer forever. Fall back to loadWallet so the user at
  // least sees a proper Loading → Loaded (or Loaded → Error with
  // retry) path instead of being stranded.
  Future<void> reloadAfterPurchase(String uid) async {
    try {
      final results = await Future.wait([
        _repository.getBalance(uid),
        _repository.getCoinPacks(),
        _repository.hasEverPurchased(uid),
        _repository.getWelcomeOffer(),
      ]);

      if (isClosed) return;

      final balance = results[0] as int;
      final packs = results[1] as List<CoinPackModel>;
      final hasPurchased = results[2] as bool;
      final welcomeOffer = results[3] as Map<String, int>;

      // Default-select the popular pack just like loadWallet does,
      // so the user returns to a fully-primed wallet (Pay button
      // active, hero number showing a real count).
      final popularPack = packs.where((p) => p.isPopular).firstOrNull;

      emit(WalletLoaded(
        balance: balance,
        packs: packs,
        showWelcomeOffer: !hasPurchased,
        welcomeOfferCoins: welcomeOffer['coins'] ?? 100,
        welcomeOfferPrice: welcomeOffer['price'] ?? 29,
        selectedPackId: popularPack?.id,
      ));
    } catch (e, st) {
      debugPrint('[Wallet] reloadAfterPurchase failed: $e\n$st');
      if (isClosed) return;
      // Fallback to a full loadWallet. It emits WalletLoading first,
      // which the page renders as the shimmer body, and then either
      // WalletLoaded or WalletError. Either is recoverable UX —
      // staying on WalletPurchaseSuccess is not.
      await loadWallet(uid);
    }
  }

  @override
  Future<void> close() {
    _balanceSubscription?.cancel();
    return super.close();
  }
}
