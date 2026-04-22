// Dashboard cubit — loads and refreshes admin dashboard data

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:gospel_vox/features/admin/dashboard/bloc/dashboard_state.dart';
import 'package:gospel_vox/features/admin/dashboard/data/dashboard_repository.dart';

class DashboardCubit extends Cubit<DashboardState> {
  final DashboardRepository _repository;

  DashboardCubit(this._repository) : super(DashboardInitial());

  Future<void> loadDashboard() async {
    try {
      emit(DashboardLoading());
      final data = await _repository.getDashboardData();
      emit(DashboardLoaded(data));
    } on TimeoutException {
      emit(DashboardError('Taking too long. Check your connection.'));
    } catch (e) {
      // Print the actual error so we can debug from terminal
      debugPrint('[Dashboard] loadDashboard FAILED: $e');
      emit(DashboardError('Failed to load dashboard.'));
    }
  }

  Future<void> refreshDashboard() async {
    try {
      final data = await _repository.getDashboardData();
      emit(DashboardLoaded(data));
    } catch (e) {
      debugPrint('[Dashboard] refreshDashboard FAILED: $e');
    }
  }
}
