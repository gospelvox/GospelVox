// Data access for the user-facing home feed of priests.
//
// We're intentionally reusing the admin SpeakerModel — the Firestore
// schema is the same regardless of which side reads it, and having
// two parallel models would quickly drift. The user-side never sees
// admin-only bits (id proof URL etc.) because the UI never renders
// them; the model is a superset, not a leak.
//
// Queries exclude the `_placeholder` doc that the registration flow
// creates to keep the priests collection non-empty on first deploy.
// Without this filter the user sees a ghost card on day one.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';

import 'package:gospel_vox/features/admin/speakers/data/speaker_model.dart';

const String _kFunctionsRegion = 'asia-south1';

class HomeRepository {
  FirebaseFirestore get _db => FirebaseFirestore.instance;

  // Real-time stream of approved + activated priests. We deliberately
  // DON'T add `.orderBy(...)` on isOnline/rating — combining that
  // with the two where-clauses requires a composite Firestore index
  // that isn't part of any deploy script, and the first run in any
  // fresh environment throws FAILED_PRECONDITION until someone
  // clicks the console link. Sorting client-side is free at the
  // realistic priest counts (<1000) and keeps the app bootstrap
  // zero-config. Same trade-off as SpeakersRepository.
  Stream<List<SpeakerModel>> watchOnlinePriests() {
    return _db
        .collection('priests')
        .where('status', isEqualTo: 'approved')
        .where('isActivated', isEqualTo: true)
        .snapshots()
        .map((snap) => _sortForFeed(snap.docs
            .where((doc) => doc.id != '_placeholder')
            .map((doc) => SpeakerModel.fromFirestore(doc.data()))
            // A priest who deleted their account vanishes from the
            // feed the instant the delete write lands — isDeleted is
            // set in the same update that flips isOnline off.
            .where((p) => !p.isDeleted)
            .toList()));
  }

  // One-shot fetch used by pull-to-refresh so the refresh spinner has
  // a concrete future to await. The stream will converge to the same
  // data moments later, but we don't want the pull gesture to dangle
  // forever waiting for a stream event that may already have fired.
  Future<List<SpeakerModel>> getPriests() async {
    final snap = await _db
        .collection('priests')
        .where('status', isEqualTo: 'approved')
        .where('isActivated', isEqualTo: true)
        .get()
        .timeout(const Duration(seconds: 10));

    return _sortForFeed(snap.docs
        .where((doc) => doc.id != '_placeholder')
        .map((doc) => SpeakerModel.fromFirestore(doc.data()))
        // Mirror the stream's deleted-priest filter so pull-to-refresh
        // can't briefly resurrect a priest the stream already dropped.
        .where((p) => !p.isDeleted)
        .toList());
  }

  // Rank buckets: available (0) first, busy (1) second, offline (2)
  // last. This matches the three-section home feed so the list is
  // already grouped correctly before the cubit splits it. Rating
  // desc within each bucket; stable UID tiebreaker so equal-rated
  // priests don't visually shuffle between snapshots.
  int _availabilityRank(SpeakerModel p) {
    if (p.isAvailable) return 0;
    if (p.isOnline && p.isBusy) return 1;
    return 2;
  }

  List<SpeakerModel> _sortForFeed(List<SpeakerModel> priests) {
    priests.sort((a, b) {
      final rankCmp = _availabilityRank(a).compareTo(_availabilityRank(b));
      if (rankCmp != 0) return rankCmp;
      final ratingCmp = b.rating.compareTo(a.rating);
      if (ratingCmp != 0) return ratingCmp;
      return a.uid.compareTo(b.uid);
    });
    return priests;
  }

  // ─── User block (per priest) ─────────────────────────────
  //
  // Block is intentionally separate from Mute:
  //   • Mute (in session_repository.setPriestMuted) suppresses free
  //     priest messages but the priest still appears in the feed and
  //     is dialable.
  //   • Block hides the priest from the feed entirely AND the server
  //     refuses createSessionRequest against them, so a user who's
  //     been harassed can fully sever the connection.
  // Per Google Play UGC policy, an "ability to block" is the second
  // pillar (alongside Report) for any app where strangers interact.

  // Live stream of the current user's blocked-priest list. Drives the
  // feed-filter inside HomeCubit and the unblock list on the Settings
  // page. Returns a Set so membership checks are O(1).
  Stream<Set<String>> watchBlockedPriestIds(String userId) {
    return _db.doc('users/$userId').snapshots().map((snap) {
      final raw = snap.data()?['blockedPriestIds'];
      if (raw is List) {
        return raw.whereType<String>().toSet();
      }
      return const <String>{};
    });
  }

  // One-shot read for the Settings page where a live stream would be
  // wasteful (the user opens the page, taps Unblock, leaves — total
  // dwell ~10s).
  Future<Set<String>> getBlockedPriestIds(String userId) async {
    final doc = await _db
        .doc('users/$userId')
        .get()
        .timeout(const Duration(seconds: 8));
    final raw = doc.data()?['blockedPriestIds'];
    if (raw is List) {
      return raw.whereType<String>().toSet();
    }
    return const <String>{};
  }

  // Adds or removes a priest from the user's block list. Idempotent —
  // arrayUnion/arrayRemove no-op if the value is already (not) there,
  // so a duplicated Block tap from a flaky network doesn't double-
  // write or hit a "already blocked" error.
  Future<void> setPriestBlocked({
    required String userId,
    required String priestId,
    required bool blocked,
  }) async {
    await _db
        .doc('users/$userId')
        .set(
          {
            'blockedPriestIds': blocked
                ? FieldValue.arrayUnion([priestId])
                : FieldValue.arrayRemove([priestId]),
          },
          SetOptions(merge: true),
        )
        .timeout(const Duration(seconds: 8));
  }

  // Detail fetch for the priest profile page. We don't stream this —
  // the profile page is short-lived and a single read keeps Firestore
  // costs predictable for a flow the user may open/close rapidly.
  Future<SpeakerModel> getPriestDetail(String uid) async {
    final doc = await _db
        .doc('priests/$uid')
        .get()
        .timeout(const Duration(seconds: 10));
    if (!doc.exists) {
      throw FirebaseException(
        plugin: 'cloud_firestore',
        code: 'not-found',
        message: 'Priest not found',
      );
    }
    final priest = SpeakerModel.fromFirestore(doc.data()!);
    // A deleted priest is treated exactly like a missing one — if a
    // stale deep-link or cached card somehow routes here, the profile
    // page shows its standard "not found" state instead of a ghost
    // "Deleted Speaker" profile.
    if (priest.isDeleted) {
      throw FirebaseException(
        plugin: 'cloud_firestore',
        code: 'not-found',
        message: 'Priest not found',
      );
    }
    return priest;
  }

  // Balance snapshot used for the pre-session affordability check.
  // A stream would be overkill — the user sees the live balance via
  // the wallet cubit elsewhere; we just need "enough right now?".
  Future<int> getUserBalance(String uid) async {
    final doc = await _db
        .doc('users/$uid')
        .get()
        .timeout(const Duration(seconds: 10));
    return (doc.data()?['coinBalance'] as num?)?.toInt() ?? 0;
  }

  // Returns (chatRate, voiceRate) from app_config/settings. Falling
  // back to sane defaults means a brand-new environment without a
  // settings doc still renders readable rate copy instead of "null/
  // min · null/min".
  Future<Map<String, int>> getSessionRates() async {
    final doc = await _db
        .doc('app_config/settings')
        .get()
        .timeout(const Duration(seconds: 10));
    final data = doc.data() ?? const <String, dynamic>{};
    return {
      'chat': (data['chatRatePerMinute'] as num?)?.toInt() ?? 10,
      'voice': (data['voiceRatePerMinute'] as num?)?.toInt() ?? 20,
    };
  }

  // Minimum cost to even start a session — one minute of chat.
  // We gate on the cheaper rate so a user with "just enough for chat"
  // can still see the Chat button enabled; the Voice button will
  // disable itself independently based on the voice-specific math.
  Future<int> getMinSessionCost() async {
    final rates = await getSessionRates();
    return rates['chat'] ?? 10;
  }

  // Recent written reviews for a priest, used by the profile page's
  // Reviews are read by trying three sources in order:
  //
  //   1. PRIMARY: the `getPublicPriestReviews` callable CF. Reads
  //      sessions with admin privileges (bypassing the rules that
  //      block other users from reading another priest's sessions
  //      directly) and returns a sanitised projection. This is the
  //      path that just works after a single function deploy — no
  //      data backfill required.
  //
  //   2. FALLBACK: the denormalized `recentReviews` array on
  //      priests/{id}, maintained by onSessionRated + replyToReview.
  //      Used when the CF call fails for any reason.
  //
  //   3. LAST RESORT: direct sessions query. Works if the rules are
  //      permissive enough OR if the caller is the priest themself.
  //      Otherwise returns empty (logged, never throws).
  Future<List<PriestReview>> getRecentReviews(
    String priestId, {
    int limit = 200,
  }) async {
    // --- 1. callable CF (primary) ---
    try {
      final callable = FirebaseFunctions.instanceFor(
        region: _kFunctionsRegion,
      ).httpsCallable('getPublicPriestReviews');
      final result = await callable
          .call<Map<String, dynamic>>({
            'priestId': priestId,
            'limit': limit,
          })
          .timeout(const Duration(seconds: 10));
      final list = (result.data['reviews'] as List?) ?? const [];
      final reviews = list
          .whereType<Map>()
          .map((m) => Map<String, dynamic>.from(m))
          .map(_parseCallableReview)
          .toList();
      debugPrint(
        'getRecentReviews($priestId): callable returned '
        '${reviews.length} reviews',
      );
      // Empty list from the callable is a valid result (the priest
      // simply has no rated sessions yet) — return it instead of
      // falling through to other paths that won't find anything
      // either.
      return reviews;
    } catch (e) {
      debugPrint('getRecentReviews callable failed for $priestId: $e');
    }

    // --- 2. priest-doc array fallback ---
    try {
      final snap = await _db
          .doc('priests/$priestId')
          .get()
          .timeout(const Duration(seconds: 6));

      final raw = snap.data()?['recentReviews'] as List? ?? const [];
      if (raw.isNotEmpty) {
        final reviews = _parsePriestDocReviews(raw, limit);
        debugPrint(
          'getRecentReviews($priestId): array fallback returned '
          '${reviews.length} reviews',
        );
        return reviews;
      }
    } catch (e) {
      debugPrint('getRecentReviews array path failed for $priestId: $e');
    }

    // --- 3. direct sessions query (last resort) ---
    try {
      final snap = await _db
          .collection('sessions')
          .where('priestId', isEqualTo: priestId)
          .limit(250)
          .get()
          .timeout(const Duration(seconds: 8));

      final reviews = _parseSessionRows(snap.docs, limit);
      debugPrint(
        'getRecentReviews($priestId): sessions last-resort returned '
        '${reviews.length} reviews',
      );
      return reviews;
    } catch (e, st) {
      debugPrint(
        'getRecentReviews sessions last-resort failed for $priestId: '
        '$e\n$st',
      );
      return const [];
    }
  }

  // Parser for the callable's response. Shape matches the
  // getPublicPriestReviews TS interface: flat fields, endedAt as
  // ISO string, priestReply as nullable plain string.
  PriestReview _parseCallableReview(Map<String, dynamic> m) {
    final reply = (m['priestReply'] as String?)?.trim() ?? '';
    final endedRaw = m['endedAt'];
    return PriestReview(
      userName: (m['userName'] as String?) ?? '',
      userPhotoUrl: (m['userPhotoUrl'] as String?) ?? '',
      rating: (m['rating'] as num?)?.toDouble() ?? 0,
      feedback: (m['feedback'] as String?) ?? '',
      at: endedRaw is String ? DateTime.tryParse(endedRaw) : null,
      priestReply: reply.isEmpty ? null : reply,
    );
  }

  // Parser shared between the two paths. Handles both the array shape
  // (fields: rating, feedback, endedAt, priestReply) AND the session
  // shape (fields: userRating, userFeedback, endedAt, priestReply).
  List<PriestReview> _parsePriestDocReviews(List raw, int limit) {
    final rows = raw
        .whereType<Map>()
        .map((m) => Map<String, dynamic>.from(m))
        .toList();
    _sortReviews(rows, ratingKey: 'rating', feedbackKey: 'feedback');
    return rows.take(limit).map((d) {
      final reply = (d['priestReply'] as String?)?.trim() ?? '';
      return PriestReview(
        userName: (d['userName'] as String?) ?? '',
        userPhotoUrl: (d['userPhotoUrl'] as String?) ?? '',
        rating: (d['rating'] as num?)?.toDouble() ?? 0,
        feedback: (d['feedback'] as String?) ?? '',
        at: _readAt(d['endedAt']),
        priestReply: reply.isEmpty ? null : reply,
      );
    }).toList();
  }

  List<PriestReview> _parseSessionRows(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
    int limit,
  ) {
    final rows = docs
        .map((d) => d.data())
        .where((d) => (d['userRating'] as num?) != null)
        .toList();
    _sortReviews(
      rows,
      ratingKey: 'userRating',
      feedbackKey: 'userFeedback',
    );
    return rows.take(limit).map((d) {
      final replyMap = d['priestReply'] is Map
          ? Map<String, dynamic>.from(d['priestReply'] as Map)
          : null;
      final replyText =
          (replyMap?['text'] as String?)?.trim() ?? '';
      return PriestReview(
        userName: (d['userName'] as String?) ?? '',
        userPhotoUrl: (d['userPhotoUrl'] as String?) ?? '',
        rating: (d['userRating'] as num?)?.toDouble() ?? 0,
        feedback: (d['userFeedback'] as String?) ?? '',
        at: _readAt(d['endedAt']),
        priestReply: replyText.isEmpty ? null : replyText,
      );
    }).toList();
  }

  DateTime? _readAt(dynamic v) {
    if (v is Timestamp) return v.toDate();
    if (v is String) return DateTime.tryParse(v);
    return null;
  }

  void _sortReviews(
    List<Map<String, dynamic>> rows, {
    required String ratingKey,
    required String feedbackKey,
  }) {
    bool hasText(Map<String, dynamic> d) =>
        ((d[feedbackKey] as String?)?.trim() ?? '').isNotEmpty;
    rows.sort((a, b) {
      // Written reviews first.
      final wa = hasText(a) ? 0 : 1;
      final wb = hasText(b) ? 0 : 1;
      if (wa != wb) return wa.compareTo(wb);
      // Then newest first.
      final ta = _readAt(a['endedAt']);
      final tb = _readAt(b['endedAt']);
      if (ta == null && tb == null) return 0;
      if (ta == null) return 1;
      if (tb == null) return -1;
      return tb.compareTo(ta);
    });
  }
}

// Lightweight view-model for the profile-page review preview. Lives
// here (not in shared/data/session_model.dart) because it's a strict
// subset of SessionModel — only the fields the public preview card
// renders — and adding it to SessionModel would force every other
// reader to know about the projection.
class PriestReview {
  final String userName;
  final String userPhotoUrl;
  final double rating;
  final String feedback;
  final DateTime? at;
  // Priest's public reply text if they replied to this review.
  // Stored flat (just the text) because the profile preview never
  // needs the createdAt / edit-window metadata that the priest-side
  // ReviewReply carries.
  final String? priestReply;

  const PriestReview({
    required this.userName,
    required this.userPhotoUrl,
    required this.rating,
    required this.feedback,
    required this.at,
    this.priestReply,
  });
}
