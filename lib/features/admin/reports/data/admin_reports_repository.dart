// Data access for the admin report queue.
//
// The query deliberately omits `orderBy('createdAt')`. Pairing it
// with `where('status', ...)` would require a composite Firestore
// index that no deploy script currently creates — on first run in
// prod the query throws FAILED_PRECONDITION. We sort client-side
// instead. Matches the speakers repo pattern.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'package:gospel_vox/features/admin/reports/data/report_model.dart';

class AdminReportsRepository {
  // statusFilter: null or 'all' returns every status.
  Future<List<ReportModel>> getReports({String? statusFilter}) async {
    Query<Map<String, dynamic>> query =
        FirebaseFirestore.instance.collection('reports');

    if (statusFilter != null && statusFilter != 'all') {
      query = query.where('status', isEqualTo: statusFilter);
    }

    final snap = await query.get().timeout(const Duration(seconds: 10));

    final reports = snap.docs
        .map((doc) => ReportModel.fromFirestore(doc.id, doc.data()))
        .toList();

    // Newest first; nulls sink to the bottom so a freshly filed
    // report doesn't vanish off-screen during the write-then-read
    // window where createdAt is still null in the cache.
    reports.sort((a, b) {
      final aTime = a.createdAt;
      final bTime = b.createdAt;
      if (aTime == null && bTime == null) return 0;
      if (aTime == null) return 1;
      if (bTime == null) return -1;
      return bTime.compareTo(aTime);
    });

    return reports;
  }

  // Admin resolves a report with notes. Direct Firestore write here;
  // moves to a CF in Week 6 for proper audit trail.
  Future<void> resolveReport(String reportId, String adminNotes) async {
    await FirebaseFirestore.instance
        .doc('reports/$reportId')
        .update({
          'status': 'resolved',
          'adminNotes': adminNotes,
          'resolvedAt': FieldValue.serverTimestamp(),
          'resolvedBy': FirebaseAuth.instance.currentUser?.uid ?? '',
        })
        .timeout(const Duration(seconds: 10));
  }
}
