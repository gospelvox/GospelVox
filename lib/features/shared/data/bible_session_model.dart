// Bible session domain models. Used by both the user-side browse/
// register flow and the priest-side create/manage flow — kept in
// `shared/` so neither side reaches into the other's feature folder.
//
// `BibleRegistration` lives in `bible_sessions/{sessionId}/registrations/{uid}`.
// The doc id IS the user's uid, which lets a free registration be a
// single-doc create (rules-friendly: `auth.uid == regId`).

import 'package:cloud_firestore/cloud_firestore.dart';

class BibleSessionModel {
  final String id;
  final String priestId;
  final String priestName;
  final String priestPhotoUrl;
  final String title;
  final String description;
  // "Deep Study" / "Daily Living" / "Youth" / "Prayer" /
  // "Practical Guide" / "Worship" / "Testimony"
  final String category;
  final DateTime? scheduledAt;
  final int durationMinutes;
  // 0 means unlimited.
  final int maxParticipants;
  // Price in rupees (the Razorpay amount is price * 100 paise).
  final int price;
  final String meetingLink;
  // "upcoming" / "live" / "completed" / "cancelled"
  final String status;
  final int registrationCount;
  final DateTime? createdAt;

  const BibleSessionModel({
    required this.id,
    required this.priestId,
    required this.priestName,
    required this.priestPhotoUrl,
    required this.title,
    required this.description,
    required this.category,
    this.scheduledAt,
    required this.durationMinutes,
    required this.maxParticipants,
    required this.price,
    required this.meetingLink,
    required this.status,
    required this.registrationCount,
    this.createdAt,
  });

  factory BibleSessionModel.fromFirestore(
      String docId, Map<String, dynamic> data) {
    return BibleSessionModel(
      id: docId,
      priestId: data['priestId'] as String? ?? '',
      priestName: data['priestName'] as String? ?? '',
      priestPhotoUrl: data['priestPhotoUrl'] as String? ?? '',
      title: data['title'] as String? ?? '',
      description: data['description'] as String? ?? '',
      category: data['category'] as String? ?? '',
      scheduledAt: data['scheduledAt'] is Timestamp
          ? (data['scheduledAt'] as Timestamp).toDate()
          : null,
      durationMinutes: (data['durationMinutes'] as num?)?.toInt() ?? 60,
      maxParticipants: (data['maxParticipants'] as num?)?.toInt() ?? 0,
      price: (data['price'] as num?)?.toInt() ?? 0,
      meetingLink: data['meetingLink'] as String? ?? '',
      status: data['status'] as String? ?? 'upcoming',
      registrationCount:
          (data['registrationCount'] as num?)?.toInt() ?? 0,
      createdAt: data['createdAt'] is Timestamp
          ? (data['createdAt'] as Timestamp).toDate()
          : null,
    );
  }

  bool get hasLink => meetingLink.isNotEmpty;
  bool get isUpcoming => status == 'upcoming';
  bool get isCancelled => status == 'cancelled';
  bool get isCompleted => status == 'completed';
  bool get isFull =>
      maxParticipants > 0 && registrationCount >= maxParticipants;

  bool get isInPast =>
      scheduledAt != null && scheduledAt!.isBefore(DateTime.now());

  int get daysUntil {
    if (scheduledAt == null) return 0;
    return scheduledAt!.difference(DateTime.now()).inDays;
  }

  int get hoursUntil {
    if (scheduledAt == null) return 0;
    return scheduledAt!.difference(DateTime.now()).inHours;
  }

  int get minutesUntil {
    if (scheduledAt == null) return 0;
    return scheduledAt!.difference(DateTime.now()).inMinutes;
  }

  // True from 15 min before start through the end of the scheduled
  // duration. Drives when the user-side "Join & Pay" button appears.
  bool get isJoinWindowOpen {
    if (scheduledAt == null) return false;
    final diff = scheduledAt!.difference(DateTime.now()).inMinutes;
    return diff <= 15 && diff >= -durationMinutes;
  }

  // Priest-facing nudge to add the Meet link. Tightens as the session
  // approaches; null when the link is set or the session is closed.
  String? get linkWarning {
    if (hasLink || isCancelled || isCompleted) return null;
    if (hoursUntil <= 1) {
      return "Add meeting link NOW — session starts soon!";
    }
    if (hoursUntil <= 24) {
      return "Add meeting link — session is tomorrow";
    }
    if (daysUntil <= 3) {
      return "Add meeting link — session in $daysUntil days";
    }
    return null;
  }

  String get formattedDate {
    if (scheduledAt == null) return '';
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    final m = scheduledAt!.month;
    return '${months[m - 1]} ${scheduledAt!.day}, ${scheduledAt!.year}';
  }

  String get formattedTime {
    if (scheduledAt == null) return '';
    final h = scheduledAt!.hour;
    final hour = h > 12 ? h - 12 : (h == 0 ? 12 : h);
    final period = h >= 12 ? 'PM' : 'AM';
    final mm = scheduledAt!.minute.toString().padLeft(2, '0');
    return '$hour:$mm $period';
  }

  String get startsInText {
    if (scheduledAt == null) return '';
    final diff = scheduledAt!.difference(DateTime.now());
    if (diff.isNegative) return 'Started';
    if (diff.inDays > 0) return 'Starts in ${diff.inDays} days';
    if (diff.inHours > 0) return 'Starts in ${diff.inHours} hours';
    if (diff.inMinutes > 0) return 'Starts in ${diff.inMinutes} min';
    return 'Starting now';
  }
}

class BibleRegistration {
  final String userId;
  final String userName;
  final String userPhotoUrl;
  // "registered" / "paid" / "cancelled"
  final String status;
  final String? paymentId;
  final DateTime? registeredAt;

  const BibleRegistration({
    required this.userId,
    required this.userName,
    required this.userPhotoUrl,
    required this.status,
    this.paymentId,
    this.registeredAt,
  });

  factory BibleRegistration.fromFirestore(
      String docId, Map<String, dynamic> data) {
    return BibleRegistration(
      userId: docId,
      userName: data['userName'] as String? ?? '',
      userPhotoUrl: data['userPhotoUrl'] as String? ?? '',
      status: data['status'] as String? ?? 'registered',
      paymentId: data['paymentId'] as String?,
      registeredAt: data['registeredAt'] is Timestamp
          ? (data['registeredAt'] as Timestamp).toDate()
          : null,
    );
  }

  bool get isPaid => status == 'paid';
  bool get isRegistered => status == 'registered';
  bool get isCancelled => status == 'cancelled';
}
