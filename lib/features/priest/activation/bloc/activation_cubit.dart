// Drives the activation paywall. Two phases:
//
//   A. Load fee → ready → (priest taps Pay → client calls createOrder
//      CF → opens Razorpay) — this part lives in the page because the
//      Razorpay SDK wants its callbacks registered on the widget's
//      lifecycle, not on the cubit.
//
//   B. Razorpay success callback → verifyPayment → HMAC check
//      server-side → flip isActivated → emit Success.
//
// The cubit never talks to Razorpay directly — it's a data-flow
// orchestrator only. All device-side payment ceremony is the page's
// responsibility.

import 'dart:async';
import 'dart:io';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:gospel_vox/features/priest/activation/bloc/activation_state.dart';
import 'package:gospel_vox/features/priest/activation/data/activation_repository.dart';

// Fallback fee. Used ONLY so the UI can render "Activate for ₹500"
// while the real fee loads — the server still validates against the
// authoritative value in app_config/settings, so a tampered fallback
// cannot underpay.
const int _kFallbackFee = 500;

class ActivationCubit extends Cubit<ActivationState> {
  final ActivationRepository _repository;

  ActivationCubit(this._repository) : super(ActivationInitial());

  Future<void> loadFee() async {
    try {
      emit(ActivationLoading());
      final fee = await _repository.getActivationFee();
      if (isClosed) return;
      emit(ActivationReady(fee: fee));
    } on TimeoutException {
      if (isClosed) return;
      emit(ActivationError(
        'Taking too long. Check your connection and try again.',
        fee: _kFallbackFee,
      ));
    } on SocketException {
      if (isClosed) return;
      emit(ActivationError(
        'No internet connection. Please reconnect and try again.',
        fee: _kFallbackFee,
      ));
    } catch (e, st) {
      debugPrint('[ActivationCubit] loadFee failed: $e\n$st');
      if (isClosed) return;
      emit(ActivationError(
        'Failed to load activation details.',
        fee: _kFallbackFee,
      ));
    }
  }

  // The page flips this to true the moment the priest taps Pay (even
  // before Razorpay opens) so double-taps can't stack two checkouts.
  // Flipped back to false on payment cancel / failure / by the next
  // state transition (verifying / success / error).
  void setPaymentInProgress(bool value) {
    final current = state;
    if (current is! ActivationReady || isClosed) return;
    if (current.isPaymentInProgress == value) return;
    emit(current.copyWith(isPaymentInProgress: value));
  }

  // Asks the server to create a Razorpay order. Returns null on
  // failure — the page renders a snackbar and resets its local
  // in-progress flag.
  Future<ActivationOrder?> createOrder() async {
    try {
      return await _repository.createOrder();
    } on FirebaseFunctionsException catch (e) {
      debugPrint(
        '[ActivationCubit] createOrder CF error: '
        'code="${e.code}" message="${e.message}"',
      );
      return null;
    } on TimeoutException {
      debugPrint('[ActivationCubit] createOrder timed out');
      return null;
    } on SocketException {
      debugPrint('[ActivationCubit] createOrder offline');
      return null;
    } catch (e, st) {
      debugPrint('[ActivationCubit] createOrder failed: $e\n$st');
      return null;
    }
  }

  // Called from the page's Razorpay success callback. At this point
  // Razorpay has captured the payment — if verification fails below,
  // the priest has been charged. We flag afterCapture=true so the
  // paywall hides the Retry button (retry would double-charge).
  Future<void> verifyPayment({
    required String razorpayPaymentId,
    required String razorpayOrderId,
    required String razorpaySignature,
  }) async {
    final current = state;
    final fee = switch (current) {
      ActivationReady s => s.fee,
      ActivationVerifying s => s.fee,
      ActivationError s => s.fee,
      _ => _kFallbackFee,
    };

    try {
      if (isClosed) return;
      emit(ActivationVerifying(fee));

      await _repository.verifyPayment(
        razorpayPaymentId: razorpayPaymentId,
        razorpayOrderId: razorpayOrderId,
        razorpaySignature: razorpaySignature,
      );

      if (isClosed) return;
      emit(ActivationSuccess());
    } on TimeoutException {
      if (isClosed) return;
      emit(ActivationError(
        'Verification timed out. If your amount was debited, contact '
        'support with reference: $razorpayPaymentId',
        paymentId: razorpayPaymentId,
        fee: fee,
        afterCapture: true,
      ));
    } on SocketException {
      if (isClosed) return;
      emit(ActivationError(
        'Lost internet during verification. If your amount was '
        'debited, contact support with reference: $razorpayPaymentId',
        paymentId: razorpayPaymentId,
        fee: fee,
        afterCapture: true,
      ));
    } on FirebaseFunctionsException catch (e) {
      debugPrint(
        '[ActivationCubit] verify CF error: '
        'code="${e.code}" message="${e.message}"',
      );
      if (isClosed) return;
      emit(ActivationError(
        _humaniseCfError(e, razorpayPaymentId),
        paymentId: razorpayPaymentId,
        fee: fee,
        afterCapture: true,
      ));
    } catch (e, st) {
      debugPrint('[ActivationCubit] verify failed: $e\n$st');
      if (isClosed) return;
      emit(ActivationError(
        'Verification failed. If your amount was debited, contact '
        'support with reference: $razorpayPaymentId',
        paymentId: razorpayPaymentId,
        fee: fee,
        afterCapture: true,
      ));
    }
  }

  // Used by the page's "Retry Payment" button on the PaymentFailure
  // sheet for PRE-capture failures (Razorpay itself rejected the
  // card, user's UPI app crashed, etc). Brings the cubit back to a
  // clean Ready state so the Pay button is interactive again.
  void resetForRetry() {
    final current = state;
    final fee = switch (current) {
      ActivationReady s => s.fee,
      ActivationError s => s.fee,
      ActivationVerifying s => s.fee,
      _ => _kFallbackFee,
    };
    if (isClosed) return;
    emit(ActivationReady(fee: fee));
  }

  String _humaniseCfError(
    FirebaseFunctionsException e,
    String paymentId,
  ) {
    switch (e.code) {
      case 'permission-denied':
        return 'Payment signature mismatch. If you were charged, '
            'contact support with reference: $paymentId';
      case 'failed-precondition':
        return e.message ??
            'This activation payment is no longer valid. '
                'Reference: $paymentId';
      case 'unimplemented':
        return 'Activation is not available yet. '
            'Please contact support.';
      case 'unavailable':
        return 'Service temporarily unavailable. '
            'If charged, contact support with reference: $paymentId';
      default:
        return e.message ??
            'Verification failed. If charged, contact support '
                'with reference: $paymentId';
    }
  }
}
