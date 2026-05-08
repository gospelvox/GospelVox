// In-app notification model — read-only on the client.
//
// Cloud Functions are the only writers (createSessionRequest,
// approveRejectPriest, requestWithdrawal, sessionWatchdog,
// verifyActivationFee, sendFollowUp, etc). The shape here mirrors
// what those functions actually write, so renaming a field on either
// side will surface as a runtime miss the next time we render.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

class NotificationModel {
  final String id;
  final String type;
  final String title;
  final String body;
  final bool isRead;
  final String? sessionId;
  final DateTime? createdAt;

  // Set only by the sendFollowUp CF — every other writer leaves
  // these null. The user-side notifications page uses priestId for
  // the deep link to /user/priest/:id, and priestPhotoUrl to swap
  // the icon square for an actual avatar on follow_up cards.
  final String? priestId;
  final String? priestName;
  final String? priestPhotoUrl;

  // Set only by notifyPriestMissedRequest CF. Stored separately
  // from priest* fields above so the inbox renderer can show the
  // *user's* avatar on a missed-request card without confusing it
  // with a priest-sent message. sessionType is 'chat' or 'voice'
  // and drives the "Tried to call/chat" copy.
  final String? requesterId;
  final String? requesterName;
  final String? requesterPhotoUrl;
  final String? sessionType;

  // Set only when the priest dismisses a missed_request from the
  // My Users page. Both fields are null until dismiss; once set,
  // isRead is also true so the doc no longer shows up in the
  // unread missed-request stream.
  final String? dismissReason;
  final DateTime? dismissedAt;

  // For type='priest_message' only: the CF writes false when the
  // recipient had muted the sender at send time. The user-side
  // inbox filters these out so a muted priest's messages never
  // surface; the priest still sees them in their own outbox.
  final bool delivered;

  const NotificationModel({
    required this.id,
    required this.type,
    required this.title,
    required this.body,
    required this.isRead,
    this.sessionId,
    this.createdAt,
    this.priestId,
    this.priestName,
    this.priestPhotoUrl,
    this.requesterId,
    this.requesterName,
    this.requesterPhotoUrl,
    this.sessionType,
    this.dismissReason,
    this.dismissedAt,
    this.delivered = true,
  });

  factory NotificationModel.fromFirestore(
    String docId,
    Map<String, dynamic> data,
  ) {
    final ts = data['createdAt'];
    final dts = data['dismissedAt'];
    return NotificationModel(
      id: docId,
      type: data['type'] as String? ?? '',
      title: data['title'] as String? ?? '',
      body: data['body'] as String? ?? '',
      isRead: data['isRead'] as bool? ?? false,
      sessionId: data['sessionId'] as String?,
      createdAt: ts is Timestamp ? ts.toDate() : null,
      priestId: data['priestId'] as String?,
      priestName: data['priestName'] as String?,
      priestPhotoUrl: data['priestPhotoUrl'] as String?,
      requesterId: data['requesterId'] as String?,
      requesterName: data['requesterName'] as String?,
      requesterPhotoUrl: data['requesterPhotoUrl'] as String?,
      sessionType: data['sessionType'] as String?,
      dismissReason: data['dismissReason'] as String?,
      dismissedAt: dts is Timestamp ? dts.toDate() : null,
      // Default true so legacy follow_up docs (pre-dating mute)
      // continue to render correctly — they were always delivered.
      delivered: data['delivered'] as bool? ?? true,
    );
  }

  NotificationModel copyWith({bool? isRead}) {
    return NotificationModel(
      id: id,
      type: type,
      title: title,
      body: body,
      isRead: isRead ?? this.isRead,
      sessionId: sessionId,
      createdAt: createdAt,
      priestId: priestId,
      priestName: priestName,
      priestPhotoUrl: priestPhotoUrl,
      requesterId: requesterId,
      requesterName: requesterName,
      requesterPhotoUrl: requesterPhotoUrl,
      sessionType: sessionType,
      dismissReason: dismissReason,
      dismissedAt: dismissedAt,
      delivered: delivered,
    );
  }

  // Type-aware icon. Each branch matches a Cloud Function writer.
  IconData get icon {
    switch (type) {
      case 'session_request':
        return Icons.chat_bubble_outline_rounded;
      case 'session_ended':
        return Icons.access_time_rounded;
      case 'application_approved':
        return Icons.check_circle_outline_rounded;
      case 'application_rejected':
        return Icons.cancel_outlined;
      case 'account_activated':
        return Icons.verified_outlined;
      case 'account_suspended':
        return Icons.block_outlined;
      case 'account_reactivated':
        return Icons.refresh_rounded;
      case 'withdrawal_processed':
        return Icons.account_balance_outlined;
      case 'withdrawal_sent':
        return Icons.payments_outlined;
      case 'follow_up':
      case 'priest_message':
        return Icons.message_outlined;
      case 'missed_request':
        return Icons.phone_missed_rounded;
      default:
        return Icons.notifications_none_rounded;
    }
  }

  // Type-aware accent. Hard-coded literals (rather than AppColors)
  // because we want green/red/gold to always read as "outcome",
  // independent of any palette tweak.
  Color get accentColor {
    switch (type) {
      case 'application_approved':
      case 'account_activated':
      case 'account_reactivated':
        return const Color(0xFF2E7D4F);
      case 'application_rejected':
      case 'account_suspended':
        return const Color(0xFFC03828);
      case 'withdrawal_processed':
      case 'withdrawal_sent':
        return const Color(0xFFC8902A);
      case 'session_request':
      case 'follow_up':
      case 'priest_message':
        return const Color(0xFF6B3A2A);
      case 'missed_request':
        // Same amber as the dashboard badge + My Users dot — the
        // "you missed something" colour the priest learns to scan
        // for across surfaces.
        return const Color(0xFFC8902A);
      default:
        return const Color(0xFF6B3A2A);
    }
  }

  String get timeAgo {
    final ts = createdAt;
    if (ts == null) return '';
    final diff = DateTime.now().difference(ts);
    if (diff.inSeconds < 60) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    final d = ts.day.toString().padLeft(2, '0');
    final m = ts.month.toString().padLeft(2, '0');
    return '$d/$m/${ts.year}';
  }
}
