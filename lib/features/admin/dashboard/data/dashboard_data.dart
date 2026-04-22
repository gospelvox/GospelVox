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

  bool get hasAttentionItems =>
      pendingSpeakers > 0 ||
      pendingMatrimony > 0 ||
      openReports > 0 ||
      pendingWithdrawals > 0;
}
