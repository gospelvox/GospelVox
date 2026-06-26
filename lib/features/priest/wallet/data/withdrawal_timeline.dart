// Turns a WithdrawalRecord into the ordered list of timeline steps the
// priest status card draws. Pure logic, kept out of the widget so it's
// unit-testable and so the "what stage is this in" rules live in one
// place.
//
// Lives in its own file (not withdrawal_status.dart) to avoid an import
// cycle: wallet_models imports withdrawal_status for the enum, so
// withdrawal_status must not import wallet_models — but the timeline
// needs WithdrawalRecord, so it sits here and imports both.
library;

import 'package:gospel_vox/features/priest/wallet/data/wallet_models.dart';
import 'package:gospel_vox/features/priest/wallet/data/withdrawal_status.dart';

// Visual state of one step in the tracker.
enum WithdrawalStageState { done, current, upcoming }

class WithdrawalStage {
  final String label;
  final WithdrawalStageState state;
  // When this stage was reached. Null when not yet reached (upcoming)
  // or when the timestamp wasn't recorded.
  final DateTime? at;
  // Extra line under the stage — the on-hold reason, or the refund note
  // on a cancelled payout. Null for normal happy-path steps.
  final String? note;

  const WithdrawalStage({
    required this.label,
    required this.state,
    this.at,
    this.note,
  });
}

// Builds the steps for a record:
//   • happy path (pending/processing/paid) → 3 steps
//       Requested → Processing → Sent to bank
//   • on hold  → Requested (done) + On Hold (current, with reason)
//   • cancelled→ Requested (done) + Cancelled (current, refund note)
List<WithdrawalStage> buildWithdrawalTimeline(WithdrawalRecord r) {
  switch (r.status) {
    case WithdrawalStatus.onHold:
      return [
        WithdrawalStage(
          label: 'Requested',
          state: WithdrawalStageState.done,
          at: r.createdAt,
        ),
        WithdrawalStage(
          label: 'On Hold',
          state: WithdrawalStageState.current,
          at: r.onHoldAt,
          note: r.onHoldReason ??
              'There is an issue with this payout. Please check your '
                  'bank details.',
        ),
      ];
    case WithdrawalStatus.blocked:
      return [
        WithdrawalStage(
          label: 'Requested',
          state: WithdrawalStageState.done,
          at: r.createdAt,
        ),
        WithdrawalStage(
          label: 'Cancelled',
          state: WithdrawalStageState.current,
          at: r.blockedAt,
          note: 'The amount was refunded to your wallet.',
        ),
      ];
    case WithdrawalStatus.pending:
    case WithdrawalStatus.processing:
    case WithdrawalStatus.paid:
      // The enum is declared in happy-path order, so `index` is the
      // stage position: pending=0, processing=1, paid=2.
      final reached = r.status.index;
      WithdrawalStageState stateFor(int i) {
        if (i < reached) return WithdrawalStageState.done;
        if (i == reached) {
          // A terminal "paid" shows its final step as done (a tick), not
          // as the blinking "current" — the journey is finished.
          return r.status.isTerminal
              ? WithdrawalStageState.done
              : WithdrawalStageState.current;
        }
        return WithdrawalStageState.upcoming;
      }

      return [
        WithdrawalStage(
          label: 'Requested',
          state: stateFor(0),
          at: r.createdAt,
        ),
        WithdrawalStage(
          label: 'Processing',
          state: stateFor(1),
          at: r.processingAt,
        ),
        WithdrawalStage(
          label: 'Sent to bank',
          state: stateFor(2),
          at: r.paidAt,
        ),
      ];
  }
}
