// Drives the admin withdrawal monitor: load by tab, surface
// counts on every tab badge, and process payouts with two
// mutating actions (mark paid / block + refund). Reload after
// each mutation so the row drops out of the Pending tab without
// the admin having to pull-to-refresh.

import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:gospel_vox/features/admin/withdrawals/bloc/admin_withdrawals_state.dart';
import 'package:gospel_vox/features/admin/withdrawals/data/admin_withdrawals_repository.dart';

class AdminWithdrawalsCubit extends Cubit<AdminWithdrawalsState> {
  final AdminWithdrawalsRepository _repository;

  AdminWithdrawalsCubit(this._repository)
      : super(AdminWithdrawalsInitial());

  Future<void> loadWithdrawals(String filter) async {
    try {
      if (state is! AdminWithdrawalsLoaded) {
        emit(AdminWithdrawalsLoading());
      }

      final listFuture =
          _repository.getWithdrawals(statusFilter: filter);
      final countsFuture = _repository.getCounts();
      final withdrawals =
          await listFuture.timeout(const Duration(seconds: 12));
      final counts =
          await countsFuture.timeout(const Duration(seconds: 12));

      if (isClosed) return;
      emit(AdminWithdrawalsLoaded(
        withdrawals: withdrawals,
        filter: filter,
        pendingCount: counts['pending'] ?? 0,
        paidCount: counts['paid'] ?? 0,
        blockedCount: counts['blocked'] ?? 0,
      ));
    } on TimeoutException {
      if (isClosed) return;
      if (state is AdminWithdrawalsLoaded) return;
      emit(AdminWithdrawalsError(
          'Taking too long. Check your connection.'));
    } catch (_) {
      if (isClosed) return;
      if (state is AdminWithdrawalsLoaded) return;
      emit(AdminWithdrawalsError('Failed to load withdrawals.'));
    }
  }

  Future<bool> markAsPaid(String withdrawalId) async {
    final current = state;
    if (current is! AdminWithdrawalsLoaded) return false;
    // Money-flow guard. The button-disable in the UI happens via
    // a BlocBuilder rebuild which is microtask-async — a fast
    // double-tap can fire two markAsPaid calls before the rebuild
    // flushes. The type check above passes both, so without this
    // guard we'd issue two writes (harmless for paid, but symmetric
    // with the block path where double-tap would double-refund).
    if (current.actionInProgressId != null) return false;

    emit(current.copyWith(
      actionInProgressId: withdrawalId,
      actionInProgressKind: 'paid',
    ));

    try {
      await _repository.markAsPaid(withdrawalId);
      if (isClosed) return false;
      await loadWithdrawals(current.filter);
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

  Future<bool> blockWithdrawal({
    required String withdrawalId,
    required String priestId,
    required int amount,
  }) async {
    final current = state;
    if (current is! AdminWithdrawalsLoaded) return false;
    // Same guard as markAsPaid — and load-bearing on this side
    // because the block path increments the priest's wallet by
    // `amount`. A second tap that slipped through would refund
    // the priest twice.
    if (current.actionInProgressId != null) return false;

    emit(current.copyWith(
      actionInProgressId: withdrawalId,
      actionInProgressKind: 'blocked',
    ));

    try {
      await _repository.blockWithdrawal(
        withdrawalId: withdrawalId,
        priestId: priestId,
        amount: amount,
      );
      if (isClosed) return false;
      await loadWithdrawals(current.filter);
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
}
