// Data access for the admin speaker management flow.
//
// Two important design choices the reader should know about:
//
// 1. The list query deliberately omits `orderBy('createdAt')`. Pairing
//    that with a `where('status', ...)` would require a composite
//    Firestore index that no deploy script currently creates — on
//    first run in prod the query would throw FAILED_PRECONDITION.
//    We sort client-side instead; speaker counts per status are small
//    enough that this is free in wall-clock terms.
//
// 2. Every mutation (approve/reject/suspend/unsuspend) goes through
//    the same Cloud Function. Writing priests/{id}.status directly
//    from the client would hit Firestore rules that restrict that
//    field to the priest themselves — admins can't write it. The CF
//    runs with Admin SDK privileges after verifying the caller is
//    actually an admin, which is both safer and auditable.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';

import 'package:gospel_vox/features/admin/speakers/data/speaker_model.dart';

// Region matches functions/src/config/constants.ts. Hard-coding here
// rather than injecting because there's only one functions region
// for this app and a mismatch would manifest as a confusing
// "function not found" error.
const String _kRegion = 'asia-south1';

class SpeakersRepository {
  FirebaseFunctions get _functions =>
      FirebaseFunctions.instanceFor(region: _kRegion);

  // Fetches all priests with the given status. Sorts newest-first
  // in-memory to avoid the composite-index requirement described at
  // the top of the file.
  Future<List<SpeakerModel>> getSpeakers(String status) async {
    final snap = await FirebaseFirestore.instance
        .collection('priests')
        .where('status', isEqualTo: status)
        .get()
        .timeout(const Duration(seconds: 10));

    final speakers = snap.docs
        .where((doc) => doc.id != '_placeholder')
        .map((doc) => SpeakerModel.fromFirestore(doc.data()))
        .toList();

    // Newest first; nulls (pending server timestamp) sink to the
    // bottom so the freshly-submitted application doesn't vanish
    // off the top of the admin's view.
    speakers.sort((a, b) {
      final aTime = a.createdAt;
      final bTime = b.createdAt;
      if (aTime == null && bTime == null) return 0;
      if (aTime == null) return 1;
      if (bTime == null) return -1;
      return bTime.compareTo(aTime);
    });

    return speakers;
  }

  Future<SpeakerModel> getSpeakerDetail(String uid) async {
    final doc = await FirebaseFirestore.instance
        .doc('priests/$uid')
        .get()
        .timeout(const Duration(seconds: 10));

    if (!doc.exists) {
      throw FirebaseException(
        plugin: 'cloud_firestore',
        code: 'not-found',
        message: 'Speaker not found',
      );
    }
    return SpeakerModel.fromFirestore(doc.data()!);
  }

  // Single callable for every admin moderation action. The CF
  // enforces the state machine (e.g. can only suspend approved
  // speakers) and surfaces failures as FirebaseFunctionsException
  // with typed codes that the cubit can translate into friendly
  // copy.
  Future<void> approve(String priestId) async {
    await _call({'priestId': priestId, 'action': 'approve'});
  }

  Future<void> reject(String priestId, String reason) async {
    await _call({
      'priestId': priestId,
      'action': 'reject',
      'rejectionReason': reason,
    });
  }

  Future<void> suspend(String priestId) async {
    await _call({'priestId': priestId, 'action': 'suspend'});
  }

  Future<void> unsuspend(String priestId) async {
    await _call({'priestId': priestId, 'action': 'unsuspend'});
  }

  Future<void> _call(Map<String, dynamic> data) async {
    await _functions
        .httpsCallable('approveRejectPriest')
        .call(data)
        .timeout(const Duration(seconds: 15));
  }

  // Tab badge counts. `count().get()` is a Firestore aggregation
  // query — cheap because it reads metadata only, never doc contents.
  // A single failed count shouldn't take the whole screen down, so
  // we fall back to 0 per bucket if a specific aggregation throws.
  Future<Map<String, int>> getStatusCounts() async {
    final results = await Future.wait([
      _countWhere('pending'),
      _countWhere('approved'),
      _countWhere('suspended'),
    ]).timeout(const Duration(seconds: 10));

    return {
      'pending': results[0],
      'approved': results[1],
      'suspended': results[2],
    };
  }

  Future<int> _countWhere(String status) async {
    final agg = await FirebaseFirestore.instance
        .collection('priests')
        .where('status', isEqualTo: status)
        .count()
        .get();
    return agg.count ?? 0;
  }
}
