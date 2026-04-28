// Data access for the admin withdrawal monitor.
//
// The list query deliberately omits `orderBy('createdAt')`. Pairing
// it with `where('status', ...)` would require a composite Firestore
// index that no deploy script currently creates — on first run in
// prod the query throws FAILED_PRECONDITION. We sort client-side
// instead. Matches the speakers repo pattern.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'package:gospel_vox/features/admin/withdrawals/data/admin_withdrawal_model.dart';

class AdminWithdrawalsRepository {
  // statusFilter: null or 'all' returns every status.
  Future<List<AdminWithdrawalModel>> getWithdrawals({
    String? statusFilter,
  }) async {
    Query<Map<String, dynamic>> query =
        FirebaseFirestore.instance.collection('withdrawals');

    if (statusFilter != null && statusFilter != 'all') {
      query = query.where('status', isEqualTo: statusFilter);
    }

    final snap = await query.get().timeout(const Duration(seconds: 10));

    final withdrawals = snap.docs
        .map((doc) =>
            AdminWithdrawalModel.fromFirestore(doc.id, doc.data()))
        .toList();

    // Newest first; nulls (pending server timestamp) sink to the
    // bottom so a freshly-requested payout doesn't vanish off the
    // top during the cache write-then-read window.
    withdrawals.sort((a, b) {
      final aTime = a.createdAt;
      final bTime = b.createdAt;
      if (aTime == null && bTime == null) return 0;
      if (aTime == null) return 1;
      if (bTime == null) return -1;
      return bTime.compareTo(aTime);
    });

    return withdrawals;
  }

  // Admin-flagged "I sent the bank transfer". Direct write today;
  // moves to a CF in Week 6 so we get an audit trail and so the
  // priest gets the "Withdrawal Processed" notification (currently
  // notifications/* is CF-only by rules).
  Future<void> markAsPaid(String withdrawalId) async {
    await FirebaseFirestore.instance
        .doc('withdrawals/$withdrawalId')
        .update({
          'status': 'paid',
          'paidAt': FieldValue.serverTimestamp(),
          'paidBy':
              FirebaseAuth.instance.currentUser?.uid ?? '',
        })
        .timeout(const Duration(seconds: 10));
  }

  // Admin-flagged fraud block. Refunds the amount back to the
  // priest's wallet in the same batch so we never leave the
  // priest's wallet short while the withdrawal sits in 'blocked'.
  Future<void> blockWithdrawal({
    required String withdrawalId,
    required String priestId,
    required int amount,
  }) async {
    final batch = FirebaseFirestore.instance.batch();

    batch.update(
      FirebaseFirestore.instance.doc('withdrawals/$withdrawalId'),
      {
        'status': 'blocked',
        'blockedAt': FieldValue.serverTimestamp(),
        'blockedBy':
            FirebaseAuth.instance.currentUser?.uid ?? '',
      },
    );

    // Refund — atomic increment so concurrent writes (a session
    // earnings credit landing at the same instant) sum correctly.
    batch.update(
      FirebaseFirestore.instance.doc('priests/$priestId'),
      {'walletBalance': FieldValue.increment(amount)},
    );

    await batch.commit().timeout(const Duration(seconds: 10));
  }

  // Tab badge counts — fired alongside the active list so the
  // header counts are always fresh.
  Future<Map<String, int>> getCounts() async {
    final results = await Future.wait([
      _countWhere('pending'),
      _countWhere('paid'),
      _countWhere('blocked'),
    ]).timeout(const Duration(seconds: 10));

    return {
      'pending': results[0],
      'paid': results[1],
      'blocked': results[2],
    };
  }

  Future<int> _countWhere(String status) async {
    try {
      final agg = await FirebaseFirestore.instance
          .collection('withdrawals')
          .where('status', isEqualTo: status)
          .count()
          .get();
      return agg.count ?? 0;
    } catch (_) {
      return 0;
    }
  }
}
