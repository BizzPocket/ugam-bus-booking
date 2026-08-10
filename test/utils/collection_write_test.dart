import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/collection.dart';
import 'package:occubusbooking/utils/collection_write.dart';

/// These exist because the invariant they pin was broken in production code
/// that a widget test could not reach: the write goes through a directly
/// constructed store, so nothing intercepted the row on its way to the RPC.
///
/// The bug: `handler_upsert_collection` conflicts on
/// (passenger_id, bus_id, seat_id). Rewriting an ADOPTED row's seat_id makes
/// that target match nothing, so Postgres attempts an INSERT carrying the
/// adopted row's id and fails on the primary key — the handler cannot record a
/// moved rider's cash at all.
void main() {
  Collection adopted({String seatId = 'ST9', double received = 900}) =>
      Collection(
        id: 'row-1',
        tourId: 't',
        busId: 'b',
        passengerId: 'p',
        seatId: seatId,
        amountDue: received,
        amountReceived: received,
      );

  Collection save({
    Collection? existing,
    String seatId = 'SL1',
    double due = 1200,
    double received = 1200,
    double manualReturned = 0,
    String collectedBy = '',
    String note = '',
  }) =>
      buildCollectionToSave(
        existing: existing,
        tourId: 't',
        busId: 'b',
        passengerId: 'p',
        seatId: seatId,
        due: due,
        received: received,
        manualReturned: manualReturned,
        collectedBy: collectedBy,
        note: note,
      );

  group('seat_id immutability — the upsert conflict target', () {
    test('an ADOPTED row keeps its own seat_id', () {
      // The rider paid on ST9 and has since moved to SL1. The row must stay
      // filed under ST9 or the upsert turns into a PK collision.
      final out = save(existing: adopted(), seatId: 'SL1');

      expect(out.seatId, 'ST9');
      expect(out.id, 'row-1', reason: 'it must still be the SAME row');
    });

    test('a NEW row takes the current seat', () {
      final out = save(existing: null, seatId: 'SL1');
      expect(out.seatId, 'SL1');
    });

    test('a row adopted from the very seat being collected is unchanged', () {
      final out = save(existing: adopted(seatId: 'SL1'), seatId: 'SL1');
      expect(out.seatId, 'SL1');
      expect(out.id, 'row-1');
    });
  });

  group('amounts still apply to an adopted row', () {
    test('due and received are updated even though the seat is not', () {
      final out = save(existing: adopted(), due: 1200, received: 1200);
      expect(out.amountDue, 1200);
      expect(out.amountReceived, 1200);
      expect(out.seatId, 'ST9');
    });

    test('overpayment auto-books as change returned', () {
      final out = save(due: 1000, received: 1200);
      expect(out.amountRefunded, 200);
      expect(out.balance, closeTo(0, Collection.kMoneyEpsilon));
    });

    test('an explicit return overrides the auto-booking', () {
      final out = save(due: 1000, received: 1200, manualReturned: 50);
      expect(out.amountRefunded, 50);
    });

    test('the online slice survives a cash edit', () {
      // amount_online is server-owned. A handler recording cash must not
      // silently reclassify a UPI advance as money in their pocket.
      final withOnline = Collection(
        id: 'row-2',
        tourId: 't',
        busId: 'b',
        passengerId: 'p',
        seatId: 'ST9',
        amountReceived: 400,
        amountOnline: 400,
      );
      final out = save(existing: withOnline, due: 1200, received: 1200);

      expect(out.amountOnline, 400);
      expect(out.netCash, 800, reason: 'only the cash slice is the handler\'s');
    });
  });

  group('blank fields become null, not empty strings', () {
    test('collectedBy and note', () {
      final out = save(collectedBy: '', note: '');
      expect(out.collectedBy, isNull);
      expect(out.note, isNull);
    });

    test('populated values are kept', () {
      final out = save(collectedBy: 'Ramesh', note: 'paid at Surat');
      expect(out.collectedBy, 'Ramesh');
      expect(out.note, 'paid at Surat');
    });
  });
}
