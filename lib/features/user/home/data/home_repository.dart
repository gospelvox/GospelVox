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

import 'package:gospel_vox/features/admin/speakers/data/speaker_model.dart';

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
    return SpeakerModel.fromFirestore(doc.data()!);
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
  // Reviews preview. Single-`where` query (priestId == X) with
  // client-side filtering + sorting to avoid a composite index — same
  // pattern as PriestReviewsPage. Returns at most [limit] entries
  // that have BOTH a rating and a non-empty written feedback (a
  // star-only review is useless as a preview).
  //
  // Any failure (index missing, permission denied, timeout) returns
  // an empty list so the Reviews section just hides on the profile
  // instead of breaking the whole page.
  Future<List<PriestReview>> getRecentReviews(
    String priestId, {
    int limit = 3,
  }) async {
    try {
      final snap = await _db
          .collection('sessions')
          .where('priestId', isEqualTo: priestId)
          .limit(80)
          .get()
          .timeout(const Duration(seconds: 8));

      final rows = snap.docs
          .map((d) => d.data())
          .where((d) {
            final rating = (d['userRating'] as num?)?.toDouble();
            final feedback =
                (d['userFeedback'] as String?)?.trim() ?? '';
            return rating != null && feedback.isNotEmpty;
          })
          .toList();

      rows.sort((a, b) {
        final ta = a['endedAt'] is Timestamp
            ? (a['endedAt'] as Timestamp).toDate()
            : null;
        final tb = b['endedAt'] is Timestamp
            ? (b['endedAt'] as Timestamp).toDate()
            : null;
        if (ta == null && tb == null) return 0;
        if (ta == null) return 1;
        if (tb == null) return -1;
        return tb.compareTo(ta);
      });

      return rows.take(limit).map((d) {
        return PriestReview(
          userName: (d['userName'] as String?) ?? '',
          userPhotoUrl: (d['userPhotoUrl'] as String?) ?? '',
          rating: (d['userRating'] as num?)?.toDouble() ?? 0,
          feedback: (d['userFeedback'] as String?) ?? '',
          at: d['endedAt'] is Timestamp
              ? (d['endedAt'] as Timestamp).toDate()
              : null,
        );
      }).toList();
    } catch (_) {
      return const [];
    }
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

  const PriestReview({
    required this.userName,
    required this.userPhotoUrl,
    required this.rating,
    required this.feedback,
    required this.at,
  });
}
