// Guards the priest-side Bible earnings math. The priest's "Earned"/
// "Revenue" tiles and Session History "Earned · Bible" must show the NET
// amount that actually lands in the wallet — i.e. price minus platform
// commission — NOT the gross ticket price.
//
// These expectations mirror the server formula in
// functions/src/bible/verifyAndJoinBibleSession.ts:
//   priestEarning = Math.floor(price * (1 - commission/100))
// credited PER paid registration. If these two ever drift, a priest
// would see one number on the session page and a different amount in
// their wallet — the exact bug this fix removes.
import 'package:flutter_test/flutter_test.dart';
import 'package:gospel_vox/features/shared/data/bible_session_model.dart';

BibleSessionModel _session({int price = 199}) => BibleSessionModel(
      id: 's1',
      priestId: 'p1',
      priestName: 'Speaker',
      priestPhotoUrl: '',
      title: 'Session',
      description: 'desc',
      category: 'Prayer',
      durationMinutes: 60,
      maxParticipants: 0,
      price: price,
      meetingLink: '',
      status: 'completed',
      registrationCount: 0,
    );

void main() {
  group('per-head net earning (mirrors server floor)', () {
    final s = _session(price: 199);

    test('₹199 @ 40% commission → ₹119 (the default split)', () {
      expect(s.priestEarningPerHead(40), 119);
    });

    test('0% commission → full price', () {
      expect(s.priestEarningPerHead(0), 199);
    });

    test('100% commission → 0', () {
      expect(s.priestEarningPerHead(100), 0);
    });

    test('rounding lands with the platform (floor), e.g. 33% → ₹133', () {
      // 199 * 0.67 = 133.33 → floor 133
      expect(s.priestEarningPerHead(33), 133);
    });

    test('default constant matches the 40% server default', () {
      expect(BibleSessionModel.defaultCommissionPercent, 40);
      expect(
        s.priestEarningPerHead(BibleSessionModel.defaultCommissionPercent),
        119,
      );
    });
  });

  group('total net earnings accumulate per-head (matches wallet ledger)', () {
    final s = _session(price: 199);

    test('5 paid @ 40% → 5 × ₹119 = ₹595', () {
      // Server credits floor() PER registration, then they sum — so the
      // total must be paidCount × perHead, never floor(total × rate).
      expect(s.priestNetEarnings(5, 40), 595);
    });

    test('0 paid → ₹0', () {
      expect(s.priestNetEarnings(0, 40), 0);
    });

    test('net is strictly less than gross when commission > 0', () {
      const paid = 3;
      final gross = paid * s.price; // 597
      expect(s.priestNetEarnings(paid, 40), lessThan(gross));
      expect(s.priestNetEarnings(paid, 40), 357); // 3 × 119
    });
  });
}
