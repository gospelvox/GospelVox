// Shape of a priest document as the admin sees it.
//
// We deliberately mirror the Firestore field names verbatim rather
// than renaming in Dart — the admin list has to cross-reference data
// with the priests' own registration flow often, and matching names
// makes grep/debugging trivial.

import 'package:cloud_firestore/cloud_firestore.dart';

import 'package:gospel_vox/core/utils/date_format.dart' as df;

class SpeakerModel {
  final String uid;
  final String fullName;
  final String email;
  final String phone;
  final String photoUrl;
  final String denomination;
  final String subDenomination;
  final String churchName;
  final String diocese;
  final String location;
  final int yearsOfExperience;
  final String bio;
  final List<String> languages;
  final List<String> specializations;
  final String idProofUrl;
  final String certificateUrl;
  // pending | approved | rejected | suspended
  final String status;
  final bool isActivated;
  // Availability — set automatically by app lifecycle (foregrounded
  // => online, backgrounded for 2+ minutes => offline). A Cloud
  // Function watchdog also flips it off if the heartbeat stops.
  // Defaults to false so an older doc without the field reads as
  // offline rather than "mysteriously available".
  final bool isOnline;
  // Opt-in "don't send me requests right now" flag toggled from
  // Settings > Pause Requests. A busy priest is still online (so
  // they can finish an ongoing session and respond at leisure) but
  // users see them as "Busy" and can't open new sessions with them.
  final bool isBusy;
  // ID of the currently-live Bible session this priest is teaching.
  // Set atomically by the startBibleSession CF, cleared by
  // completeBibleSession AND the bibleSessionReminders auto-complete
  // cron. While this field is non-empty (and not past its deadline,
  // see bibleSessionLockedUntil below), the priest is treated as
  // "In Bible Session" everywhere — distinct from `isBusy` so a
  // priest who's both in a chat session AND a bible session
  // doesn't get prematurely unlocked when one of the two ends.
  final String liveBibleSessionId;
  // Wall-clock deadline at which the bible-session lock auto-releases
  // (startedAt + durationMinutes + 15min). Acts as the self-healing
  // guard for the lock — if every server-side clear path fails, the
  // moment this timestamp passes both the client UI and the
  // createSessionRequest CF treat the priest as free again. Without
  // this fallback a stuck `liveBibleSessionId` could otherwise block
  // a priest from receiving any session request indefinitely.
  final DateTime? bibleSessionLockedUntil;
  final double walletBalance;
  final double totalEarnings;
  final int totalSessions;
  final double rating;
  final int reviewCount;
  final DateTime? createdAt;
  final String? rejectionReason;

  const SpeakerModel({
    required this.uid,
    required this.fullName,
    required this.email,
    required this.phone,
    required this.photoUrl,
    required this.denomination,
    required this.subDenomination,
    required this.churchName,
    required this.diocese,
    required this.location,
    required this.yearsOfExperience,
    required this.bio,
    required this.languages,
    required this.specializations,
    required this.idProofUrl,
    required this.certificateUrl,
    required this.status,
    required this.isActivated,
    this.isOnline = false,
    this.isBusy = false,
    this.liveBibleSessionId = '',
    this.bibleSessionLockedUntil,
    required this.walletBalance,
    required this.totalEarnings,
    required this.totalSessions,
    required this.rating,
    required this.reviewCount,
    this.createdAt,
    this.rejectionReason,
  });

  // Hand-rolled because `createdAt` is a serverTimestamp that can
  // arrive as null during the brief window between the client
  // writing and the server stamping (pending writes in the cache).
  // Naive `as Timestamp` panics there; we fall back to null.
  factory SpeakerModel.fromFirestore(Map<String, dynamic> data) {
    return SpeakerModel(
      uid: data['uid'] as String? ?? '',
      fullName: data['fullName'] as String? ?? '',
      email: data['email'] as String? ?? '',
      phone: data['phone'] as String? ?? '',
      photoUrl: data['photoUrl'] as String? ?? '',
      denomination: data['denomination'] as String? ?? '',
      subDenomination: data['subDenomination'] as String? ?? '',
      churchName: data['churchName'] as String? ?? '',
      diocese: data['diocese'] as String? ?? '',
      location: data['location'] as String? ?? '',
      yearsOfExperience:
          (data['yearsOfExperience'] as num?)?.toInt() ?? 0,
      bio: data['bio'] as String? ?? '',
      languages:
          List<String>.from(data['languages'] as List? ?? const []),
      specializations:
          List<String>.from(data['specializations'] as List? ?? const []),
      idProofUrl: data['idProofUrl'] as String? ?? '',
      certificateUrl: data['certificateUrl'] as String? ?? '',
      status: data['status'] as String? ?? 'pending',
      isActivated: data['isActivated'] as bool? ?? false,
      isOnline: data['isOnline'] as bool? ?? false,
      isBusy: data['isBusy'] as bool? ?? false,
      // Defaults to empty string when the field is missing — older
      // priest docs created before this lock existed simply read as
      // "not in bible session", no migration needed.
      liveBibleSessionId: data['liveBibleSessionId'] as String? ?? '',
      bibleSessionLockedUntil:
          data['bibleSessionLockedUntil'] is Timestamp
              ? (data['bibleSessionLockedUntil'] as Timestamp).toDate()
              : null,
      walletBalance:
          (data['walletBalance'] as num?)?.toDouble() ?? 0,
      totalEarnings:
          (data['totalEarnings'] as num?)?.toDouble() ?? 0,
      totalSessions: (data['totalSessions'] as num?)?.toInt() ?? 0,
      rating: (data['rating'] as num?)?.toDouble() ?? 0,
      reviewCount: (data['reviewCount'] as num?)?.toInt() ?? 0,
      createdAt: data['createdAt'] is Timestamp
          ? (data['createdAt'] as Timestamp).toDate()
          : null,
      rejectionReason: data['rejectionReason'] as String?,
    );
  }

  String get timeAgo => df.formatTimeAgo(createdAt);

  bool get hasPhoto => photoUrl.isNotEmpty;
  bool get hasIdProof => idProofUrl.isNotEmpty;
  bool get hasCertificate => certificateUrl.isNotEmpty;

  // True when the priest is currently teaching a live Bible session.
  //
  // The check has TWO independent signals and BOTH must agree for the
  // lock to be considered held:
  //
  //   1. liveBibleSessionId is set — the server-side lock flag,
  //      written atomically by startBibleSession and cleared by
  //      completeBibleSession / the auto-complete cron.
  //
  //   2. bibleSessionLockedUntil is either missing OR still in the
  //      future. This is the self-healing escape hatch: if every
  //      server-side clear path fails and the field gets stuck, the
  //      moment the deadline passes the UI auto-releases the priest
  //      without waiting for any CF to run. A priest can never be
  //      permanently locked into "In Bible Session" by a buggy CF.
  //
  // Conservative on missing-deadline: if liveBibleSessionId is set
  // but bibleSessionLockedUntil is null (older docs, partial writes),
  // we trust the lock flag and treat the priest as in-session. The
  // server CF gate enforces the same precedence.
  bool get isInBibleSession {
    if (liveBibleSessionId.isEmpty) return false;
    final until = bibleSessionLockedUntil;
    if (until != null && !DateTime.now().isBefore(until)) return false;
    return true;
  }

  // "Truly available to take a new session" — online, not paused
  // (isBusy false), AND not teaching a Bible session. Adding the
  // isInBibleSession term here cascades the gate to EVERY caller of
  // isAvailable (home feed Available-Now section, priest profile
  // Call/Chat buttons, etc.) without each one having to remember
  // to add the check separately.
  bool get isAvailable => isOnline && !isBusy && !isInBibleSession;

  // First letter of name for the avatar fallback. Trimmed because
  // leading whitespace in user-submitted data would render as a
  // blank avatar otherwise.
  String get initial {
    final trimmed = fullName.trim();
    if (trimmed.isEmpty) return '?';
    return trimmed.substring(0, 1).toUpperCase();
  }
}
