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
    // Type-checked accessors instead of raw `as` casts. A single
    // session doc with a field written as the wrong type (e.g. a voice
    // session whose `durationMinutes` came through as the bool `false`
    // from a buggy/legacy write) used to throw a CastError —
    // "type 'bool' is not a subtype of type 'num?'" — inside the live
    // stream's .map, which took down the ENTIRE monitor with a format
    // error rather than just dropping the one bad row. These helpers
    // coerce any unexpected type to a safe default so the monitor
    // always renders.
    DateTime? ts(dynamic v) => v is Timestamp ? v.toDate() : null;
    String str(dynamic v, [String fallback = '']) =>
        v is String ? v : fallback;
    String? strOrNull(dynamic v) => v is String ? v : null;
    int intOf(dynamic v) => v is num ? v.toInt() : 0;
    double? doubleOrNull(dynamic v) => v is num ? v.toDouble() : null;

    return AdminSessionModel(
      id: docId,
      userId: str(data['userId']),
      priestId: str(data['priestId']),
      userName: str(data['userName'], 'Unknown'),
      priestName: str(data['priestName'], 'Unknown'),
      type: str(data['type'], 'chat'),
      status: str(data['status']),
      ratePerMinute: intOf(data['ratePerMinute']),
      durationMinutes: intOf(data['durationMinutes']),
      totalCharged: intOf(data['totalCharged']),
      priestEarnings: intOf(data['priestEarnings']),
      commissionPercent: intOf(data['commissionPercent']),
      userRating: doubleOrNull(data['userRating']),
      userFeedback: strOrNull(data['userFeedback']),
      endReason: strOrNull(data['endReason']),
      createdAt: ts(data['createdAt']),
      startedAt: ts(data['startedAt']),
      endedAt: ts(data['endedAt']),
    );
  }

  // Value equality over the displayed fields. This is what stops the
  // live monitor from rebuilding on every Firestore tick: an active
  // session doc gets a `lastHeartbeat` write every few seconds, but
  // that field isn't parsed into this model, so two models built
  // across a heartbeat-only change compare EQUAL. The cubit's emit
  // then no-ops (Bloc skips an emit equal to the current state) and
  // the page doesn't rebuild. Real changes (status, duration, charge)
  // still differ and still rebuild.
  @override
  bool operator ==(Object other) {
    return other is AdminSessionModel &&
        other.id == id &&
        other.userId == userId &&
        other.priestId == priestId &&
        other.userName == userName &&
        other.priestName == priestName &&
        other.type == type &&
        other.status == status &&
        other.ratePerMinute == ratePerMinute &&
        other.durationMinutes == durationMinutes &&
        other.totalCharged == totalCharged &&
        other.priestEarnings == priestEarnings &&
        other.commissionPercent == commissionPercent &&
        other.userRating == userRating &&
        other.userFeedback == userFeedback &&
        other.endReason == endReason &&
        other.createdAt == createdAt &&
        other.startedAt == startedAt &&
        other.endedAt == endedAt;
  }

  @override
  int get hashCode => Object.hash(
        id,
        userId,
        priestId,
        userName,
        priestName,
        type,
        status,
        ratePerMinute,
        durationMinutes,
        totalCharged,
        priestEarnings,
        commissionPercent,
        userRating,
        userFeedback,
        endReason,
        createdAt,
        startedAt,
        endedAt,
      );

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
