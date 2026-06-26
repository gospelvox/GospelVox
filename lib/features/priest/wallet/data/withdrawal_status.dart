// The shared withdrawal lifecycle — the single source of truth for
// withdrawal status, used by BOTH the priest status screen and the
// admin payout queue so the two never speak different vocabularies
// (the whole point of the rebuild: one status, same words, both sides).
//
// Wire vocabulary (the string stored on withdrawals/{id}.status):
//   pending     → "Requested"   — submitted, waiting for the admin
//   processing  → "Processing"  — admin is preparing / has sent it to
//                                 the bank (exported in a batch)
//   paid        → "Sent"        — money sent; a bank reference exists
//   on_hold     → "On Hold"     — a problem the priest needs to fix
//   blocked     → "Cancelled"   — cancelled by admin, amount refunded
//
// Why these exact wire values:
//   `pending`, `paid`, `blocked` are ALREADY what the live
//   requestWithdrawal function and the admin dashboard write/read, so
//   keeping them means zero migration and nothing existing breaks.
//   `processing` and `on_hold` are NEW, added for the rebuild — the
//   middle "we're working on it" state and the recoverable-error state
//   the old flow never had.
library;

enum WithdrawalStatus {
  // Order matters: this is the happy-path progression, so `index`
  // doubles as the timeline position for pending→processing→paid.
  pending('pending', 'Requested'),
  processing('processing', 'Processing'),
  paid('paid', 'Sent'),
  // Off-path states come after the happy path.
  onHold('on_hold', 'On Hold'),
  blocked('blocked', 'Cancelled');

  const WithdrawalStatus(this.wire, this.label);

  // The string persisted on the withdrawal doc.
  final String wire;
  // The priest- and admin-facing label.
  final String label;

  // Parse a stored status. Unknown / missing values resolve to
  // `pending` — the same safe default the existing admin model uses —
  // so a malformed record still shows as "Requested" rather than
  // vanishing. `completed` is accepted as a defensive alias for a
  // historical value that mapped to a finished payout.
  static WithdrawalStatus fromWire(String? value) {
    switch (value) {
      case 'pending':
        return WithdrawalStatus.pending;
      case 'processing':
        return WithdrawalStatus.processing;
      case 'paid':
      case 'completed':
        return WithdrawalStatus.paid;
      case 'on_hold':
        return WithdrawalStatus.onHold;
      case 'blocked':
        return WithdrawalStatus.blocked;
      default:
        return WithdrawalStatus.pending;
    }
  }

  // No further movement once paid or cancelled.
  bool get isTerminal =>
      this == WithdrawalStatus.paid || this == WithdrawalStatus.blocked;

  // The priest has to do something (fix bank details and the admin
  // re-tries). Drives the "Fix now" affordance on the status card.
  bool get needsPriestAction => this == WithdrawalStatus.onHold;

  // True for the happy-path states that sit on the Requested →
  // Processing → Sent track (used when drawing the 3-step timeline;
  // on_hold / blocked are rendered as their own single off-path state).
  bool get isOnHappyPath =>
      this == WithdrawalStatus.pending ||
      this == WithdrawalStatus.processing ||
      this == WithdrawalStatus.paid;
}
