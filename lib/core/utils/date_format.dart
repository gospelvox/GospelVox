// Single source of truth for date / time / time-ago formatting.
// Every chat surface, every list, every notification ribbon goes
// through this file. Three rules govern everything below:
//
//   1. Always `.toLocal()` the input before reading components.
//      Cloud Firestore's `Timestamp.toDate()` returns a local
//      DateTime, but call paths occasionally hand us a UTC
//      DateTime by accident (someone wrote `.toUtc()` or the
//      timestamp was constructed manually). `.toLocal()` is a
//      no-op when already local and the right thing when UTC.
//
//   2. Calendar-day comparisons strip the time component first.
//      Never use `Duration.inDays` to decide "Today" / "Yesterday".
//      A session at 11pm yesterday viewed at 9am today is only 10
//      hours of duration but a full calendar day apart.
//
//   3. Years are shown the moment the year is anything other than
//      the current year. A "May 11" with no year next to a 2024
//      session is misleading; users assume "this year".
//
// Helpers in this file are pure / side-effect-free; tests can call
// them with a fixed `now` via the optional parameter where the
// math depends on the current moment.

/// "Today" / "Yesterday" / "Mon, Apr 5" / "Apr 5, 2024"
///
/// Use this for day-separator headers in chat lists, session
/// dividers, and any place the goal is "what calendar day was
/// this". `now` defaults to `DateTime.now()` but is overridable
/// so tests pin a clock.
String formatDayLabel(DateTime? dt, {DateTime? now}) {
  if (dt == null) return '';
  final local = dt.toLocal();
  final reference = (now ?? DateTime.now()).toLocal();

  final today = DateTime(reference.year, reference.month, reference.day);
  final that = DateTime(local.year, local.month, local.day);
  final dayDiff = today.difference(that).inDays;

  if (dayDiff == 0) return 'Today';
  if (dayDiff == 1) return 'Yesterday';

  const weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  // Within the last week: weekday name reads more naturally than
  // a date (the user has internal context for "Wed" but has to do
  // math for "Apr 5"). After a week, switch to month-day, and add
  // the year the moment it's not the current year.
  if (dayDiff < 7) {
    return weekdays[local.weekday - 1];
  }
  final sameYear = local.year == reference.year;
  if (sameYear) {
    return '${months[local.month - 1]} ${local.day}';
  }
  return '${months[local.month - 1]} ${local.day}, ${local.year}';
}

/// "Today" / "Yesterday" / "Apr 5" / "Apr 5, 2024"
///
/// Same as [formatDayLabel] but skips the weekday format — used by
/// session-history dividers where a weekday is visual noise.
String formatDayCompact(DateTime? dt, {DateTime? now}) {
  if (dt == null) return '';
  final local = dt.toLocal();
  final reference = (now ?? DateTime.now()).toLocal();

  final today = DateTime(reference.year, reference.month, reference.day);
  final that = DateTime(local.year, local.month, local.day);
  final dayDiff = today.difference(that).inDays;

  if (dayDiff == 0) return 'Today';
  if (dayDiff == 1) return 'Yesterday';

  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  final sameYear = local.year == reference.year;
  if (sameYear) {
    return '${months[local.month - 1]} ${local.day}';
  }
  return '${months[local.month - 1]} ${local.day}, ${local.year}';
}

/// "Apr 5, 2024" — always shows the year. For surfaces where the
/// goal is "show me the exact date", not "how recent is this".
String formatFullDate(DateTime? dt) {
  if (dt == null) return '—';
  final local = dt.toLocal();
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  return '${months[local.month - 1]} ${local.day}, ${local.year}';
}

/// "3:00 PM" — 12-hour clock with AM/PM. Always uses local time.
String formatTime(DateTime? dt) {
  if (dt == null) return '';
  final local = dt.toLocal();
  final hour24 = local.hour;
  final isAm = hour24 < 12;
  var hour = hour24 % 12;
  if (hour == 0) hour = 12;
  final minute = local.minute.toString().padLeft(2, '0');
  return '$hour:$minute ${isAm ? 'AM' : 'PM'}';
}

/// "Today, 3:00 PM" / "Yesterday, 3:00 PM" / "Apr 5, 3:00 PM" /
/// "Apr 5, 2024, 3:00 PM"
///
/// Combined day + time. Use this for inline rows where the time
/// alone would be ambiguous (call history entries, missed-call
/// rows, etc.) — without the day prefix, a call at "3:00 PM" from
/// last week looks like it happened today.
String formatDayTime(DateTime? dt, {DateTime? now}) {
  if (dt == null) return '';
  return '${formatDayCompact(dt, now: now)}, ${formatTime(dt)}';
}

/// "Apr 5, 2024 · 3:00 PM" — full date + time. For session detail
/// surfaces where the user is reading an audit-style record.
String formatFullDateTime(DateTime? dt) {
  if (dt == null) return '—';
  return '${formatFullDate(dt)} · ${formatTime(dt)}';
}

/// "Just now" / "5m ago" / "3h ago" / "2d ago" / "Apr 5" /
/// "Apr 5, 2024"
///
/// Rolling relative time for activity feeds (notifications, missed
/// requests, applied-X-ago). After a week, falls through to a
/// calendar-day format so "Apr 5" reads consistently with the rest
/// of the app.
String formatTimeAgo(DateTime? dt, {DateTime? now}) {
  if (dt == null) return '';
  final local = dt.toLocal();
  final reference = (now ?? DateTime.now()).toLocal();
  final diff = reference.difference(local);

  if (diff.isNegative) return 'Just now';
  if (diff.inSeconds < 60) return 'Just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
  if (diff.inHours < 24) return '${diff.inHours}h ago';
  // Once we cross "days", switch from rolling-24h windows to
  // calendar-day math so "1d ago" doesn't show for a session at
  // 11pm last night viewed at 9am today (10h, but still
  // *yesterday* by calendar).
  final today = DateTime(reference.year, reference.month, reference.day);
  final that = DateTime(local.year, local.month, local.day);
  final dayDiff = today.difference(that).inDays;
  if (dayDiff == 0) return 'Today';
  if (dayDiff == 1) return 'Yesterday';
  if (dayDiff < 7) return '${dayDiff}d ago';
  return formatDayCompact(dt, now: now);
}
