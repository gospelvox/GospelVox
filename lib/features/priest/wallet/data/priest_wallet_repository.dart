// Firestore + CF gateway for the priest wallet feature.
//
// Stateless by design: a singleton in the DI container is fine
// because every call either takes the uid as an argument or reads
// the auth context inside the CF. Anything that touches walletBalance
// goes through requestWithdrawal — Flutter never writes to that
// field directly (rule 5 of the brief).

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';

import 'package:gospel_vox/features/priest/wallet/data/wallet_models.dart';

class PriestWalletRepository {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseFunctions _functions =
      FirebaseFunctions.instanceFor(region: 'asia-south1');

  // Live snapshot of every wallet-relevant field on priests/{uid}.
  // Replaces the older balance-only stream because we now also
  // surface totalEarnings/totalWithdrawn on the wallet page; piping
  // them through one listener keeps the three values atomic from
  // the UI's perspective.
  Stream<PriestWalletSummary> watchSummary(String uid) {
    return _firestore.doc('priests/$uid').snapshots().map(
          (snap) => PriestWalletSummary.fromFirestore(
            snap.data() ?? const <String, dynamic>{},
          ),
        );
  }

  // Mixed earning + withdrawal feed. Capped at 50 so an old priest
  // doesn't end up paginating the moment they open the wallet —
  // older entries can ship as a "Load more" later if needed.
  Future<List<WalletTransaction>> getTransactions(String uid) async {
    final snap = await _firestore
        .collection('wallet_transactions')
        .where('userId', isEqualTo: uid)
        .orderBy('createdAt', descending: true)
        .limit(50)
        .get()
        .timeout(const Duration(seconds: 10));

    return snap.docs
        .map((doc) => WalletTransaction.fromFirestore(doc.id, doc.data()))
        .toList();
  }

  // Admin-tunable floor. Defaulting to ₹100 keeps things sane if
  // the settings doc hasn't been created yet on a fresh project.
  Future<int> getMinWithdrawalAmount() async {
    final doc = await _firestore
        .doc('app_config/settings')
        .get()
        .timeout(const Duration(seconds: 10));
    return (doc.data()?['minWithdrawalAmount'] as num?)?.toInt() ?? 100;
  }

  // Writes only the bank-detail fields. The priests/{uid} doc has
  // other fields (status, walletBalance, etc.) that must NOT be
  // overwritten — `update` instead of `set` keeps everything else
  // untouched.
  Future<void> saveBankDetails({
    required String uid,
    required BankDetails details,
  }) async {
    await _firestore
        .doc('priests/$uid')
        .update(details.toFirestore())
        .timeout(const Duration(seconds: 10));
  }

  // Generates a fresh idempotency token. We use a Firestore auto-id
  // (20-char base62) instead of pulling in a uuid package — same
  // collision properties, no new dependency. The token is sent to
  // the CF, which dedupes on it before debiting.
  String generateClientRequestId() {
    return _firestore.collection('withdrawals').doc().id;
  }

  // Fires the CF. The CF deducts walletBalance atomically and
  // returns the new balance + the new withdrawal id.
  //
  // Errors come back as WithdrawalException with a stable `reason`
  // token — the page switches on it instead of substring-matching
  // the message. Anything we can't recognise is mapped to
  // 'unknown' so the page still has a clean default branch.
  Future<WithdrawalResult> requestWithdrawal({
    required int amount,
    required String clientRequestId,
  }) async {
    try {
      final callable = _functions.httpsCallable('requestWithdrawal');
      final result = await callable.call(<String, dynamic>{
        'amount': amount,
        'clientRequestId': clientRequestId,
      }).timeout(const Duration(seconds: 15));

      final data = (result.data is Map)
          ? Map<String, dynamic>.from(result.data as Map)
          : <String, dynamic>{};

      return WithdrawalResult(
        withdrawalId: data['withdrawalId'] as String? ?? '',
        newBalance: (data['newBalance'] as num?)?.toDouble() ?? 0,
        amount: amount,
        deduplicated: data['deduplicated'] as bool? ?? false,
      );
    } on FirebaseFunctionsException catch (e) {
      // CF returns structured `details: { reason: "..." }`. We
      // pull `reason` out and pass through; the page maps the
      // tokens to localised messages. Falling back to 'unknown'
      // lets the page show a generic error without us leaking the
      // raw CF text into the UI.
      final raw = e.details;
      final detailsMap = raw is Map
          ? Map<String, dynamic>.from(raw)
          : const <String, dynamic>{};
      final reason = detailsMap['reason'] as String? ?? 'unknown';
      throw WithdrawalException(
        reason: reason,
        message: e.message ?? e.code,
        details: detailsMap,
      );
    }
  }

  // Withdrawal history feed (separate from wallet_transactions
  // because admin moderation flips status to "blocked" on the
  // withdrawal doc itself). Currently unused by the wallet page,
  // but exposed so a future "Withdrawal History" detail page can
  // consume it without a repo change.
  Future<List<WithdrawalRecord>> getWithdrawals(String uid) async {
    final snap = await _firestore
        .collection('withdrawals')
        .where('priestId', isEqualTo: uid)
        .orderBy('createdAt', descending: true)
        .limit(30)
        .get()
        .timeout(const Duration(seconds: 10));

    return snap.docs
        .map((doc) => WithdrawalRecord.fromFirestore(doc.id, doc.data()))
        .toList();
  }
}
