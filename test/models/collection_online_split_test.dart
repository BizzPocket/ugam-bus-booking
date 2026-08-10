import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/collection.dart';

/// A UPI advance lands in the organiser's bank; the handler never touches it.
/// Folding it into "collected" asks the handler to hand over money they were
/// never given, and leaves outstanding permanently short by that amount. These
/// tests pin the two figures apart.
void main() {
  Collection row({
    double received = 0,
    double online = 0,
    double refunded = 0,
    double due = 0,
  }) =>
      Collection(
        tourId: 't',
        busId: 'b',
        passengerId: 'p',
        amountDue: due,
        amountReceived: received,
        amountOnline: online,
        amountRefunded: refunded,
      );

  group('netCash vs netCollected', () {
    test('all cash: the two agree', () {
      final c = row(received: 1000);
      expect(c.netCollected, 1000);
      expect(c.netCash, 1000);
    });

    test('all online: the rider has paid, the handler holds nothing', () {
      final c = row(received: 1000, online: 1000);
      expect(c.netCollected, 1000);
      expect(c.netCash, 0);
    });

    test('mixed: only the cash slice is the handler\'s', () {
      // The row that made this bug expensive — a rider who paid an advance
      // online and the balance in cash on the bus.
      final c = row(received: 1000, online: 400);
      expect(c.netCollected, 1000);
      expect(c.netCash, 600);
    });

    test('a refund comes out of both', () {
      final c = row(received: 1000, online: 400, refunded: 100);
      expect(c.netCollected, 900);
      expect(c.netCash, 500);
    });

    test('balance is the RIDER position, so online money still settles it', () {
      // A fully prepaid rider owes nothing, even though the handler holds no
      // cash for them. Using netCash here would show them as owing the fare.
      final c = row(due: 1000, received: 1000, online: 1000);
      expect(c.isSquare, isTrue);
      expect(c.stillToCollect, 0);
      expect(c.netCash, 0);
    });
  });

  group('serialization', () {
    test('amount_online is READ from the server', () {
      final c = Collection.fromMap({
        'id': 'c1',
        'tour_id': 't',
        'bus_id': 'b',
        'passenger_id': 'p',
        'amount_received': 500,
        'amount_online': 200,
      });
      expect(c.amountOnline, 200);
      expect(c.netCash, 300);
    });

    test('a row without the column defaults to all-cash', () {
      // Any read path that has not yet been taught the column must not start
      // treating cash as online.
      final c = Collection.fromMap({
        'id': 'c1',
        'tour_id': 't',
        'bus_id': 'b',
        'passenger_id': 'p',
        'amount_received': 500,
      });
      expect(c.amountOnline, 0);
      expect(c.netCash, 500);
    });

    test('amount_online is NEVER written back', () {
      // It is server-owned: confirm_payment_claim writes it and 062's
      // finance_sync_collection books that slice to bank.gateway. A client
      // PATCH echoing a stale value would re-book an online advance as cash.
      final c = row(received: 500, online: 200);
      expect(c.toMap().containsKey('amount_online'), isFalse);
    });

    test('copyWith carries the online slice through a cash edit', () {
      final c = row(received: 500, online: 200);
      final edited = c.copyWith(amountReceived: 900);
      expect(edited.amountOnline, 200);
      expect(edited.netCash, 700);
    });
  });
}
