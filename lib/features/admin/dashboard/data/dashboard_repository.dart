// Dashboard repository — fetches aggregate counts from Firestore

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import 'package:gospel_vox/features/admin/dashboard/data/dashboard_data.dart';

class DashboardRepository {
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  Future<DashboardData> getDashboardData() async {
    final results = await Future.wait([
      _safe(() => _getPendingSpeakersCount(), 0),
      _safe(() => _getPendingMatrimonyCount(), 0),
      _safe(() => _getOpenReportsCount(), 0),
      _safe(() => _getPendingWithdrawalsCount(), 0),
      _safe(() => _getTodayRevenue(), 0.0),
      _safe(() => _getActiveSessionsCount(), 0),
      _safe(() => _getTotalUsersCount(), 0),
      _safe(() => _getAllTimeRevenue(), 0.0),
    ]);

    return DashboardData(
      pendingSpeakers: results[0] as int,
      pendingMatrimony: results[1] as int,
      openReports: results[2] as int,
      pendingWithdrawals: results[3] as int,
      todayRevenue: results[4] as double,
      activeSessions: results[5] as int,
      totalUsers: results[6] as int,
      allTimeRevenue: results[7] as double,
    );
  }

  Future<T> _safe<T>(Future<T> Function() fn, T fallback) async {
    try {
      return await fn();
    } catch (e) {
      debugPrint('[Dashboard] Query failed: $e');
      return fallback;
    }
  }

  Future<int> _getPendingSpeakersCount() async {
    final snap = await _db
        .collection('priests')
        .where('status', isEqualTo: 'pending')
        .count()
        .get()
        .timeout(const Duration(seconds: 10));
    return snap.count ?? 0;
  }

  Future<int> _getPendingMatrimonyCount() async {
    final snap = await _db
        .collection('matrimony_profiles')
        .where('status', isEqualTo: 'pending')
        .count()
        .get()
        .timeout(const Duration(seconds: 10));
    return snap.count ?? 0;
  }

  Future<int> _getOpenReportsCount() async {
    // 'pending' matches the value the report queue and admin
    // resolve flow use ({pending, resolved}). Earlier 'open' was
    // a leftover from a never-shipped status taxonomy and made
    // this card permanently read 0.
    final snap = await _db
        .collection('reports')
        .where('status', isEqualTo: 'pending')
        .count()
        .get()
        .timeout(const Duration(seconds: 10));
    return snap.count ?? 0;
  }

  Future<int> _getPendingWithdrawalsCount() async {
    final snap = await _db
        .collection('withdrawals')
        .where('status', isEqualTo: 'pending')
        .count()
        .get()
        .timeout(const Duration(seconds: 10));
    return snap.count ?? 0;
  }

  Future<double> _getTodayRevenue() async {
    // Platform revenue today = sum of `coins` on every
    // wallet_transactions row addressed to the `__platform__`
    // sentinel uid (the commission rows written by the bible-
    // session payment CFs). Single-field equality query so we
    // don't need a composite index — we filter by today client-
    // side. Volume is tiny (a few rows per session paid for) so
    // the round-trip cost is bounded even months down the line.
    //
    // Today is computed off `DateTime.now()` in the device's local
    // timezone. The admin web/dash is operated from India (IST), so
    // "today" matches the operator's mental model without an
    // explicit Asia/Kolkata coercion.
    final snap = await _db
        .collection('wallet_transactions')
        .where('userId', isEqualTo: '__platform__')
        .get()
        .timeout(const Duration(seconds: 10));

    final now = DateTime.now();
    final startOfToday = DateTime(now.year, now.month, now.day);
    double total = 0;
    for (final doc in snap.docs) {
      final data = doc.data();
      final ts = data['createdAt'];
      if (ts is! Timestamp) continue;
      final at = ts.toDate();
      if (at.isBefore(startOfToday)) continue;
      final coins = (data['coins'] as num?)?.toDouble() ?? 0;
      total += coins;
    }
    return total;
  }

  Future<int> _getActiveSessionsCount() async {
    final snap = await _db
        .collection('sessions')
        .where('status', isEqualTo: 'active')
        .count()
        .get()
        .timeout(const Duration(seconds: 10));
    return snap.count ?? 0;
  }

  Future<int> _getTotalUsersCount() async {
    final snap = await _db
        .collection('users')
        .count()
        .get()
        .timeout(const Duration(seconds: 10));
    return snap.count ?? 0;
  }

  Future<double> _getAllTimeRevenue() async {
    // Platform revenue all-time = sum of `coins` on every
    // wallet_transactions row addressed to `__platform__`. Same
    // shape as _getTodayRevenue minus the date filter — kept as
    // two separate queries (rather than one query + two sums) so
    // either card can fail independently without taking the other
    // down with it via the `_safe` wrapper above.
    final snap = await _db
        .collection('wallet_transactions')
        .where('userId', isEqualTo: '__platform__')
        .get()
        .timeout(const Duration(seconds: 10));

    double total = 0;
    for (final doc in snap.docs) {
      final coins = (doc.data()['coins'] as num?)?.toDouble() ?? 0;
      total += coins;
    }
    return total;
  }
}
