// Bible session domain models. Used by both the user-side browse/
// register flow and the priest-side create/manage flow — kept in
// `shared/` so neither side reaches into the other's feature folder.
//
// `BibleRegistration` lives in `bible_sessions/{sessionId}/registrations/{uid}`.
// The doc id IS the user's uid, which lets a free registration be a
// single-doc create (rules-friendly: `auth.uid == regId`).

import 'package:cloud_firestore/cloud_firestore.dart';

import 'package:gospel_vox/core/utils/date_format.dart' as df;

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
  // Set when the priest taps "Start Meeting" — the CF stamps this
  // with a server timestamp on the upcoming → live transition.
  // Drives both the "X min left" pill and the auto-complete cron
  // (started + duration + 15min buffer = deadline).
  final DateTime? startedAt;
  // Stamped by the priest's "Mark Completed" CF, by the auto-complete
  // cron, or by an admin force-complete. Used for post-session rating
  // window and history sort.
  final DateTime? completedAt;
  // Set when status flips to "cancelled" (priest cancel or admin).
  // Note: a session can ONLY be cancelled from "upcoming" — once it
  // goes live the only terminal state is "completed".
  final DateTime? cancelledAt;
  // Map of reminder-key → true, maintained by the bibleSessionReminders
  // cron so a single reminder kind only fires once per session.
  final Map<String, bool> remindersSent;

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
    this.startedAt,
    this.completedAt,
    this.cancelledAt,
    this.remindersSent = const {},
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
      startedAt: data['startedAt'] is Timestamp
          ? (data['startedAt'] as Timestamp).toDate()
          : null,
      completedAt: data['completedAt'] is Timestamp
          ? (data['completedAt'] as Timestamp).toDate()
          : null,
      cancelledAt: data['cancelledAt'] is Timestamp
          ? (data['cancelledAt'] as Timestamp).toDate()
          : null,
      // Defensive cast: Firestore can return either Map<String,dynamic>
      // or Map<Object?,Object?> depending on the SDK path that wrote
      // the doc. Copy-construct into the typed shape so downstream
      // code can use dot access without surprises.
      remindersSent: data['remindersSent'] is Map
          ? Map<String, bool>.from(
              (data['remindersSent'] as Map).map(
                (k, v) => MapEntry(k.toString(), v == true),
              ),
            )
          : const {},
    );
  }

  bool get hasLink => meetingLink.isNotEmpty;
  bool get isUpcoming => status == 'upcoming';
  bool get isLive => status == 'live';
  bool get isCancelled => status == 'cancelled';
  bool get isCompleted => status == 'completed';
  bool get isFull =>
      maxParticipants > 0 && registrationCount >= maxParticipants;

  // True only while the session is live AND we're still inside the
  // join window (duration + 15 min slack to absorb late-comers and
  // clock drift). After the deadline the auto-complete cron flips
  // the session to "completed", but if the cron is late this getter
  // is the client-side guard that hides "Join" before the doc flips.
  bool get isJoinable {
    if (!isLive || startedAt == null) return false;
    final deadline = startedAt!.toLocal().add(
          Duration(minutes: durationMinutes + 15),
        );
    return DateTime.now().isBefore(deadline);
  }

  // Time remaining in the SCHEDULED duration (not the 15-min buffer)
  // — the "X min left" pill should reflect what was promised, not
  // the grace window. Returns Duration.zero once we're past the
  // promised end, even though the session may still be joinable
  // through the buffer.
  Duration get remainingTime {
    if (!isLive || startedAt == null) return Duration.zero;
    final deadline = startedAt!.toLocal().add(
          Duration(minutes: durationMinutes),
        );
    final remaining = deadline.difference(DateTime.now());
    return remaining.isNegative ? Duration.zero : remaining;
  }

  // Compact label for the pill: "1h 30m left" / "45 min left" /
  // "Ending soon". The "Ending soon" sentinel is intentional — once
  // the promised duration elapses we want to stop counting down so
  // the UI doesn't show "0 min left" for the entire grace window.
  String get remainingTimeText {
    final mins = remainingTime.inMinutes;
    if (mins >= 60) {
      final h = mins ~/ 60;
      final m = mins % 60;
      return m == 0 ? '${h}h left' : '${h}h ${m}m left';
    }
    if (mins > 0) return '$mins min left';
    return 'Ending soon';
  }

  // scheduledAt is stored in Firestore as a UTC Timestamp. Every
  // time-arithmetic getter below normalises BOTH sides to local time
  // (`scheduledAt!.toLocal()` vs `DateTime.now()`) so the comparison
  // is an explicit local-vs-local subtraction. Dart's `.isBefore` /
  // `.difference` operate on absolute microsecondsSinceEpoch and
  // produce the right answer regardless of either side's `isUtc`
  // flag, but making the call explicit kills an entire class of
  // future "is this comparing UTC against local?" doubts in code
  // review.
  bool get isInPast =>
      scheduledAt != null &&
      scheduledAt!.toLocal().isBefore(DateTime.now());

  int get daysUntil {
    if (scheduledAt == null) return 0;
    // Calendar-day math (strip time-of-day first). `Duration.inDays`
    // truncates by 24-hour windows, so a session at 9am tomorrow
    // viewed at 6pm today is 15 hours = 0 days. Comparing dates
    // gives the human-meaningful "1 day".
    final at = scheduledAt!.toLocal();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final that = DateTime(at.year, at.month, at.day);
    return that.difference(today).inDays;
  }

  int get hoursUntil {
    if (scheduledAt == null) return 0;
    return scheduledAt!.toLocal().difference(DateTime.now()).inHours;
  }

  int get minutesUntil {
    if (scheduledAt == null) return 0;
    return scheduledAt!.toLocal().difference(DateTime.now()).inMinutes;
  }

  // True from 15 min before start through the end of the scheduled
  // duration. Drives when the user-side "Join & Pay" button appears.
  bool get isJoinWindowOpen {
    if (scheduledAt == null) return false;
    final diff =
        scheduledAt!.toLocal().difference(DateTime.now()).inMinutes;
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

  String get formattedDate => df.formatFullDate(scheduledAt);

  String get formattedTime => df.formatTime(scheduledAt);

  // Human-friendly duration label. Sub-hour values stay as "45 min";
  // exact-hour multiples render as "1 hour" / "2 hours" so the line
  // doesn't read awkwardly in tight card chips. Mixed values use the
  // compact "1h 30m" form to keep the chip width predictable.
  String get formattedDuration {
    if (durationMinutes < 60) return '$durationMinutes min';
    final hours = durationMinutes ~/ 60;
    final remaining = durationMinutes % 60;
    if (remaining == 0) {
      return hours == 1 ? '1 hour' : '$hours hours';
    }
    return '${hours}h ${remaining}m';
  }

  String get startsInText {
    if (scheduledAt == null) return '';
    final diff = scheduledAt!.toLocal().difference(DateTime.now());
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
  // Post-session feedback. `rating` is 1–5, `feedback` is optional
  // free-text. The rules permit a user to write these onto their
  // own registration doc regardless of session status, so the UI
  // is responsible for only surfacing the rating dialog after the
  // session has completed (V1 accepts the trade-off — see prompt
  // discussion).
  final int? rating;
  final String? feedback;
  final DateTime? ratedAt;

  const BibleRegistration({
    required this.userId,
    required this.userName,
    required this.userPhotoUrl,
    required this.status,
    this.paymentId,
    this.registeredAt,
    this.rating,
    this.feedback,
    this.ratedAt,
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
      rating: (data['rating'] as num?)?.toInt(),
      feedback: data['feedback'] as String?,
      ratedAt: data['ratedAt'] is Timestamp
          ? (data['ratedAt'] as Timestamp).toDate()
          : null,
    );
  }

  bool get isPaid => status == 'paid';
  bool get isRegistered => status == 'registered';
  bool get isCancelled => status == 'cancelled';
  bool get hasRated => rating != null;
}
