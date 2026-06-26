// Revenue cubit — loads and refreshes the admin revenue breakdown.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:gospel_vox/features/admin/revenue/bloc/revenue_state.dart';
import 'package:gospel_vox/features/admin/revenue/data/revenue_repository.dart';

class RevenueCubit extends Cubit<RevenueState> {
  final RevenueRepository _repository;

  RevenueCubit(this._repository) : super(RevenueInitial());

  Future<void> loadRevenue() async {
    try {
      emit(RevenueLoading());
      final data = await _repository.getRevenueData();
      emit(RevenueLoaded(data));
    } on TimeoutException {
      emit(RevenueError('Taking too long. Check your connection.'));
    } catch (e) {
      debugPrint('[Revenue] loadRevenue FAILED: $e');
      emit(RevenueError('Failed to load revenue.'));
    }
  }

  Future<void> refreshRevenue() async {
    try {
      final data = await _repository.getRevenueData();
      emit(RevenueLoaded(data));
    } catch (e) {
      debugPrint('[Revenue] refreshRevenue FAILED: $e');
    }
  }
}
