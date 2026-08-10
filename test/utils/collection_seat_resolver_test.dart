import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/collection.dart';
import 'package:occubusbooking/models/passenger.dart';
import 'package:occubusbooking/models/seat_assignment.dart';
import 'package:occubusbooking/utils/collection_seat_resolver.dart';

/// This resolver decides which collection row a handler's cash lands in, on
/// both the handler chart and the admin collection screen. Getting it wrong
/// costs real money in two directions: adopting the wrong row silently drops a
/// seat's fare, and adopting none writes a duplicate that 062's
/// collections_ledger_sync posts to the ledger a second time.
///
/// The two invariants the doc comment names are the ones under test:
///   rows(rider, bus) == distinct seats(rider, bus)
///   sum(row.amountDue) == bus.amountDueFor(rider)
void main() {
  Passenger riderOn(List<String> seatIds, {String busId = 'bus-1'}) => Passenger(
        id: 'p-1',
        tourId: 'tour-1',
        name: 'Rider',
        phone: '9990000000',
        assignedSeats: [
          for (final s in seatIds) SeatAssignment(busId: busId, seatId: s),
        ],
      );

  var seq = 0;
  Collection rowOn(
    String seatId, {
    String busId = 'bus-1',
    String passengerId = 'p-1',
    double received = 100,
  }) =>
      Collection(
        id: 'row-${seq++}',
        tourId: 'tour-1',
        busId: busId,
        passengerId: passengerId,
        seatId: seatId,
        amountDue: received,
        amountReceived: received,
        // Distinct, increasing timestamps: the resolver sorts oldest-first and
        // pairs orphans by index, so equal timestamps would make the pairing
        // depend on id ordering instead.
        createdAt: DateTime(2026, 1, 1).add(Duration(minutes: seq)),
      );

  setUp(() => seq = 0);

  group('baseSeatId', () {
    test('strips the berth suffix', () {
      expect(baseSeatId('DL1#2'), 'DL1');
      expect(baseSeatId('DL1'), 'DL1');
    });
  });

  group('the seat with its own row', () {
    test('finds it', () {
      final row = rowOn('SL1');
      expect(
        collectionRowForSeat(
          passenger: riderOn(['SL1']),
          busId: 'bus-1',
          seatId: 'SL1',
          collections: [row],
        ),
        row,
      );
    });

    test('both berths of a double sofa share ONE row', () {
      // A sofa is two assignment entries differing only by '#n' but priced as a
      // single unit. Matching on the raw string would earn it two half rows.
      final row = rowOn('DL1');
      final rider = riderOn(['DL1#1', 'DL1#2']);

      expect(
        collectionRowForSeat(
          passenger: rider,
          busId: 'bus-1',
          seatId: 'DL1#1',
          collections: [row],
        ),
        row,
      );
      expect(
        collectionRowForSeat(
          passenger: rider,
          busId: 'bus-1',
          seatId: 'DL1#2',
          collections: [row],
        ),
        row,
      );
    });
  });

  group('orphan adoption after a seat move', () {
    test('a stranded row is adopted by the seat the rider now holds', () {
      // The exact production bug: paid in ST9, moved to SL1. Without adoption
      // the sheet opens blank and the save writes a second row.
      final stranded = rowOn('ST9', received: 900);

      expect(
        collectionRowForSeat(
          passenger: riderOn(['SL1']),
          busId: 'bus-1',
          seatId: 'SL1',
          collections: [stranded],
        ),
        stranded,
      );
    });

    test('a row on a seat the rider STILL holds is never stolen', () {
      // Stealing it would leave the seat that owns it with no record, billing
      // the rider for one seat and losing the other's fare.
      final kept = rowOn('SL1', received: 500);
      final rider = riderOn(['SL1', 'SL2']);

      expect(
        collectionRowForSeat(
          passenger: rider,
          busId: 'bus-1',
          seatId: 'SL2',
          collections: [kept],
        ),
        isNull,
      );
    });

    test('two orphans pair with two un-rowed seats as a bijection', () {
      final a = rowOn('ST1', received: 100);
      final b = rowOn('ST2', received: 200);
      final rider = riderOn(['SL1', 'SL2']);

      final first = collectionRowForSeat(
        passenger: rider,
        busId: 'bus-1',
        seatId: 'SL1',
        collections: [a, b],
      );
      final second = collectionRowForSeat(
        passenger: rider,
        busId: 'bus-1',
        seatId: 'SL2',
        collections: [a, b],
      );

      expect(first, isNotNull);
      expect(second, isNotNull);
      // Never the same row twice — that would collapse two seats onto one
      // record and lose a fare.
      expect(first!.id, isNot(second!.id));
    });

    test('more seats than orphans: the surplus seat opens its own row', () {
      final only = rowOn('ST1');
      final rider = riderOn(['SL1', 'SL2', 'SL3']);

      final resolved = [
        for (final s in ['SL1', 'SL2', 'SL3'])
          collectionRowForSeat(
            passenger: rider,
            busId: 'bus-1',
            seatId: s,
            collections: [only],
          ),
      ];

      expect(resolved.where((r) => r != null).length, 1);
      expect(resolved.where((r) => r == null).length, 2);
    });

    test('the pairing is stable across repeated calls', () {
      // The chart calls this for every seat on every frame to paint the money
      // dot; a pairing that shuffled would make a paid dot hop between seats.
      final a = rowOn('ST1');
      final b = rowOn('ST2');
      final rider = riderOn(['SL1', 'SL2']);

      String? resolve(String seat) => collectionRowForSeat(
            passenger: rider,
            busId: 'bus-1',
            seatId: seat,
            collections: [a, b],
          )?.id;

      final firstPass = [resolve('SL1'), resolve('SL2')];
      final secondPass = [resolve('SL1'), resolve('SL2')];
      expect(secondPass, equals(firstPass));
    });
  });

  group('scoping', () {
    test('another bus\'s row is out of scope', () {
      // Fares are priced per bus and rows are bus-scoped; a cross-bus move is
      // repriced, not adopted.
      final otherBus = rowOn('SL1', busId: 'bus-2');

      expect(
        collectionRowForSeat(
          passenger: riderOn(['SL1']),
          busId: 'bus-1',
          seatId: 'SL1',
          collections: [otherBus],
        ),
        isNull,
      );
    });

    test('another rider\'s row is never adopted', () {
      final someoneElse = rowOn('ST9', passengerId: 'p-2');

      expect(
        collectionRowForSeat(
          passenger: riderOn(['SL1']),
          busId: 'bus-1',
          seatId: 'SL1',
          collections: [someoneElse],
        ),
        isNull,
      );
    });

    test('no rows at all means a new row', () {
      expect(
        collectionRowForSeat(
          passenger: riderOn(['SL1']),
          busId: 'bus-1',
          seatId: 'SL1',
          collections: const [],
        ),
        isNull,
      );
    });

    test('a seat the rider does not hold adopts nothing', () {
      final stranded = rowOn('ST9');

      expect(
        collectionRowForSeat(
          passenger: riderOn(['SL1']),
          busId: 'bus-1',
          seatId: 'SL7',
          collections: [stranded],
        ),
        isNull,
      );
    });
  });
}
