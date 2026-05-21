// In-app notification model — read-only on the client.
//
// Cloud Functions are the only writers (createSessionRequest,
// approveRejectPriest, requestWithdrawal, sessionWatchdog,
// verifyActivationFee, sendFollowUp, etc). The shape here mirrors
// what those functions actually write, so renaming a field on either
// side will surface as a runtime miss the next time we render.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:gospel_vox/core/widgets/app_icons.dart';

import 'package:gospel_vox/core/utils/date_format.dart' as df;

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
        return AppIcons.chatOutline;
      case 'session_ended':
        return AppIcons.clock;
      case 'application_approved':
        return AppIcons.checkCircleOutline;
      case 'application_rejected':
        return AppIcons.cancel;
      case 'account_activated':
        return AppIcons.badge;
      case 'account_suspended':
        return AppIcons.block;
      case 'account_reactivated':
        return AppIcons.refresh;
      case 'withdrawal_processed':
        return AppIcons.bank;
      case 'withdrawal_sent':
        return AppIcons.payments;
      case 'follow_up':
      case 'priest_message':
        return AppIcons.chatOutline;
      case 'missed_request':
        return AppIcons.phoneMissed;
      case 'review_milestone':
        return AppIcons.starFilled;
      case 'priest_reply':
        return AppIcons.reply;
      case 'report_resolved':
        return AppIcons.shield;
      // Bible session lifecycle. Each icon is paired with its
      // life-cycle meaning rather than its audience — that way the
      // inbox reads consistently whether a priest or user is
      // viewing the same notification type.
      case 'bible_session_registered':
        return AppIcons.howToReg;
      case 'bible_session_link_added':
        return AppIcons.link;
      case 'bible_session_paid':
        return AppIcons.payments;
      case 'bible_session_payment_received':
        return AppIcons.payments;
      case 'bible_session_completed':
      case 'bible_session_auto_completed':
        return AppIcons.checkCircle;
      case 'bible_session_live':
        return AppIcons.play;
      case 'bible_session_cancelled':
        return AppIcons.cancel;
      case 'bible_session_reminder_24h':
        return AppIcons.event;
      case 'bible_session_reminder_1h':
        return AppIcons.clock;
      case 'bible_session_pay_reminder':
        return Icons.payment_rounded;
      case 'bible_session_starting':
      case 'bible_session_starting_priest':
        return AppIcons.play;
      case 'bible_session_link_reminder':
        return AppIcons.warning;
      case 'bible_session_link_urgent':
        return AppIcons.error;
      case 'bible_session_golive':
        return AppIcons.mic;
      case 'bible_session_first_registration':
        return AppIcons.celebration;
      case 'bible_session_full':
        return AppIcons.group;
      default:
        return AppIcons.bellOutline;
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
      case 'review_milestone':
        // Amber gold — milestone celebrations share the warm-positive
        // accent with bible-session highlights so the inbox reads
        // them as the same "good news" tone.
        return const Color(0xFFC8902A);
      case 'priest_reply':
        // Brown — same as session_request / priest_message; reads as
        // "conversation/relationship" track of activity.
        return const Color(0xFF6B3A2A);
      case 'report_resolved':
        // Muted slate so the inbox doesn't shout — this is an
        // administrative outcome, not an alert or a celebration.
        return const Color(0xFF6B7280);
      // "Session is LIVE" stands out from the rest — same red as the
      // live badge on the cards + overlay so the inbox entry matches
      // what the user just saw on screen.
      case 'bible_session_live':
        return const Color(0xFFE53E3E);
      // Failure-toned types (cancellation, urgent-link-missing) get
      // errorRed so a quick scan of the inbox surfaces them as
      // "something needs attention" rather than blending into the
      // amber stream.
      case 'bible_session_cancelled':
      case 'bible_session_link_urgent':
        return const Color(0xFFC03828);
      // Bible session types all share the warm amber accent so the
      // inbox visually groups them as a single track of activity —
      // separate from session-request brown and approval-green.
      case 'bible_session_registered':
      case 'bible_session_link_added':
      case 'bible_session_paid':
      case 'bible_session_payment_received':
      case 'bible_session_completed':
      case 'bible_session_auto_completed':
      case 'bible_session_reminder_24h':
      case 'bible_session_reminder_1h':
      case 'bible_session_pay_reminder':
      case 'bible_session_starting':
      case 'bible_session_starting_priest':
      case 'bible_session_link_reminder':
      case 'bible_session_golive':
      case 'bible_session_first_registration':
      case 'bible_session_full':
        return const Color(0xFFC8902A);
      default:
        return const Color(0xFF6B3A2A);
    }
  }

  String get timeAgo => df.formatTimeAgo(createdAt);
}
