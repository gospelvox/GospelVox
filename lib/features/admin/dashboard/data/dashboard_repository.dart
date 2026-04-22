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
        .get();
    return snap.count ?? 0;
  }

  Future<int> _getPendingMatrimonyCount() async {
    final snap = await _db
        .collection('matrimony_profiles')
        .where('status', isEqualTo: 'pending')
        .count()
        .get();
    return snap.count ?? 0;
  }

  Future<int> _getOpenReportsCount() async {
    final snap = await _db
        .collection('reports')
        .where('status', isEqualTo: 'open')
        .count()
        .get();
    return snap.count ?? 0;
  }

  Future<int> _getPendingWithdrawalsCount() async {
    final snap = await _db
        .collection('withdrawals')
        .where('status', isEqualTo: 'pending')
        .count()
        .get();
    return snap.count ?? 0;
  }

  Future<double> _getTodayRevenue() async {
    return 0;
  }

  Future<int> _getActiveSessionsCount() async {
    final snap = await _db
        .collection('sessions')
        .where('status', isEqualTo: 'active')
        .count()
        .get();
    return snap.count ?? 0;
  }

  Future<int> _getTotalUsersCount() async {
    final snap = await _db.collection('users').count().get();
    return snap.count ?? 0;
  }

  Future<double> _getAllTimeRevenue() async {
    return 0;
  }
}
