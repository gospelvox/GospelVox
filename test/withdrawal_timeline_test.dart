// Locks the timeline rules the priest status card renders: which steps
// appear and which are done/current/upcoming for each status.
import 'package:flutter_test/flutter_test.dart';
import 'package:gospel_vox/features/priest/wallet/data/wallet_models.dart';
import 'package:gospel_vox/features/priest/wallet/data/withdrawal_status.dart';
import 'package:gospel_vox/features/priest/wallet/data/withdrawal_timeline.dart';

void main() {
  WithdrawalRecord rec(WithdrawalStatus s, {String? reason}) => WithdrawalRecord(
        id: 'x',
        amount: 1000,
        status: s,
        onHoldReason: reason,
      );

  List<WithdrawalStageState> states(List<WithdrawalStage> t) =>
      t.map((s) => s.state).toList();

  test('pending: Requested is current, rest upcoming', () {
    final t = buildWithdrawalTimeline(rec(WithdrawalStatus.pending));
    expect(t.map((s) => s.label),
        ['Requested', 'Processing', 'Sent to bank']);
    expect(states(t), [
      WithdrawalStageState.current,
      WithdrawalStageState.upcoming,
      WithdrawalStageState.upcoming,
    ]);
  });

  test('processing: Requested done, Processing current, Sent upcoming', () {
    final t = buildWithdrawalTimeline(rec(WithdrawalStatus.processing));
    expect(states(t), [
      WithdrawalStageState.done,
      WithdrawalStageState.current,
      WithdrawalStageState.upcoming,
    ]);
  });

  test('paid: all three steps done (terminal, no blinking current)', () {
    final t = buildWithdrawalTimeline(rec(WithdrawalStatus.paid));
    expect(states(t), [
      WithdrawalStageState.done,
      WithdrawalStageState.done,
      WithdrawalStageState.done,
    ]);
  });

  test('on hold: two steps, reason carried on the current step', () {
    final t = buildWithdrawalTimeline(
        rec(WithdrawalStatus.onHold, reason: 'Account number invalid'));
    expect(t.map((s) => s.label), ['Requested', 'On Hold']);
    expect(t.last.state, WithdrawalStageState.current);
    expect(t.last.note, 'Account number invalid');
  });

  test('on hold without a reason still gives a helpful default note', () {
    final t = buildWithdrawalTimeline(rec(WithdrawalStatus.onHold));
    expect(t.last.note, isNotNull);
    expect(t.last.note, isNotEmpty);
  });

  test('cancelled: Requested done + Cancelled with refund note', () {
    final t = buildWithdrawalTimeline(rec(WithdrawalStatus.blocked));
    expect(t.map((s) => s.label), ['Requested', 'Cancelled']);
    expect(t.last.note, contains('refunded'));
  });
}
