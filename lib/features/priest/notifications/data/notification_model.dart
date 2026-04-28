// In-app notification model — read-only on the client.
//
// Cloud Functions are the only writers (createSessionRequest,
// approveRejectPriest, requestWithdrawal, sessionWatchdog,
// verifyActivationFee, etc). The shape here mirrors what those
// functions actually write, so renaming a field on either side
// will surface as a runtime miss the next time we render.

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

  const NotificationModel({
    required this.id,
    required this.type,
    required this.title,
    required this.body,
    required this.isRead,
    this.sessionId,
    this.createdAt,
  });

  factory NotificationModel.fromFirestore(
    String docId,
    Map<String, dynamic> data,
  ) {
    final ts = data['createdAt'];
    return NotificationModel(
      id: docId,
      type: data['type'] as String? ?? '',
      title: data['title'] as String? ?? '',
      body: data['body'] as String? ?? '',
      isRead: data['isRead'] as bool? ?? false,
      sessionId: data['sessionId'] as String?,
      createdAt: ts is Timestamp ? ts.toDate() : null,
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
        return const Color(0xFF6B3A2A);
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
