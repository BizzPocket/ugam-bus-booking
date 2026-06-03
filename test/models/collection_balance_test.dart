import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/collection.dart';

void main() {
  Collection collection({
    double due = 0,
    double received = 0,
    double refunded = 0,
  }) => Collection(
    tourId: 't1',
    busId: 'bus1',
    passengerId: 'p1',
    amountDue: due,
    amountReceived: received,
    amountRefunded: refunded,
  );

  group('collection balance', () {
    test('overpay — change owed to customer', () {
      final c = collection(due: 1550, received: 1600, refunded: 0);
      expect(c.balance, 50);
      expect(c.isReturnDue, isTrue);
      expect(c.changeToReturn, 50);
      expect(c.stillToCollect, 0);
      expect(c.netCollected, 1600);
    });

    test('shortfall — customer still owes', () {
      final c = collection(due: 1550, received: 1000);
      expect(c.balance, -550);
      expect(c.isShortfall, isTrue);
      expect(c.stillToCollect, 550);
      expect(c.changeToReturn, 0);
    });

    test('square — exact payment', () {
      final c = collection(due: 1550, received: 1550);
      expect(c.isSquare, isTrue);
      expect(c.balance, 0);
    });

    test('with refund — net squares the books', () {
      final c = collection(due: 1550, received: 1600, refunded: 50);
      expect(c.balance, 0);
      expect(c.isSquare, isTrue);
      expect(c.netCollected, 1550);
    });

    test('serialises seat id for per-seat collection rows', () {
      final c = Collection(
        tourId: 't1',
        busId: 'bus1',
        passengerId: 'p1',
        seatId: 'DL4',
        amountDue: 1200,
      );

      final roundTrip = Collection.fromMap(c.toMap());

      expect(roundTrip.seatId, 'DL4');
      expect(roundTrip.amountDue, 1200);
    });

    test('copyWith can clear optional note fields', () {
      final c = Collection(
        tourId: 't1',
        busId: 'bus1',
        passengerId: 'p1',
        seatId: 'SL1',
        note: 'old note',
        collectedBy: 'handler',
      );

      final updated = c.copyWith(note: null, collectedBy: null);

      expect(updated.note, isNull);
      expect(updated.collectedBy, isNull);
    });
  });
}
