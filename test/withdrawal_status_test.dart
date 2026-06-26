// Locks the shared withdrawal lifecycle: wire<->enum mapping (including
// the legacy/compat cases), the safe unknown->pending fallback, and the
// enriched WithdrawalRecord parsing the priest status screen relies on.
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gospel_vox/features/priest/wallet/data/wallet_models.dart';
import 'package:gospel_vox/features/priest/wallet/data/withdrawal_status.dart';

void main() {
  group('WithdrawalStatus.fromWire', () {
    test('maps every canonical wire value', () {
      expect(WithdrawalStatus.fromWire('pending'), WithdrawalStatus.pending);
      expect(WithdrawalStatus.fromWire('processing'),
          WithdrawalStatus.processing);
      expect(WithdrawalStatus.fromWire('paid'), WithdrawalStatus.paid);
      expect(WithdrawalStatus.fromWire('on_hold'), WithdrawalStatus.onHold);
      expect(WithdrawalStatus.fromWire('blocked'), WithdrawalStatus.blocked);
    });
    test('accepts legacy "completed" as paid', () {
      expect(WithdrawalStatus.fromWire('completed'), WithdrawalStatus.paid);
    });
    test('unknown / null fall back to pending (never lost)', () {
      expect(WithdrawalStatus.fromWire(null), WithdrawalStatus.pending);
      expect(WithdrawalStatus.fromWire('garbage'), WithdrawalStatus.pending);
    });
    test('wire round-trips through fromWire', () {
      for (final s in WithdrawalStatus.values) {
        expect(WithdrawalStatus.fromWire(s.wire), s);
      }
    });
  });

  group('WithdrawalStatus flags', () {
    test('labels are the priest-facing words', () {
      expect(WithdrawalStatus.pending.label, 'Requested');
      expect(WithdrawalStatus.processing.label, 'Processing');
      expect(WithdrawalStatus.paid.label, 'Sent');
      expect(WithdrawalStatus.onHold.label, 'On Hold');
      expect(WithdrawalStatus.blocked.label, 'Cancelled');
    });
    test('terminal / action / happy-path flags', () {
      expect(WithdrawalStatus.paid.isTerminal, isTrue);
      expect(WithdrawalStatus.blocked.isTerminal, isTrue);
      expect(WithdrawalStatus.pending.isTerminal, isFalse);
      expect(WithdrawalStatus.onHold.needsPriestAction, isTrue);
      expect(WithdrawalStatus.paid.needsPriestAction, isFalse);
      expect(WithdrawalStatus.processing.isOnHappyPath, isTrue);
      expect(WithdrawalStatus.onHold.isOnHappyPath, isFalse);
    });
  });

  group('WithdrawalRecord.fromFirestore', () {
    test('parses a paid record with a reference', () {
      final r = WithdrawalRecord.fromFirestore('w1', {
        'amount': 2500,
        'status': 'paid',
        'currency': 'INR',
        'paymentReference': 'HDFC00012345',
        'createdAt': Timestamp.fromMillisecondsSinceEpoch(1000),
        'paidAt': Timestamp.fromMillisecondsSinceEpoch(5000),
      });
      expect(r.status, WithdrawalStatus.paid);
      expect(r.reference, 'HDFC00012345');
      expect(r.currency, 'INR');
      expect(r.statusAt, DateTime.fromMillisecondsSinceEpoch(5000));
    });

    test('blank reference / reason normalise to null', () {
      final r = WithdrawalRecord.fromFirestore('w2', {
        'amount': 100,
        'status': 'pending',
        'paymentReference': '   ',
        'onHoldReason': '',
      });
      expect(r.reference, isNull);
      expect(r.onHoldReason, isNull);
    });

    test('on-hold record carries reason + onHoldAt as statusAt', () {
      final r = WithdrawalRecord.fromFirestore('w3', {
        'amount': 800,
        'status': 'on_hold',
        'onHoldReason': 'Account number invalid',
        'onHoldAt': Timestamp.fromMillisecondsSinceEpoch(9000),
      });
      expect(r.status, WithdrawalStatus.onHold);
      expect(r.onHoldReason, 'Account number invalid');
      expect(r.statusAt, DateTime.fromMillisecondsSinceEpoch(9000));
    });

    test('legacy record (no status) defaults to pending, statusAt=createdAt',
        () {
      final r = WithdrawalRecord.fromFirestore('w4', {
        'amount': 500,
        'createdAt': Timestamp.fromMillisecondsSinceEpoch(2000),
      });
      expect(r.status, WithdrawalStatus.pending);
      expect(r.statusAt, DateTime.fromMillisecondsSinceEpoch(2000));
    });
  });
}
