// States for the admin withdrawal monitor. Sealed so the builder
// has to render every variant — a missing case surfaces at analyze
// time rather than as a blank screen in prod.

import 'package:gospel_vox/features/admin/withdrawals/data/admin_withdrawal_model.dart';

sealed class AdminWithdrawalsState {}

class AdminWithdrawalsInitial extends AdminWithdrawalsState {}

class AdminWithdrawalsLoading extends AdminWithdrawalsState {}

class AdminWithdrawalsLoaded extends AdminWithdrawalsState {
  final List<AdminWithdrawalModel> withdrawals;
  // 'pending' | 'processing' | 'paid' | 'on_hold' | 'blocked' | 'all'
  final String filter;
  // Tab badge counts kept in state so the header stays truthful
  // while the user is on a non-active tab.
  final int pendingCount;
  final int processingCount;
  final int paidCount;
  final int onHoldCount;
  final int blockedCount;
  // Per-row in-flight markers so the card can show a spinner on
  // exactly the button the admin tapped, while the rest of the
  // list stays interactive.
  final String? actionInProgressId;
  // 'processing' | 'sent' | 'on_hold' | 'blocked'
  final String? actionInProgressKind;

  AdminWithdrawalsLoaded({
    required this.withdrawals,
    required this.filter,
    this.pendingCount = 0,
    this.processingCount = 0,
    this.paidCount = 0,
    this.onHoldCount = 0,
    this.blockedCount = 0,
    this.actionInProgressId,
    this.actionInProgressKind,
  });

  AdminWithdrawalsLoaded copyWith({
    List<AdminWithdrawalModel>? withdrawals,
    String? filter,
    int? pendingCount,
    int? processingCount,
    int? paidCount,
    int? onHoldCount,
    int? blockedCount,
    String? actionInProgressId,
    String? actionInProgressKind,
    bool clearAction = false,
  }) {
    return AdminWithdrawalsLoaded(
      withdrawals: withdrawals ?? this.withdrawals,
      filter: filter ?? this.filter,
      pendingCount: pendingCount ?? this.pendingCount,
      processingCount: processingCount ?? this.processingCount,
      paidCount: paidCount ?? this.paidCount,
      onHoldCount: onHoldCount ?? this.onHoldCount,
      blockedCount: blockedCount ?? this.blockedCount,
      actionInProgressId: clearAction
          ? null
          : (actionInProgressId ?? this.actionInProgressId),
      actionInProgressKind: clearAction
          ? null
          : (actionInProgressKind ?? this.actionInProgressKind),
    );
  }
}

class AdminWithdrawalsError extends AdminWithdrawalsState {
  final String message;
  AdminWithdrawalsError(this.message);
}
