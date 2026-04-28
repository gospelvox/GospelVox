// Shape of a reports/{id} doc as the admin queue surfaces it.
//
// Field names mirror Firestore verbatim — when the admin needs to
// cross-reference a report against the underlying session/user doc,
// matching names makes the grep trivial.

import 'package:cloud_firestore/cloud_firestore.dart';

class ReportModel {
  final String id;
  // uid of the user who filed the report.
  final String reportedBy;
  // uid of the user/priest being reported.
  final String reportedUser;
  final String reportedUserName;
  final String reporterName;
  final String reason;
  final String description;
  // Optional — present when the report was filed from a session
  // context, lets the admin jump from report → session detail later.
  final String? sessionId;
  // 'pending' | 'resolved'
  final String status;
  final String? adminNotes;
  final String? resolvedBy;
  final DateTime? createdAt;
  final DateTime? resolvedAt;

  const ReportModel({
    required this.id,
    required this.reportedBy,
    required this.reportedUser,
    required this.reportedUserName,
    required this.reporterName,
    required this.reason,
    required this.description,
    this.sessionId,
    required this.status,
    this.adminNotes,
    this.resolvedBy,
    this.createdAt,
    this.resolvedAt,
  });

  factory ReportModel.fromFirestore(
    String docId,
    Map<String, dynamic> data,
  ) {
    DateTime? ts(dynamic v) =>
        v is Timestamp ? v.toDate() : null;

    return ReportModel(
      id: docId,
      reportedBy: data['reportedBy'] as String? ?? '',
      reportedUser: data['reportedUser'] as String? ?? '',
      reportedUserName:
          data['reportedUserName'] as String? ?? 'Unknown',
      reporterName: data['reporterName'] as String? ?? 'Unknown',
      reason: data['reason'] as String? ?? '',
      description: data['description'] as String? ?? '',
      sessionId: data['sessionId'] as String?,
      status: data['status'] as String? ?? 'pending',
      adminNotes: data['adminNotes'] as String?,
      resolvedBy: data['resolvedBy'] as String?,
      createdAt: ts(data['createdAt']),
      resolvedAt: ts(data['resolvedAt']),
    );
  }

  bool get isPending => status == 'pending';
  bool get isResolved => status == 'resolved';

  // "Apr 27, 2:30 PM" — same format as elsewhere in admin.
  String _fmt(DateTime? d) {
    if (d == null) return '';
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    final hour =
        d.hour > 12 ? d.hour - 12 : (d.hour == 0 ? 12 : d.hour);
    final period = d.hour >= 12 ? 'PM' : 'AM';
    final minute = d.minute.toString().padLeft(2, '0');
    return '${months[d.month - 1]} ${d.day}, $hour:$minute $period';
  }

  String get formattedCreatedAt => _fmt(createdAt);
  String get formattedResolvedAt => _fmt(resolvedAt);
}
