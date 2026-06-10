// Drives the activation paywall (Play Billing).
//
// Two phases:
//
//   A. loadFee() reads the authoritative ₹X fee from settings,
//      emits ActivationReady so the paywall can render
//      "Activate for ₹X".
//
//   B. activate() queries the priest_activation Play product,
//      opens the Play sheet via buyNonConsumable, and emits
//      ActivationVerifying. The global IapService listener
//      routes the verified purchase back via its outcomes
//      stream; this cubit filters by productId ==
//      priest_activation and maps the outcome to
//      ActivationSuccess / ActivationError / ActivationReady.
//
// Pattern: the cubit OWNS the IapService subscription (mirrors
// wallet_cubit). The page doesn't subscribe directly — it just
// renders state and calls activate().

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:gospel_vox/core/config/iap_products.dart';
import 'package:gospel_vox/core/services/iap_service.dart';
import 'package:gospel_vox/features/priest/activation/bloc/activation_state.dart';
import 'package:gospel_vox/features/priest/activation/data/activation_repository.dart';

// Fallback fee. Used ONLY so the UI can render "Activate for ₹500"
// while the real fee loads — the server still validates against the
// authoritative value in app_config/settings, so a tampered fallback
// cannot underpay.
const int _kFallbackFee = 500;

class ActivationCubit extends Cubit<ActivationState> {
  final ActivationRepository _repository;
  final IapService _iap;
  StreamSubscription<IapOutcome>? _iapSub;

  // Last known fee. Initialised to the fallback, updated by
  // loadFee, and read by activate() + _onIapOutcome — neither has
  // direct access to the state's fee field at the point they need
  // to emit an error/verifying state that should preserve the
  // current price.
  int _currentFee = _kFallbackFee;

  ActivationCubit(this._repository, this._iap) : super(ActivationInitial()) {
    // Subscribe for the full cubit lifetime. The page is the only
    // surface that mounts an ActivationCubit, so there's no
    // cross-cubit broadcast concern — but the productId filter in
    // _onIapOutcome still guards against coin/bible outcomes
    // bleeding in from purchases happening on other surfaces while
    // this cubit happens to be alive (e.g. priest opens activation
    // paywall, leaves it on screen, an unrelated buy fires).
    _iapSub = _iap.outcomes.listen(_onIapOutcome);
  }

  Future<void> loadFee() async {
    try {
      emit(ActivationLoading());
      final fee = await _repository.getActivationFee();
      if (isClosed) return;
      _currentFee = fee;
      emit(ActivationReady(fee: fee));
    } on TimeoutException {
      if (isClosed) return;
      emit(ActivationError(
        message: 'Taking too long. Check your connection and try again.',
        fee: _kFallbackFee,
      ));
    } on SocketException {
      if (isClosed) return;
      emit(ActivationError(
        message: 'No internet connection. Please reconnect and try again.',
        fee: _kFallbackFee,
      ));
    } catch (e, st) {
      debugPrint('[ActivationCubit] loadFee failed: $e\n$st');
      if (isClosed) return;
      emit(ActivationError(
        message: 'Failed to load activation details.',
        fee: _kFallbackFee,
      ));
    }
  }

  /// Kicks off a Play Billing non-consumable purchase for the
  /// priest_activation SKU. UI flips to verifying immediately; the
  /// final outcome lands via `_onIapOutcome` (success / pending /
  /// error / canceled).
  Future<void> activate() async {
    final fee = _currentFee;

    // Pre-check so the user gets a clear error instead of the
    // generic "unavailable" outcome that the IapService synthesises
    // on a store-unavailable buy attempt.
    if (!_iap.isStoreAvailable) {
      emit(ActivationError(
        message: "In-app purchases aren't available on this device yet. "
            "Please use an Android device with Google Play.",
        fee: fee,
      ));
      return;
    }

    emit(ActivationVerifying(fee: fee));

    final products = await _iap.queryProducts({IapProducts.priestActivation});
    if (isClosed) return;
    final product = products[IapProducts.priestActivation];
    if (product == null) {
      emit(ActivationError(
        message: "Activation isn't available right now. "
            "Please try again later.",
        fee: fee,
      ));
      return;
    }

    final started = await _iap.buyNonConsumable(product);
    if (isClosed) return;
    if (!started) {
      // Couldn't open the Play sheet — the IapService outcome
      // stream will also surface an unavailable/error outcome which
      // _onIapOutcome handles. Reset to Ready here so the button is
      // usable again immediately rather than waiting on the async
      // outcome to arrive.
      emit(ActivationReady(fee: fee));
    }
  }

  void _onIapOutcome(IapOutcome outcome) {
    if (isClosed) return;

    // Ignore outcomes for products this cubit doesn't own — coin
    // and bible purchases broadcast on the same stream. Exact
    // match because priest_activation has exactly one SKU.
    // Unavailable outcomes carry no productId so they're rejected
    // here too; the activate() pre-check already surfaced that
    // case as an ActivationError before we ever entered the
    // verifying state.
    if (outcome.productId != IapProducts.priestActivation) {
      return;
    }

    final fee = _currentFee;
    switch (outcome.kind) {
      case IapOutcomeKind.success:
        emit(ActivationSuccess());
        break;
      case IapOutcomeKind.pending:
        // Deferred payment / voucher settlement at Play. Keep the
        // verifying UI on screen — the eventual success arrives via
        // a subsequent outcome when the user completes payment
        // (potentially in another app session, triggered by
        // restorePurchases at next init).
        emit(ActivationVerifying(fee: fee));
        break;
      case IapOutcomeKind.canceled:
        emit(ActivationReady(fee: fee));
        break;
      case IapOutcomeKind.error:
        emit(ActivationError(
          message: outcome.message ?? "Activation couldn't be completed.",
          fee: fee,
        ));
        break;
      case IapOutcomeKind.unavailable:
        emit(ActivationError(
          message: "In-app purchases aren't available on this device yet.",
          fee: fee,
        ));
        break;
    }
  }

  @override
  Future<void> close() async {
    await _iapSub?.cancel();
    return super.close();
  }
}
