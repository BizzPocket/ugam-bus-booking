import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/bus_details.dart';
import 'package:occubusbooking/models/collection.dart';
import 'package:occubusbooking/models/handler_bus_money.dart';
import 'package:occubusbooking/models/passenger.dart';
import 'package:occubusbooking/models/request_line.dart';
import 'package:occubusbooking/models/seat_assignment.dart';
import 'package:occubusbooking/models/seat_layout.dart';
import 'package:occubusbooking/models/seat_type.dart';
import 'package:occubusbooking/models/trip_type.dart';
import 'package:occubusbooking/utils/collection_seat_resolver.dart';

/// The DUPLICATE-COLLECTION bug and the rule that fixes it.
///
/// The handler resolved an existing collection by the full (passenger, bus,
/// seat) triple — the same triple the DB's unique index and
/// `handler_upsert_collection`'s ON CONFLICT use. So a rider who paid on seat A
/// and later sat in seat B missed the lookup, got a brand-new row with a fresh
/// uuid, and the insert did NOT collide: two rows, and their cash folded TWICE
/// by [BusMoneySummary.compute] / [HandlerBusMoney.compute], which sum per
/// collection ROW. It never healed itself either — `reconcileAfterSeatMove`
/// returns early for a same-bus move, so the stale row's seat_id stayed put.
///
/// The counter-pressure, and the reason "one row per rider per bus" would be
/// WRONG: [Bus.amountDueForSeat] prices ONE record per DISTINCT seat (a whole
/// double sofa = one record at the FULL sofa price; two separate seats = two
/// records), and [Bus.amountDueFor] is by definition the sum over exactly those
/// distinct seats. So every test below asserts the pair of invariants the rule
/// has to keep true at once:
///
///   rows(rider, bus)  == distinct seats(rider, bus)
///   Σ row.amountDue   == bus.amountDueFor(rider)
void main() {
  // One of each seat type, known prices:
  //   Double Sofa (whole) 1550 / one berth 775
  //   Single Sofa         1200
  //   Seater               900
  Bus buildBus() => Bus(
    id: 'bus1',
    tourId: 't1',
    name: 'Bus 1',
    pricePerSeat: 1000,
    singleSofaPrice: 1200,
    doubleSofaPrice: 1550,
    seaterPrice: 900,
    layout: BusLayout(
      rows: 3,
      cols: 5,
      grid: const [
        SeatCell(
          row: 0,
          col: 4,
          seatType: SeatType.doubleSofa,
          position: SeatPosition.lower,
          seatId: 'DL1',
        ),
        SeatCell(
          row: 0,
          col: 1,
          seatType: SeatType.singleSofa,
          position: SeatPosition.lower,
          seatId: 'SL1',
        ),
        SeatCell(row: 1, col: 0, seatType: SeatType.seater, seatId: 'ST1'),
      ],
    ),
  );

  // The per-seat-type leg lookup drives pricing, so attach one round-trip
  // request line per type — the same fixture shape fare_calculation_test uses.
  Passenger rider(List<String> seatIds) => Passenger(
    id: 'p1',
    tourId: 't1',
    name: 'Rider',
    phone: '1',
    assignedSeats: [
      for (final s in seatIds) SeatAssignment(busId: 'bus1', seatId: s),
    ],
    requestLines: [
      for (final t in SeatType.values)
        RequestLine(seatType: t, qty: 1, leg: TripType.roundTrip),
    ],
    tripType: TripType.roundTrip,
  );

  /// Replays EXACTLY what the handler's collect sheet does on save: resolve the
  /// row this seat belongs to, rewrite its money at the LIVE per-seat fare, and
  /// commit it into the id-keyed cache. Keying by collection id (not by seat) is
  /// half the fix — a seat-keyed cache would keep the pre-move entry alongside
  /// the re-saved one and double-count locally until the next reload.
  List<Collection> collect(
    List<Collection> rows,
    Bus bus,
    Passenger p,
    String seatId,
    double received,
  ) {
    final existing = collectionRowForSeat(
      passenger: p,
      busId: bus.id,
      seatId: seatId,
      collections: rows,
    );
    final base =
        existing ??
        Collection(
          tourId: 't1',
          busId: bus.id,
          passengerId: p.id,
          seatId: seatId,
        );
    final updated = base.copyWith(
      amountDue: bus.amountDueForSeat(p, seatId),
      amountReceived: received,
    );
    final byId = {for (final r in rows) r.id: r};
    byId[updated.id] = updated;
    return byId.values.toList();
  }

  double collectedOn(Bus bus, Passenger p, List<Collection> rows) =>
      HandlerBusMoney.compute(
        busId: bus.id,
        passengers: [p],
        collections: rows,
        expenses: const [],
        dueForSeat: bus.amountDueForSeat,
      ).collected;

  group('a rider who changes seat', () {
    test('re-uses their existing row instead of opening a second one', () {
      final bus = buildBus();
      // Paid the full single-sofa fare on SL1 …
      var rows = collect([], bus, rider(['SL1']), 'SL1', 1200);
      expect(rows, hasLength(1));

      // … then the agent moved them to the seater ST1. The handler taps the new
      // seat and corrects the cash to the seater fare.
      final moved = rider(['ST1']);
      rows = collect(rows, bus, moved, 'ST1', 900);

      // ONE row, not two — and one row's worth of cash. Before the fix this was
      // two rows and ₹2,100 of "collected" against ₹900 of real money.
      expect(rows, hasLength(1));
      expect(collectedOn(bus, moved, rows), 900);
      expect(
        rows.fold<double>(0, (s, r) => s + r.amountDue),
        bus.amountDueFor(moved),
      );
    });

    test('resolves the stranded row for the seat they now hold', () {
      final paid = Collection(
        tourId: 't1',
        busId: 'bus1',
        passengerId: 'p1',
        seatId: 'SL1',
        amountDue: 1200,
        amountReceived: 1200,
      );
      expect(
        collectionRowForSeat(
          passenger: rider(['ST1']),
          busId: 'bus1',
          seatId: 'ST1',
          collections: [paid],
        )?.id,
        paid.id,
      );
    });

    test('a rider with no rows at all still opens a fresh one', () {
      expect(
        collectionRowForSeat(
          passenger: rider(['ST1']),
          busId: 'bus1',
          seatId: 'ST1',
          collections: const [],
        ),
        isNull,
      );
    });

    test('a row on ANOTHER bus is never adopted', () {
      // Cross-bus moves are a different animal: the fare is re-priced per bus
      // and the row is scoped to its own bus, so bus 2 legitimately opens its
      // own record.
      final other = Collection(
        tourId: 't1',
        busId: 'bus2',
        passengerId: 'p1',
        seatId: 'SL1',
        amountReceived: 1200,
      );
      expect(
        collectionRowForSeat(
          passenger: rider(['ST1']),
          busId: 'bus1',
          seatId: 'ST1',
          collections: [other],
        ),
        isNull,
      );
    });
  });

  group('a rider holding TWO distinct seats', () {
    test('keeps two rows totalling amountDueFor', () {
      final bus = buildBus();
      final p = rider(['SL1', 'ST1']);
      var rows = collect([], bus, p, 'SL1', 1200);
      rows = collect(rows, bus, p, 'ST1', 900);

      // Two seats → two records. Collapsing them would have made the rider's
      // billed total 900 against 2100 owed.
      expect(rows, hasLength(2));
      expect(rows.fold<double>(0, (s, r) => s + r.amountDue), 2100);
      expect(
        rows.fold<double>(0, (s, r) => s + r.amountDue),
        bus.amountDueFor(p),
      );
      expect(collectedOn(bus, p, rows), 2100);
    });

    test('never takes over the row of a seat they still hold', () {
      // THE constraint that stops "seat-agnostic" turning into "collapse the
      // rider onto one row": SL1's record belongs to SL1 while SL1 is held, so
      // a tap on ST1 must miss and open its own.
      final onSL1 = Collection(
        tourId: 't1',
        busId: 'bus1',
        passengerId: 'p1',
        seatId: 'SL1',
        amountDue: 1200,
        amountReceived: 1200,
      );
      expect(
        collectionRowForSeat(
          passenger: rider(['SL1', 'ST1']),
          busId: 'bus1',
          seatId: 'ST1',
          collections: [onSL1],
        ),
        isNull,
      );
    });

    test('two stranded rows pair one-to-one with the two new seats', () {
      // Both of a two-seat rider's seats changed. Each new seat must adopt a
      // DIFFERENT stranded row — if they both claimed the same one, the second
      // save would overwrite the first and a whole seat's cash would vanish.
      final bus = buildBus();
      final older = Collection(
        tourId: 't1',
        busId: 'bus1',
        passengerId: 'p1',
        seatId: 'OLD1',
        amountReceived: 1200,
        createdAt: DateTime(2026, 1, 1),
      );
      final newer = Collection(
        tourId: 't1',
        busId: 'bus1',
        passengerId: 'p1',
        seatId: 'OLD2',
        amountReceived: 900,
        createdAt: DateTime(2026, 1, 2),
      );
      final p = rider(['SL1', 'ST1']);
      final forSL1 = collectionRowForSeat(
        passenger: p,
        busId: 'bus1',
        seatId: 'SL1',
        collections: [newer, older],
      );
      final forST1 = collectionRowForSeat(
        passenger: p,
        busId: 'bus1',
        seatId: 'ST1',
        collections: [newer, older],
      );
      expect(forSL1, isNotNull);
      expect(forST1, isNotNull);
      expect(forSL1!.id, isNot(forST1!.id));

      var rows = collect([newer, older], bus, p, 'SL1', 1200);
      rows = collect(rows, bus, p, 'ST1', 900);
      expect(rows, hasLength(2));
      expect(collectedOn(bus, p, rows), 2100);
      expect(
        rows.fold<double>(0, (s, r) => s + r.amountDue),
        bus.amountDueFor(p),
      );
    });

    test('one stranded row is claimed by only ONE of the two new seats', () {
      // Asymmetric case: one row, two un-rowed seats. The row is adopted once
      // and the other seat opens its own — never both from the same row.
      final stranded = Collection(
        tourId: 't1',
        busId: 'bus1',
        passengerId: 'p1',
        seatId: 'OLD1',
        amountReceived: 1200,
      );
      final p = rider(['SL1', 'ST1']);
      final claims = ['SL1', 'ST1']
          .map(
            (s) => collectionRowForSeat(
              passenger: p,
              busId: 'bus1',
              seatId: s,
              collections: [stranded],
            ),
          )
          .toList();
      expect(claims.where((c) => c?.id == stranded.id), hasLength(1));
      expect(claims.where((c) => c == null), hasLength(1));
    });
  });

  group('a WHOLE double sofa', () {
    test('stays ONE record at the full sofa price', () {
      final bus = buildBus();
      // Both berths of DL1 — two assignment entries on one seatId.
      final p = rider(['DL1', 'DL1']);
      final rows = collect([], bus, p, 'DL1', 1550);
      expect(rows, hasLength(1));
      expect(rows.single.amountDue, 1550);
      expect(rows.single.amountDue, bus.amountDueFor(p));
      expect(collectedOn(bus, p, rows), 1550);
    });

    test('a second tap on the same sofa corrects the record, never adds one', () {
      final bus = buildBus();
      final p = rider(['DL1', 'DL1']);
      var rows = collect([], bus, p, 'DL1', 1000); // part payment
      rows = collect(rows, bus, p, 'DL1', 1550); // the rest
      expect(rows, hasLength(1));
      expect(collectedOn(bus, p, rows), 1550);
    });
  });

  group('berth-suffixed seat ids', () {
    test("'DL1#2' resolves to the same record as 'DL1'", () {
      // A double sofa's two berths are stored as 'DL1' and 'DL1#2'. They are one
      // PHYSICAL seat and therefore one collection record — matching on the raw
      // string would split a whole sofa into two half-price rows.
      final onBerthTwo = Collection(
        tourId: 't1',
        busId: 'bus1',
        passengerId: 'p1',
        seatId: 'DL1#2',
        amountDue: 1550,
        amountReceived: 1550,
      );
      expect(
        collectionRowForSeat(
          passenger: rider(['DL1', 'DL1#2']),
          busId: 'bus1',
          seatId: 'DL1',
          collections: [onBerthTwo],
        )?.id,
        onBerthTwo.id,
      );
    });

    test('a suffixed assignment still counts as the seat being held', () {
      // The rider holds only DL1 (as 'DL1#2'). A stranded row on ANOTHER seat
      // must not be adopted by a tap on a seat the rider does not hold …
      final stranded = Collection(
        tourId: 't1',
        busId: 'bus1',
        passengerId: 'p1',
        seatId: 'SL1',
        amountReceived: 1200,
      );
      expect(
        collectionRowForSeat(
          passenger: rider(['DL1#2']),
          busId: 'bus1',
          seatId: 'ST1', // not held
          collections: [stranded],
        ),
        isNull,
      );
      // … but the seat they DO hold, named without the suffix, adopts it.
      expect(
        collectionRowForSeat(
          passenger: rider(['DL1#2']),
          busId: 'bus1',
          seatId: 'DL1',
          collections: [stranded],
        )?.id,
        stranded.id,
      );
    });

    test('a whole sofa held as DL1 + DL1#2 keeps one row across a move', () {
      final bus = buildBus();
      var rows = collect([], bus, rider(['DL1', 'DL1#2']), 'DL1', 1550);
      // Moved to the single sofa; the sofa's record follows them.
      final moved = rider(['SL1']);
      rows = collect(rows, bus, moved, 'SL1', 1200);
      expect(rows, hasLength(1));
      expect(rows.single.amountDue, bus.amountDueFor(moved));
      expect(collectedOn(bus, moved, rows), 1200);
    });
  });
}
