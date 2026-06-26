// Revenue repository — fetches the raw rows the revenue page needs.
//
// Reads are admin-only (firestore.rules lets isAdmin() read any
// wallet_transactions row, which is what makes the __platform__ /
// type-filtered queries below resolve). Each query is wrapped in
// `_safe` so one failing read degrades to an empty list rather than
// blanking the whole page.
//
// SCALE NOTE: these are full-collection client reads filtered client-
// side (the same pattern the dashboard cards use). Fine for the admin
// tool at current volume; when the ledger grows large this should move
// to a server-side aggregation / scheduled rollup.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import 'package:gospel_vox/features/admin/revenue/data/revenue_models.dart';

class RevenueRepository {
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  Future<RevenueData> getRevenueData() async {
    final results = await Future.wait([
      _safe(_getPlatformTxns, <RevenueTxn>[]),
      _safe(_getActivationTxns, <RevenueTxn>[]),
      _safe(_getGrossSales, <GrossSale>[]),
      _safe(_getStoreCutPercent, 30),
    ]);

    final txns = <RevenueTxn>[
      ...results[0] as List<RevenueTxn>,
      ...results[1] as List<RevenueTxn>,
    ];

    return RevenueData(
      txns: txns,
      grossSales: results[2] as List<GrossSale>,
      storeCutPercent: results[3] as int,
    );
  }

  Future<T> _safe<T>(Future<T> Function() fn, T fallback) async {
    try {
      return await fn();
    } catch (e) {
      debugPrint('[Revenue] query failed: $e');
      return fallback;
    }
  }

  // Commission rows: the platform's slice of calls/chats and bible
  // sessions. Both live under the `__platform__` sentinel uid; the
  // `type` distinguishes the source.
  Future<List<RevenueTxn>> _getPlatformTxns() async {
    final snap = await _db
        .collection('wallet_transactions')
        .where('userId', isEqualTo: '__platform__')
        .get()
        .timeout(const Duration(seconds: 12));

    final out = <RevenueTxn>[];
    for (final doc in snap.docs) {
      final data = doc.data();
      final coins = (data['coins'] as num?)?.toDouble() ?? 0;
      if (coins <= 0) continue;
      final type = data['type'] as String? ?? '';
      final isBible = type == 'bible_session_commission';
      out.add(RevenueTxn(
        source: isBible ? RevenueSource.bible : RevenueSource.callChat,
        amount: coins,
        at: tsToDate(data['createdAt']),
        title: isBible ? 'Bible session commission' : 'Call / chat commission',
      ));
    }
    return out;
  }

  // One-time speaker activation fees. 100% platform revenue.
  Future<List<RevenueTxn>> _getActivationTxns() async {
    final snap = await _db
        .collection('wallet_transactions')
        .where('type', isEqualTo: 'activation_fee')
        .get()
        .timeout(const Duration(seconds: 12));

    final out = <RevenueTxn>[];
    for (final doc in snap.docs) {
      final data = doc.data();
      final amt = (data['amountPaid'] as num?)?.toDouble() ?? 0;
      if (amt <= 0) continue;
      out.add(RevenueTxn(
        source: RevenueSource.activation,
        amount: amt,
        at: tsToDate(data['createdAt']),
        title: 'Speaker activation fee',
      ));
    }
    return out;
  }

  // Gross coin-pack sales (what customers were charged). Context only —
  // not counted as platform revenue.
  Future<List<GrossSale>> _getGrossSales() async {
    final snap = await _db
        .collection('wallet_transactions')
        .where('type', isEqualTo: 'purchase')
        .get()
        .timeout(const Duration(seconds: 12));

    final out = <GrossSale>[];
    for (final doc in snap.docs) {
      final data = doc.data();
      final amt = (data['amountPaid'] as num?)?.toDouble() ?? 0;
      if (amt <= 0) continue;
      out.add(GrossSale(amount: amt, at: tsToDate(data['createdAt'])));
    }
    return out;
  }


  // Store fee % used only for the "after store fee" estimate. Reads an
  // optional `storeCutPercent` from app_config so it can be tuned
  // without a rebuild; defaults to 30.
  Future<int> _getStoreCutPercent() async {
    final doc = await _db
        .doc('app_config/settings')
        .get()
        .timeout(const Duration(seconds: 10));
    final raw = (doc.data()?['storeCutPercent'] as num?)?.toInt();
    return (raw != null && raw >= 0 && raw <= 100) ? raw : 30;
  }
}
