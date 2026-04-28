// Shape of a sessions/{id} doc as the admin monitor surfaces it.
//
// We keep this distinct from the shared SessionModel because the
// admin view cares about a different slice — denormalised names,
// platform-revenue derivation, status labels — while not needing
// the typing-presence and transcript hooks the chat side uses.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import 'package:gospel_vox/core/theme/admin_colors.dart';

class AdminSessionModel {
  final String id;
  final String userId;
  final String priestId;
  final String userName;
  final String priestName;
  // chat | voice
  final String type;
  // pending | active | completed | declined | expired | cancelled
  final String status;
  final int ratePerMinute;
  final int durationMinutes;
  final int totalCharged;
  final int priestEarnings;
  final int commissionPercent;
  final double? userRating;
  final String? userFeedback;
  final String? endReason;
  final DateTime? createdAt;
  final DateTime? startedAt;
  final DateTime? endedAt;

  const AdminSessionModel({
    required this.id,
    required this.userId,
    required this.priestId,
    required this.userName,
    required this.priestName,
    required this.type,
    required this.status,
    required this.ratePerMinute,
    required this.durationMinutes,
    required this.totalCharged,
    required this.priestEarnings,
    required this.commissionPercent,
    this.userRating,
    this.userFeedback,
    this.endReason,
    this.createdAt,
    this.startedAt,
    this.endedAt,
  });

  factory AdminSessionModel.fromFirestore(
    String docId,
    Map<String, dynamic> data,
  ) {
    DateTime? ts(dynamic v) =>
        v is Timestamp ? v.toDate() : null;

    return AdminSessionModel(
      id: docId,
      userId: data['userId'] as String? ?? '',
      priestId: data['priestId'] as String? ?? '',
      userName: data['userName'] as String? ?? 'Unknown',
      priestName: data['priestName'] as String? ?? 'Unknown',
      type: data['type'] as String? ?? 'chat',
      status: data['status'] as String? ?? '',
      ratePerMinute: (data['ratePerMinute'] as num?)?.toInt() ?? 0,
      durationMinutes: (data['durationMinutes'] as num?)?.toInt() ?? 0,
      totalCharged: (data['totalCharged'] as num?)?.toInt() ?? 0,
      priestEarnings: (data['priestEarnings'] as num?)?.toInt() ?? 0,
      commissionPercent:
          (data['commissionPercent'] as num?)?.toInt() ?? 0,
      userRating: (data['userRating'] as num?)?.toDouble(),
      userFeedback: data['userFeedback'] as String?,
      endReason: data['endReason'] as String?,
      createdAt: ts(data['createdAt']),
      startedAt: ts(data['startedAt']),
      endedAt: ts(data['endedAt']),
    );
  }

  // Charged minus what the priest takes home — what stays with the
  // platform after commission. Derived rather than stored because
  // priestEarnings is the canonical CF-written figure and the diff
  // is always exact.
  int get platformRevenue => totalCharged - priestEarnings;

  String get statusLabel {
    switch (status) {
      case 'active':
        return 'Live';
      case 'completed':
        return 'Completed';
      case 'pending':
        return 'Pending';
      case 'declined':
        return 'Declined';
      case 'expired':
        return 'Expired';
      case 'cancelled':
        return 'Cancelled';
      default:
        return status.isEmpty ? 'Unknown' : status;
    }
  }

  // Foreground colour for the status pill. Backgrounds in the UI
  // derive from these by mixing 14% alpha so the pill stays readable
  // without us managing a parallel bg-token for every status.
  Color get statusColor {
    switch (status) {
      case 'active':
        return AdminColors.success;
      case 'completed':
        return AdminColors.textMuted;
      case 'pending':
        return AdminColors.warning;
      case 'declined':
        return AdminColors.error;
      case 'expired':
      case 'cancelled':
        return AdminColors.textLight;
      default:
        return AdminColors.textMuted;
    }
  }

  // "Apr 27, 2:30 PM" — same format as the wallet so admins
  // jumping between screens read timestamps the same way.
  String get formattedDate {
    final d = createdAt;
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
}
