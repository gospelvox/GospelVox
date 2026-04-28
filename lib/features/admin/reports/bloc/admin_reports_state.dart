// States for the admin report queue. Sealed so the builder has to
// render every variant — a missing case surfaces at analyze time
// rather than as a blank screen in prod.

import 'package:gospel_vox/features/admin/reports/data/report_model.dart';

sealed class AdminReportsState {}

class AdminReportsInitial extends AdminReportsState {}

class AdminReportsLoading extends AdminReportsState {}

class AdminReportsLoaded extends AdminReportsState {
  final List<ReportModel> reports;
  // 'pending' | 'resolved' | 'all'
  final String filter;
  // Pending count surfaced on the tab badge — fetched alongside
  // the active list so the badge stays truthful even when the
  // admin is on Resolved or All.
  final int pendingCount;
  // Set while a resolve action is in flight so the detail sheet
  // can disable its CTA. We don't flip back to Loading — that
  // would clobber the list — only this single field changes.
  final String? resolvingId;

  AdminReportsLoaded({
    required this.reports,
    required this.filter,
    this.pendingCount = 0,
    this.resolvingId,
  });

  AdminReportsLoaded copyWith({
    List<ReportModel>? reports,
    String? filter,
    int? pendingCount,
    String? resolvingId,
    bool clearResolvingId = false,
  }) {
    return AdminReportsLoaded(
      reports: reports ?? this.reports,
      filter: filter ?? this.filter,
      pendingCount: pendingCount ?? this.pendingCount,
      resolvingId:
          clearResolvingId ? null : (resolvingId ?? this.resolvingId),
    );
  }
}

class AdminReportsError extends AdminReportsState {
  final String message;
  AdminReportsError(this.message);
}
