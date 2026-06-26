// Data access for the admin withdrawal monitor.
//
// The list query deliberately omits `orderBy('createdAt')`. Pairing
// it with `where('status', ...)` would require a composite Firestore
// index that no deploy script currently creates — on first run in
// prod the query throws FAILED_PRECONDITION. We sort client-side
// instead. Matches the speakers repo pattern.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
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

  String get _adminUid => FirebaseAuth.instance.currentUser?.uid ?? '';

  // ── Lifecycle transitions ──
  // All are direct admin writes (rules whitelist these exact fields).
  // The priest-facing notification is sent by the onWithdrawalStatus
  // Cloud Function trigger reacting to the status change — the client
  // can't write notifications/* (CF-only by rules), so we don't try.

  // Stage 2: the payout has been added to a bank batch / is being
  // prepared. Moves pending -> processing so the priest's status
  // screen shows movement instead of silence.
  Future<void> markProcessing(String withdrawalId) async {
    await FirebaseFirestore.instance
        .doc('withdrawals/$withdrawalId')
        .update({
          'status': 'processing',
          'processingAt': FieldValue.serverTimestamp(),
          'processingBy': _adminUid,
        })
        .timeout(const Duration(seconds: 10));
  }

  // Batch version for the export flow: marking many rows processing at
  // once when they're exported to the bank. Chunked at 400 to stay
  // well under Firestore's 500-write batch limit.
  Future<void> markProcessingBatch(List<String> withdrawalIds) async {
    final db = FirebaseFirestore.instance;
    final by = _adminUid;
    for (var i = 0; i < withdrawalIds.length; i += 400) {
      final chunk = withdrawalIds.sublist(
        i,
        (i + 400 > withdrawalIds.length) ? withdrawalIds.length : i + 400,
      );
      final batch = db.batch();
      for (final id in chunk) {
        batch.update(db.doc('withdrawals/$id'), {
          'status': 'processing',
          'processingAt': FieldValue.serverTimestamp(),
          'processingBy': by,
        });
      }
      await batch.commit().timeout(const Duration(seconds: 20));
    }
  }

  // Fetch a single withdrawal by id (used to refresh the detail page
  // after an edit/reverse so it shows the authoritative state).
  Future<AdminWithdrawalModel?> getWithdrawalById(String withdrawalId) async {
    final snap = await FirebaseFirestore.instance
        .doc('withdrawals/$withdrawalId')
        .get()
        .timeout(const Duration(seconds: 8));
    if (!snap.exists) return null;
    return AdminWithdrawalModel.fromFirestore(snap.id, snap.data()!);
  }

  // Correct a typo'd bank reference on an already-sent payout. Records
  // who/when for the audit trail. Status is unchanged (stays 'paid').
  Future<void> editReference({
    required String withdrawalId,
    required String reference,
    String transactionId = '',
  }) async {
    await FirebaseFirestore.instance
        .doc('withdrawals/$withdrawalId')
        .update({
          'paymentReference': reference.trim(),
          'transactionId': transactionId.trim(),
          'referenceEditedAt': FieldValue.serverTimestamp(),
          'referenceEditedBy': _adminUid,
        })
        .timeout(const Duration(seconds: 10));
  }

  // "Marked Sent by mistake" recovery — move a paid payout BACK to
  // processing and clear the sent fields. NOTE: this does not un-send
  // money; it's for when the admin clicked Sent but hadn't actually
  // wired it. `processingBy` records who reversed it.
  Future<void> reverseToProcessing(String withdrawalId) async {
    await FirebaseFirestore.instance
        .doc('withdrawals/$withdrawalId')
        .update({
          'status': 'processing',
          'processingAt': FieldValue.serverTimestamp(),
          'processingBy': _adminUid,
          'paymentReference': FieldValue.delete(),
          'paidAt': FieldValue.delete(),
          'paidBy': FieldValue.delete(),
        })
        .timeout(const Duration(seconds: 10));
  }

  // Resolves the priest's CURRENT bank details for the Mark-Sent sheet.
  //
  // Why: the withdrawal snapshots the bank details at request time. If
  // the payout was put On Hold for a bad account and the priest then
  // corrected their bank details, that snapshot is stale — sending to
  // it would pay the wrong account. We re-read priests/{priestId} so
  // the admin always sees and copies the up-to-date account.
  //
  // Returns a model carrying the CURRENT bank fields + this payout's
  // amount, or null if the priest has no usable destination now (e.g.
  // they deleted their bank details) — the caller then falls back to
  // the request snapshot so a payout is never left undeliverable.
  Future<AdminWithdrawalModel?> getCurrentPriestPayout(
    AdminWithdrawalModel w,
  ) async {
    try {
      final snap = await FirebaseFirestore.instance
          .doc('priests/${w.priestId}')
          .get()
          .timeout(const Duration(seconds: 8));
      final data = Map<String, dynamic>.from(snap.data() ?? <String, dynamic>{});
      // Inject the payout-specific fields the priest doc doesn't carry.
      data['priestId'] = w.priestId;
      data['amount'] = w.amount;
      data['status'] = w.status;
      final model = AdminWithdrawalModel.fromFirestore(w.id, data);
      if (model.bankAccountName.isEmpty ||
          model.primaryAccountIdentifier.isEmpty) {
        return null; // no usable current destination
      }
      return model;
    } catch (_) {
      return null;
    }
  }

  // Stage 3: the bank transfer has been sent. The reference (UTR /
  // wire ref / whatever the bank returns) is recorded so the priest
  // sees it on their status screen and can chase the bank if needed.
  Future<void> markSent({
    required String withdrawalId,
    required String reference,
    String transactionId = '',
  }) async {
    await FirebaseFirestore.instance
        .doc('withdrawals/$withdrawalId')
        .update({
          'status': 'paid',
          'paidAt': FieldValue.serverTimestamp(),
          'paidBy': _adminUid,
          'paymentReference': reference.trim(),
          'transactionId': transactionId.trim(),
        })
        .timeout(const Duration(seconds: 10));
  }

  // Bulk Stage 3 — mark MANY payouts sent with ONE bank reference
  // (e.g. a single batch UTR the bank returns for a bulk transfer).
  // Chunked at 400 to stay under Firestore's 500-write batch limit;
  // each priest is notified by the onWithdrawalStatus trigger.
  Future<void> markSentBatch(
    List<String> withdrawalIds,
    String reference,
  ) async {
    final db = FirebaseFirestore.instance;
    final by = _adminUid;
    final ref = reference.trim();
    for (var i = 0; i < withdrawalIds.length; i += 400) {
      final end =
          (i + 400 > withdrawalIds.length) ? withdrawalIds.length : i + 400;
      final batch = db.batch();
      for (final id in withdrawalIds.sublist(i, end)) {
        batch.update(db.doc('withdrawals/$id'), {
          'status': 'paid',
          'paidAt': FieldValue.serverTimestamp(),
          'paidBy': by,
          'paymentReference': ref,
        });
      }
      await batch.commit().timeout(const Duration(seconds: 20));
    }
  }

  // Bulk On-Hold — flag MANY payouts with one reason (e.g. the rows the
  // bank bounced in a batch). Chunked like markSentBatch.
  Future<void> putOnHoldBatch(
    List<String> withdrawalIds,
    String reason,
  ) async {
    final db = FirebaseFirestore.instance;
    final by = _adminUid;
    final r = reason.trim();
    for (var i = 0; i < withdrawalIds.length; i += 400) {
      final end =
          (i + 400 > withdrawalIds.length) ? withdrawalIds.length : i + 400;
      final batch = db.batch();
      for (final id in withdrawalIds.sublist(i, end)) {
        batch.update(db.doc('withdrawals/$id'), {
          'status': 'on_hold',
          'onHoldAt': FieldValue.serverTimestamp(),
          'onHoldReason': r,
          'onHoldBy': by,
        });
      }
      await batch.commit().timeout(const Duration(seconds: 20));
    }
  }

  // Off-path: a problem the priest must fix (wrong details, bank
  // rejected). Carries a reason the priest reads on their status
  // screen. Does NOT refund — the money is still owed; the payout is
  // just paused until the priest corrects their bank details.
  Future<void> putOnHold({
    required String withdrawalId,
    required String reason,
  }) async {
    await FirebaseFirestore.instance
        .doc('withdrawals/$withdrawalId')
        .update({
          'status': 'on_hold',
          'onHoldAt': FieldValue.serverTimestamp(),
          'onHoldReason': reason.trim(),
          'onHoldBy': _adminUid,
        })
        .timeout(const Duration(seconds: 10));
  }

  // Admin block & refund — routed through the blockWithdrawal Cloud
  // Function so the refund is SAFE: the function runs a transaction that
  // is idempotent (a second block refunds nothing), refuses to block an
  // already-paid payout, and writes the offsetting refund ledger row.
  // The old client batch did a blind balance increment with no status
  // guard, which could double-refund. priestId/amount are kept on the
  // signature for the caller but the function reads them authoritatively
  // from the withdrawal doc itself.
  Future<void> blockWithdrawal({
    required String withdrawalId,
    required String priestId,
    required int amount,
  }) async {
    final callable = FirebaseFunctions.instanceFor(region: 'asia-south1')
        .httpsCallable('blockWithdrawal');
    await callable
        .call<dynamic>(<String, dynamic>{'withdrawalId': withdrawalId})
        .timeout(const Duration(seconds: 15));
  }

  // LIVE stream of the withdrawal queue for a tab — so the admin sees
  // new requests, status moves, and priest-fixed (on_hold -> pending)
  // payouts instantly, without leaving and re-opening the page.
  //
  // Uses a single equality filter on `status` (auto single-field index —
  // NO composite index, so it can't throw FAILED_PRECONDITION) and sorts
  // newest-first client-side, matching getWithdrawals. 'all'/null streams
  // every status.
  Stream<List<AdminWithdrawalModel>> watchWithdrawals({String? statusFilter}) {
    Query<Map<String, dynamic>> query =
        FirebaseFirestore.instance.collection('withdrawals');
    if (statusFilter != null && statusFilter != 'all') {
      query = query.where('status', isEqualTo: statusFilter);
    }
    return query.snapshots().map((snap) {
      final list = snap.docs
          .map((doc) =>
              AdminWithdrawalModel.fromFirestore(doc.id, doc.data()))
          .toList();
      list.sort((a, b) {
        final at = a.createdAt;
        final bt = b.createdAt;
        if (at == null && bt == null) return 0;
        if (at == null) return 1;
        if (bt == null) return -1;
        return bt.compareTo(at);
      });
      return list;
    });
  }

  // Every withdrawal a single priest has made, newest-first — powers
  // the per-priest history view (the "same priest, ₹100 × 3" case) and
  // its export. Single equality filter on priestId, so no composite
  // index is needed; sorted client-side like the main list.
  Future<List<AdminWithdrawalModel>> getWithdrawalsForPriest(
    String priestId,
  ) async {
    final snap = await FirebaseFirestore.instance
        .collection('withdrawals')
        .where('priestId', isEqualTo: priestId)
        .get()
        .timeout(const Duration(seconds: 10));

    final list = snap.docs
        .map((doc) =>
            AdminWithdrawalModel.fromFirestore(doc.id, doc.data()))
        .toList();
    list.sort((a, b) {
      final at = a.createdAt;
      final bt = b.createdAt;
      if (at == null && bt == null) return 0;
      if (at == null) return 1;
      if (bt == null) return -1;
      return bt.compareTo(at);
    });
    return list;
  }

  // Tab badge counts — fired alongside the active list so the
  // header counts are always fresh.
  Future<Map<String, int>> getCounts() async {
    final results = await Future.wait([
      _countWhere('pending'),
      _countWhere('processing'),
      _countWhere('paid'),
      _countWhere('on_hold'),
      _countWhere('blocked'),
    ]).timeout(const Duration(seconds: 10));

    return {
      'pending': results[0],
      'processing': results[1],
      'paid': results[2],
      'on_hold': results[3],
      'blocked': results[4],
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
