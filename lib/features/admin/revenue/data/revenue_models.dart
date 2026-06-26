// Revenue feature — data models.
//
// "Revenue" here means PLATFORM revenue: the money the platform keeps,
// not the gross the customer paid. It comes from three sources, all
// recorded as wallet_transactions rows:
//   • Calls & chats   — `session_commission` rows (userId == __platform__)
//   • Bible sessions  — `bible_session_commission` rows (userId == __platform__)
//   • Activation fees — `activation_fee` rows (the one-time speaker fee)
//
// Gross coin sales (what customers actually paid for coin packs) are
// tracked separately as `purchase` rows and shown as context so the
// admin can see the store-fee impact.

import 'package:cloud_firestore/cloud_firestore.dart';

// The period the admin is currently viewing. Filtering happens client-
// side off a single fetch, so switching periods is instant.
enum RevenuePeriod { today, week, month, all }

extension RevenuePeriodX on RevenuePeriod {
  String get label {
    switch (this) {
      case RevenuePeriod.today:
        return 'Today';
      case RevenuePeriod.week:
        return 'Week';
      case RevenuePeriod.month:
        return 'Month';
      case RevenuePeriod.all:
        return 'All';
    }
  }

  String get longLabel {
    switch (this) {
      case RevenuePeriod.today:
        return 'Today';
      case RevenuePeriod.week:
        return 'Last 7 days';
      case RevenuePeriod.month:
        return 'This month';
      case RevenuePeriod.all:
        return 'All time';
    }
  }

  // Inclusive lower bound for this period. `null` means "no bound"
  // (all time). `now` is passed in so the whole page agrees on one
  // clock and tests are deterministic.
  DateTime? startFrom(DateTime now) {
    switch (this) {
      case RevenuePeriod.today:
        return DateTime(now.year, now.month, now.day);
      case RevenuePeriod.week:
        return DateTime(now.year, now.month, now.day)
            .subtract(const Duration(days: 6));
      case RevenuePeriod.month:
        return DateTime(now.year, now.month, 1);
      case RevenuePeriod.all:
        return null;
    }
  }
}

enum RevenueSource { callChat, bible, activation }

extension RevenueSourceX on RevenueSource {
  String get label {
    switch (this) {
      case RevenueSource.callChat:
        return 'Calls & Chats';
      case RevenueSource.bible:
        return 'Bible Sessions';
      case RevenueSource.activation:
        return 'Activation Fees';
    }
  }
}

// One platform-earning transaction (a commission slice or an
// activation fee), normalised to rupees.
class RevenueTxn {
  final RevenueSource source;
  final double amount; // rupees (1 coin == ₹1 for commission rows)
  final DateTime? at;
  final String title;

  const RevenueTxn({
    required this.source,
    required this.amount,
    required this.at,
    required this.title,
  });
}

// A coin-pack purchase (gross money in). Kept separate from revenue
// because the gross is not what the platform keeps.
class GrossSale {
  final double amount; // rupees the customer was charged (list price)
  final DateTime? at;

  const GrossSale({required this.amount, required this.at});
}

// Everything the revenue page needs, fetched once. All period maths is
// derived from these lists client-side via the helpers below.
class RevenueData {
  final List<RevenueTxn> txns;
  final List<GrossSale> grossSales;
  // Google Play / Apple service fee %, read from app_config (default
  // 30). Used only to ESTIMATE the after-store-fee figure — clearly
  // labelled as an estimate in the UI.
  final int storeCutPercent;

  const RevenueData({
    required this.txns,
    required this.grossSales,
    required this.storeCutPercent,
  });

  static bool _inPeriod(DateTime? at, RevenuePeriod period, DateTime now) {
    final start = period.startFrom(now);
    if (start == null) return true; // all time
    if (at == null) return false;
    return !at.isBefore(start);
  }

  // Total platform revenue for a period.
  double totalFor(RevenuePeriod period, DateTime now) {
    var sum = 0.0;
    for (final t in txns) {
      if (_inPeriod(t.at, period, now)) sum += t.amount;
    }
    return sum;
  }

  // Per-source total for a period.
  double sourceTotal(RevenueSource source, RevenuePeriod period, DateTime now) {
    var sum = 0.0;
    for (final t in txns) {
      if (t.source == source && _inPeriod(t.at, period, now)) sum += t.amount;
    }
    return sum;
  }

  // Gross coin sales (money customers paid) for a period.
  double grossSalesFor(RevenuePeriod period, DateTime now) {
    var sum = 0.0;
    for (final g in grossSales) {
      if (_inPeriod(g.at, period, now)) sum += g.amount;
    }
    return sum;
  }

  // Most-recent revenue transactions in a period, newest first.
  List<RevenueTxn> recentIn(RevenuePeriod period, DateTime now, {int limit = 25}) {
    final list = txns.where((t) => _inPeriod(t.at, period, now)).toList()
      ..sort((a, b) {
        final ax = a.at;
        final bx = b.at;
        if (ax == null && bx == null) return 0;
        if (ax == null) return 1;
        if (bx == null) return -1;
        return bx.compareTo(ax);
      });
    return list.length > limit ? list.sublist(0, limit) : list;
  }
}

// ── Firestore mapping helpers (kept next to the models) ──

DateTime? tsToDate(Object? v) =>
    v is Timestamp ? v.toDate() : null;
