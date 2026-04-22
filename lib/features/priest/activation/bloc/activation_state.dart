// State machine for the activation paywall.
//
// Sealed so the page's BlocConsumer has to handle each terminal
// state explicitly — forgetting Success would silently strand the
// priest on a success-that-never-navigates.

sealed class ActivationState {}

class ActivationInitial extends ActivationState {}

class ActivationLoading extends ActivationState {}

// Fee loaded, ready for the priest to pay. `isPaymentInProgress` is
// an in-place flag — we don't transition to a separate "Purchasing"
// state because that would unmount the page layout behind Razorpay's
// checkout sheet, and the back-transition would flash empty.
class ActivationReady extends ActivationState {
  final int fee;
  final bool isPaymentInProgress;

  ActivationReady({
    required this.fee,
    this.isPaymentInProgress = false,
  });

  ActivationReady copyWith({
    int? fee,
    bool? isPaymentInProgress,
  }) {
    return ActivationReady(
      fee: fee ?? this.fee,
      isPaymentInProgress: isPaymentInProgress ?? this.isPaymentInProgress,
    );
  }
}

// The Cloud Function is performing HMAC verification and flipping
// isActivated. Separate state so the page can show a blocking
// overlay and disable any interaction.
class ActivationVerifying extends ActivationState {
  final int fee;
  ActivationVerifying(this.fee);
}

class ActivationSuccess extends ActivationState {}

// Errors always carry the fee so the paywall can keep rendering the
// right price when the page rebuilds from an error state.
class ActivationError extends ActivationState {
  final String message;
  final String? paymentId;
  final int fee;
  // true when the error happened AFTER Razorpay captured the payment
  // (i.e. verify failed). In that path the "Retry Payment" button is
  // hidden because retrying creates a duplicate charge — Razorpay has
  // no concept of "retry the same verify call".
  final bool afterCapture;

  ActivationError(
    this.message, {
    required this.fee,
    this.paymentId,
    this.afterCapture = false,
  });
}
