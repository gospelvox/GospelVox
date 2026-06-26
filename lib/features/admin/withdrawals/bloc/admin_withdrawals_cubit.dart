// Drives the admin withdrawal monitor: a LIVE per-tab stream of the
// queue (new requests, status moves, and priest-fixed on_hold->pending
// payouts appear instantly — no leave-and-reopen), live tab-badge
// counts, and the payout lifecycle actions. Mutations don't reload —
// the stream emits the change on its own; the action only clears its
// per-row spinner.

import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:gospel_vox/features/admin/withdrawals/bloc/admin_withdrawals_state.dart';
import 'package:gospel_vox/features/admin/withdrawals/data/admin_withdrawal_model.dart';
import 'package:gospel_vox/features/admin/withdrawals/data/admin_withdrawals_repository.dart';

class AdminWithdrawalsCubit extends Cubit<AdminWithdrawalsState> {
  final AdminWithdrawalsRepository _repository;
  StreamSubscription<List<AdminWithdrawalModel>>? _sub;

  AdminWithdrawalsCubit(this._repository)
      : super(AdminWithdrawalsInitial());

  // Subscribes (or re-subscribes on a tab change) to the live queue for
  // `filter`. Returns a Future so the pull-to-refresh affordance can
  // await it, but the data is live regardless.
  Future<void> loadWithdrawals(String filter) async {
    if (state is! AdminWithdrawalsLoaded) {
      emit(AdminWithdrawalsLoading());
    }
    await _sub?.cancel();
    _sub = _repository.watchWithdrawals(statusFilter: filter).listen(
      (list) {
        if (isClosed) return;
        final cur = state;
        final loaded = cur is AdminWithdrawalsLoaded ? cur : null;
        // Emit the list IMMEDIATELY, keeping the last-known counts +
        // any in-flight per-row spinner; the badge counts refresh a
        // tick later via _refreshCounts (so the list never waits on a
        // separate aggregate query).
        emit(AdminWithdrawalsLoaded(
          withdrawals: list,
          filter: filter,
          pendingCount: loaded?.pendingCount ?? 0,
          processingCount: loaded?.processingCount ?? 0,
          paidCount: loaded?.paidCount ?? 0,
          onHoldCount: loaded?.onHoldCount ?? 0,
          blockedCount: loaded?.blockedCount ?? 0,
          actionInProgressId: loaded?.actionInProgressId,
          actionInProgressKind: loaded?.actionInProgressKind,
        ));
        _refreshCounts();
      },
      onError: (_) {
        if (isClosed) return;
        // Keep showing the last good list on a transient stream error.
        if (state is AdminWithdrawalsLoaded) return;
        emit(AdminWithdrawalsError('Failed to load withdrawals.'));
      },
    );
  }

  // Refreshes the tab-badge counts (cheap aggregate count() queries) and
  // folds them into the current loaded state without disturbing the
  // live list. Best-effort — failures leave the last counts in place.
  Future<void> _refreshCounts() async {
    try {
      final counts = await _repository.getCounts();
      if (isClosed) return;
      final cur = state;
      if (cur is AdminWithdrawalsLoaded) {
        emit(cur.copyWith(
          pendingCount: counts['pending'] ?? 0,
          processingCount: counts['processing'] ?? 0,
          paidCount: counts['paid'] ?? 0,
          onHoldCount: counts['on_hold'] ?? 0,
          blockedCount: counts['blocked'] ?? 0,
        ));
      }
    } catch (_) {
      // Keep the last counts.
    }
  }

  // Runs a single-row lifecycle mutation behind the shared double-tap
  // guard + per-row spinner. No manual reload — the live stream emits
  // the change; we only clear the spinner and refresh the badges.
  Future<bool> _runRowAction({
    required String withdrawalId,
    required String kind,
    required Future<void> Function() action,
  }) async {
    final current = state;
    if (current is! AdminWithdrawalsLoaded) return false;
    // Money-flow guard — a fast double-tap can fire twice before the
    // BlocBuilder rebuild disables the button. Load-bearing on the
    // block path (double-refund) and good hygiene everywhere.
    if (current.actionInProgressId != null) return false;

    emit(current.copyWith(
      actionInProgressId: withdrawalId,
      actionInProgressKind: kind,
    ));

    try {
      await action();
      if (isClosed) return false;
      final s = state;
      if (s is AdminWithdrawalsLoaded) {
        emit(s.copyWith(clearAction: true));
      }
      _refreshCounts();
      return true;
    } catch (_) {
      if (isClosed) return false;
      final s = state;
      if (s is AdminWithdrawalsLoaded) {
        emit(s.copyWith(clearAction: true));
      }
      return false;
    }
  }

  // Stage 2: move a payout into "processing".
  Future<bool> markProcessing(String withdrawalId) {
    return _runRowAction(
      withdrawalId: withdrawalId,
      kind: 'processing',
      action: () => _repository.markProcessing(withdrawalId),
    );
  }

  // Resolves the priest's current bank details for the Mark-Sent sheet
  // (so an on-hold correction is reflected). Null => fall back to the
  // request snapshot.
  Future<AdminWithdrawalModel?> resolveCurrentPayout(AdminWithdrawalModel w) {
    return _repository.getCurrentPriestPayout(w);
  }

  // Stage 3: record the bank reference (+ optional transaction id) and
  // mark the payout sent.
  Future<bool> markSent({
    required String withdrawalId,
    required String reference,
    String transactionId = '',
  }) {
    return _runRowAction(
      withdrawalId: withdrawalId,
      kind: 'sent',
      action: () => _repository.markSent(
        withdrawalId: withdrawalId,
        reference: reference,
        transactionId: transactionId,
      ),
    );
  }

  // Off-path: pause the payout with a reason for the priest to fix.
  Future<bool> putOnHold({
    required String withdrawalId,
    required String reason,
  }) {
    return _runRowAction(
      withdrawalId: withdrawalId,
      kind: 'on_hold',
      action: () => _repository.putOnHold(
        withdrawalId: withdrawalId,
        reason: reason,
      ),
    );
  }

  // Batch-move every exported pending row into processing after the CSV
  // has been shared with the bank. The live stream emits the moves; we
  // just refresh the badges.
  Future<bool> markProcessingBatch(List<String> withdrawalIds) async {
    final current = state;
    if (current is! AdminWithdrawalsLoaded) return false;
    if (withdrawalIds.isEmpty) return false;
    try {
      await _repository.markProcessingBatch(withdrawalIds);
      if (isClosed) return false;
      _refreshCounts();
      return true;
    } catch (_) {
      return false;
    }
  }

  // Bulk Mark-Sent — one reference for many rows (a batch UTR). The
  // live stream drops them out of Processing; we refresh the badges.
  Future<bool> markSentBatch(List<String> ids, String reference) async {
    final current = state;
    if (current is! AdminWithdrawalsLoaded) return false;
    if (ids.isEmpty) return false;
    try {
      await _repository.markSentBatch(ids, reference);
      if (isClosed) return false;
      _refreshCounts();
      return true;
    } catch (_) {
      return false;
    }
  }

  // Bulk On-Hold — one reason for many rows (e.g. a bounced batch).
  Future<bool> putOnHoldBatch(List<String> ids, String reason) async {
    final current = state;
    if (current is! AdminWithdrawalsLoaded) return false;
    if (ids.isEmpty) return false;
    try {
      await _repository.putOnHoldBatch(ids, reason);
      if (isClosed) return false;
      _refreshCounts();
      return true;
    } catch (_) {
      return false;
    }
  }

  // Block & refund — goes through the transactional, idempotent
  // blockWithdrawal Cloud Function (no double refund). Routed through
  // the shared guard; the live stream drops the row out of the queue.
  Future<bool> blockWithdrawal({
    required String withdrawalId,
    required String priestId,
    required int amount,
  }) {
    return _runRowAction(
      withdrawalId: withdrawalId,
      kind: 'blocked',
      action: () => _repository.blockWithdrawal(
        withdrawalId: withdrawalId,
        priestId: priestId,
        amount: amount,
      ),
    );
  }

  @override
  Future<void> close() async {
    await _sub?.cancel();
    return super.close();
  }
}
