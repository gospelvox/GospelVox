// Revenue states

import 'package:gospel_vox/features/admin/revenue/data/revenue_models.dart';

sealed class RevenueState {}

class RevenueInitial extends RevenueState {}

class RevenueLoading extends RevenueState {}

class RevenueLoaded extends RevenueState {
  final RevenueData data;

  RevenueLoaded(this.data);
}

class RevenueError extends RevenueState {
  final String message;

  RevenueError(this.message);
}
