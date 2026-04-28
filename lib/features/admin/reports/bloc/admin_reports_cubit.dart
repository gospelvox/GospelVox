// Drives the admin report queue: load by tab, count pending for
// the badge, resolve from the detail sheet. Keeps the UI on the
// previously-loaded state during refetch so a tab switch never
// flashes empty under the admin's finger.

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:gospel_vox/features/admin/reports/bloc/admin_reports_state.dart';
import 'package:gospel_vox/features/admin/reports/data/admin_reports_repository.dart';

class AdminReportsCubit extends Cubit<AdminReportsState> {
  final AdminReportsRepository _repository;

  AdminReportsCubit(this._repository) : super(AdminReportsInitial());

  Future<void> loadReports(String filter) async {
    try {
      if (state is! AdminReportsLoaded) {
        emit(AdminReportsLoading());
      }

      // Pending count runs alongside the list query so the tab
      // badge stays truthful regardless of which tab is active.
      // Future.wait collapses to List<Object?>, so we keep the two
      // calls separately-typed and await both directly.
      final reportsFuture =
          _repository.getReports(statusFilter: filter);
      final countFuture = _countPending();
      final reports =
          await reportsFuture.timeout(const Duration(seconds: 12));
      final pendingCount =
          await countFuture.timeout(const Duration(seconds: 12));

      if (isClosed) return;

      emit(AdminReportsLoaded(
        reports: reports,
        filter: filter,
        pendingCount: pendingCount,
      ));
    } on TimeoutException {
      if (isClosed) return;
      if (state is AdminReportsLoaded) return;
      emit(AdminReportsError('Taking too long. Check your connection.'));
    } catch (_) {
      if (isClosed) return;
      if (state is AdminReportsLoaded) return;
      emit(AdminReportsError('Failed to load reports.'));
    }
  }

  Future<int> _countPending() async {
    try {
      final agg = await FirebaseFirestore.instance
          .collection('reports')
          .where('status', isEqualTo: 'pending')
          .count()
          .get();
      return agg.count ?? 0;
    } catch (_) {
      // A failed count shouldn't take the whole screen down — fall
      // back to 0 so the list still renders.
      return 0;
    }
  }

  // Returns true on success so the detail sheet can self-dismiss
  // and the list can refresh in one round-trip.
  Future<bool> resolveReport(String reportId, String adminNotes) async {
    final current = state;
    if (current is! AdminReportsLoaded) return false;

    emit(current.copyWith(resolvingId: reportId));

    try {
      await _repository.resolveReport(reportId, adminNotes);
      if (isClosed) return false;
      // Reload the active tab so the resolved row drops out of
      // the Pending tab (or appears in Resolved/All) without a
      // manual pull-to-refresh.
      await loadReports(current.filter);
      return true;
    } catch (_) {
      if (isClosed) return false;
      final s = state;
      if (s is AdminReportsLoaded) {
        emit(s.copyWith(clearResolvingId: true));
      }
      return false;
    }
  }
}
