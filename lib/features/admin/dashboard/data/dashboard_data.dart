// Dashboard aggregate data model

class DashboardData {
  final int pendingSpeakers;
  final int pendingMatrimony;
  final int openReports;
  final int pendingWithdrawals;
  final double todayRevenue;
  final int activeSessions;
  final int totalUsers;
  final double allTimeRevenue;

  const DashboardData({
    required this.pendingSpeakers,
    required this.pendingMatrimony,
    required this.openReports,
    required this.pendingWithdrawals,
    required this.todayRevenue,
    required this.activeSessions,
    required this.totalUsers,
    required this.allTimeRevenue,
  });

  // Matrimony is intentionally excluded: its admin approval screen isn't
  // built yet, so a pending matrimony count must not trigger the attention
  // strip — there would be nothing the admin could actually act on. The
  // field is still carried on the model for when that screen ships.
  bool get hasAttentionItems =>
      pendingSpeakers > 0 ||
      openReports > 0 ||
      pendingWithdrawals > 0;
}
