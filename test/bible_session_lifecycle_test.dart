// Guards the "scheduled time passed but priest never started it" case.
// Such a session keeps status='upcoming' forever (nothing server-side
// flips it), so the model must flag it as `isExpiredUpcoming` once it's
// past (scheduledAt + durationMinutes + 15min grace). Both list screens
// rely on this: the priest list moves these to PAST, the user list hides
// them. The 15-min grace lets a priest still start a few minutes late.
import 'package:flutter_test/flutter_test.dart';
import 'package:gospel_vox/features/shared/data/bible_session_model.dart';

BibleSessionModel _session({
  required String status,
  DateTime? scheduledAt,
  DateTime? startedAt,
  int durationMinutes = 60,
}) =>
    BibleSessionModel(
      id: 's1',
      priestId: 'p1',
      priestName: 'Speaker',
      priestPhotoUrl: '',
      title: 'Session',
      description: 'desc',
      category: 'Prayer',
      scheduledAt: scheduledAt,
      startedAt: startedAt,
      durationMinutes: durationMinutes,
      maxParticipants: 0,
      price: 199,
      meetingLink: '',
      status: status,
      registrationCount: 0,
    );

void main() {
  final now = DateTime.now();

  group('isExpiredUpcoming', () {
    test('future upcoming session is NOT expired', () {
      final s = _session(
        status: 'upcoming',
        scheduledAt: now.add(const Duration(hours: 2)),
      );
      expect(s.isExpiredUpcoming, isFalse);
    });

    test('just past scheduled time but inside grace is NOT expired', () {
      // 60-min session that started 10 min ago → deadline is
      // scheduled + 75 min, still ~65 min away. Priest can start late.
      final s = _session(
        status: 'upcoming',
        scheduledAt: now.subtract(const Duration(minutes: 10)),
        durationMinutes: 60,
      );
      expect(s.isExpiredUpcoming, isFalse);
    });

    test('well past (duration + grace) and never started IS expired', () {
      // Scheduled 3h ago, 60-min slot → deadline was ~1h45m ago.
      final s = _session(
        status: 'upcoming',
        scheduledAt: now.subtract(const Duration(hours: 3)),
        durationMinutes: 60,
      );
      expect(s.isExpiredUpcoming, isTrue);
    });

    test('live session is never "expired upcoming"', () {
      final s = _session(
        status: 'live',
        scheduledAt: now.subtract(const Duration(hours: 3)),
      );
      expect(s.isExpiredUpcoming, isFalse);
    });

    test('completed session is never "expired upcoming"', () {
      final s = _session(
        status: 'completed',
        scheduledAt: now.subtract(const Duration(hours: 3)),
      );
      expect(s.isExpiredUpcoming, isFalse);
    });

    test('cancelled session is never "expired upcoming"', () {
      final s = _session(
        status: 'cancelled',
        scheduledAt: now.subtract(const Duration(hours: 3)),
      );
      expect(s.isExpiredUpcoming, isFalse);
    });

    test('upcoming with no scheduledAt is NOT expired (can\'t tell)', () {
      final s = _session(status: 'upcoming', scheduledAt: null);
      expect(s.isExpiredUpcoming, isFalse);
    });
  });

  // The live-session deadline is EXACTLY startedAt + duration — there
  // is no 15-min grace any more. The instant the duration is up the
  // session is over: not joinable, past its deadline. These tests lock
  // that rule in so a future change can't silently reintroduce grace.
  group('live deadline (no grace)', () {
    test('live, 10 min into a 60-min session → joinable, not past', () {
      final s = _session(
        status: 'live',
        startedAt: now.subtract(const Duration(minutes: 10)),
        durationMinutes: 60,
      );
      expect(s.isJoinable, isTrue);
      expect(s.isPastDeadline, isFalse);
    });

    test('live, exactly at duration end → NOT joinable, past deadline', () {
      // 30-min session started 31 min ago — 1 min past the promised
      // end. With the old +15 grace this was still joinable; now it
      // is not, and no payment can be taken.
      final s = _session(
        status: 'live',
        startedAt: now.subtract(const Duration(minutes: 31)),
        durationMinutes: 30,
      );
      expect(s.isJoinable, isFalse);
      expect(s.isPastDeadline, isTrue);
      expect(s.isEffectivelyLive, isFalse);
      expect(s.isEffectivelyCompleted, isTrue);
    });

    test('live, 5 min past a 60-min session → past deadline (no grace)', () {
      // Old behaviour: still inside the 15-min grace → joinable.
      // New behaviour: the duration is up, so it is over.
      final s = _session(
        status: 'live',
        startedAt: now.subtract(const Duration(minutes: 65)),
        durationMinutes: 60,
      );
      expect(s.isJoinable, isFalse);
      expect(s.isPastDeadline, isTrue);
    });

    test('live with no startedAt → not joinable, not past (cannot tell)', () {
      final s = _session(status: 'live', startedAt: null);
      expect(s.isJoinable, isFalse);
      expect(s.isPastDeadline, isFalse);
    });
  });
}
