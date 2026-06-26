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

  // Admin-tunable floor. Reads `minWithdrawal` — the SAME key the
  // admin Settings screen and the seed write. (The old code read
  // `minWithdrawalAmount`, which nothing ever wrote, so the admin
  // value was silently ignored and this fell back to the default.)
  // Defaults to ₹1,000 if the settings doc hasn't been created yet.
  Future<int> getMinWithdrawalAmount() async {
    final doc = await _firestore
        .doc('app_config/settings')
        .get()
        .timeout(const Duration(seconds: 10));
    return (doc.data()?['minWithdrawal'] as num?)?.toInt() ?? 1000;
  }

  // Writes only the bank-detail fields. The priests/{uid} doc has
  // other fields (status, walletBalance, etc.) that must NOT be
  // overwritten — `update` instead of `set` keeps everything else
  // untouched.
  //
  // 30-second timeout (vs the 10s elsewhere) because cloud_firestore's
  // update() future only resolves when the server acks the write, and
  // a spotty mobile network round-trip can take 15-25 s. Anything
  // shorter falsely reports "Save timed out" while the write is in
  // fact already queued / completing.
  Future<void> saveBankDetails({
    required String uid,
    required BankDetails details,
  }) async {
    await _firestore
        .doc('priests/$uid')
        .update(details.toFirestore())
        .timeout(const Duration(seconds: 30));
  }

  // Server-side truth check for the bank details on the priest doc.
  // Used by the bank-details page as a self-heal after a save
  // TimeoutException: even when the network round-trip blew past
  // the ack deadline, the write is often already committed on the
  // server. This lets the UI confirm + flip to the saved view
  // instead of asking the priest to re-enter data they already
  // sent.
  Future<BankDetails?> fetchBankDetailsOnce(String uid) async {
    final snap = await _firestore
        .doc('priests/$uid')
        .get(const GetOptions(source: Source.server))
        .timeout(const Duration(seconds: 15));
    final data = snap.data();
    if (data == null) return null;
    final details = BankDetails.fromFirestore(data);
    return details.isComplete ? details : null;
  }

  // Clears every bank-detail field on the priest doc — used by the
  // "Delete bank account" action. We blank the strings rather than
  // FieldValue.delete() so PriestWalletSummary.fromFirestore stays
  // on a single code path (it checks `holder.isEmpty` to decide
  // bankDetails == null, which empty-string satisfies cleanly).
  //
  // Pending withdrawals already snapshot the bank fields onto the
  // withdrawal doc itself, so deleting the priest's saved details
  // never strands money in motion — admin payouts still know where
  // each historical request was meant to go.
  //
  // Same 30s timeout reasoning as saveBankDetails — server ack on
  // slow mobile networks can exceed 10s.
  Future<void> clearBankDetails(String uid) async {
    await _firestore
        .doc('priests/$uid')
        .update(const <String, dynamic>{
          'bankAccountName': '',
          'bankAccountNumber': '',
          'bankIfscCode': '',
          'bankName': '',
          'bankBranchName': '',
          'bankAccountType': '',
          'upiId': '',
          // Cross-border fields cleared too, so a deleted US/UK/IBAN
          // account never leaves a stale routing number / IBAN behind.
          'bankCountry': '',
          'bankCurrency': '',
          'bankRoutingNumber': '',
          'bankSortCode': '',
          'bankIban': '',
          'bankSwiftBic': '',
          'bankContactPhone': '',
          'bankContactEmail': '',
        })
        .timeout(const Duration(seconds: 30));
  }

  // Count of withdrawals the priest still has in flight (status =
  // pending). Used as a guard before the delete-bank action so we
  // can warn the priest that admin payouts will continue against
  // the snapshotted bank info on those rows.
  Future<int> getPendingWithdrawalCount(String uid) async {
    final snap = await _firestore
        .collection('withdrawals')
        .where('priestId', isEqualTo: uid)
        .where('status', isEqualTo: 'pending')
        .get()
        .timeout(const Duration(seconds: 8));
    return snap.size;
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

  // Live stream of the priest's withdrawals, newest-first. Powers the
  // wallet page's "withdrawal in progress" card and the status tags on
  // history rows, so both update the moment the admin advances a
  // payout — no pull-to-refresh needed.
  //
  // Single equality filter on priestId, which Firestore single-field
  // indexes automatically — NO composite index required (we sort
  // client-side, same reasoning as getWithdrawals).
  Stream<List<WithdrawalRecord>> watchWithdrawals(String uid) {
    return _firestore
        .collection('withdrawals')
        .where('priestId', isEqualTo: uid)
        .snapshots()
        .map((snap) {
      final list = snap.docs
          .map((doc) => WithdrawalRecord.fromFirestore(doc.id, doc.data()))
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

  // Withdrawal history / status feed for the priest's status screen.
  //
  // Deliberately NO orderBy: pairing where('priestId') with
  // orderBy('createdAt') needs a (priestId, createdAt) composite index
  // that no deploy creates — the only withdrawals index is
  // (status, createdAt) for the admin queue — so on first prod run the
  // query would throw FAILED_PRECONDITION. We sort newest-first
  // client-side instead, matching the admin withdrawals repo. A priest
  // has few withdrawals, so fetching and sorting the lot is cheap.
  Future<List<WithdrawalRecord>> getWithdrawals(String uid) async {
    final snap = await _firestore
        .collection('withdrawals')
        .where('priestId', isEqualTo: uid)
        .get()
        .timeout(const Duration(seconds: 10));

    final list = snap.docs
        .map((doc) => WithdrawalRecord.fromFirestore(doc.id, doc.data()))
        .toList();

    // Newest first; nulls (pending server timestamp) sink to the bottom
    // so a just-requested withdrawal doesn't jump above older ones
    // during the brief write-then-read window.
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
}
