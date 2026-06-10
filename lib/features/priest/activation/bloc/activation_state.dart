// State machine for the activation paywall.
//
// Sealed so the page's BlocConsumer has to handle each terminal
// state explicitly — forgetting Success would silently strand the
// priest on a success-that-never-navigates.

sealed class ActivationState {}

class ActivationInitial extends ActivationState {}

class ActivationLoading extends ActivationState {}

// Fee loaded, ready for the priest to tap Activate. The Play
// sheet is opened from the cubit's `activate()` method; this
// state has no in-flight flag because the verifying state
// (below) covers the "purchase dispatched, awaiting outcome"
// window.
class ActivationReady extends ActivationState {
  final int fee;

  ActivationReady({required this.fee});
}

// Either the Play sheet is open, the server is verifying the
// purchase token, or Play is sitting in `pending` (deferred
// payment). The page renders a blocking overlay and disables
// any interaction.
class ActivationVerifying extends ActivationState {
  final int fee;
  ActivationVerifying({required this.fee});
}

class ActivationSuccess extends ActivationState {}

// Errors always carry the fee so the paywall can keep rendering
// the right price when the page rebuilds from an error state.
// Unlike the legacy Razorpay flow, Play has no
// capture-before-verify race — Play won't finalise the charge
// against the user's payment method until acknowledge — so the
// "after-capture stuck screen" branching the legacy state used
// is gone. Every error is genuinely retryable.
class ActivationError extends ActivationState {
  final String message;
  final int fee;

  ActivationError({
    required this.message,
    required this.fee,
  });
}
