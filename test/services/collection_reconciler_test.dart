import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/bus_details.dart';
import 'package:occubusbooking/models/collection.dart';
import 'package:occubusbooking/models/passenger.dart';
import 'package:occubusbooking/models/request_line.dart';
import 'package:occubusbooking/models/seat_assignment.dart';
import 'package:occubusbooking/models/seat_layout.dart';
import 'package:occubusbooking/models/seat_type.dart';
import 'package:occubusbooking/models/tour.dart';
import 'package:occubusbooking/models/trip_type.dart';
import 'package:occubusbooking/services/collection_reconciler.dart';

/// Pins the money carry-over when a PAID passenger changes bus.
///
/// Real case: fare is collected before the tour starts, while the rider sits in
/// bus 1's ₹1,500 band. They are then moved to bus 2, whose bands are ₹2,000.
/// Collections are keyed `(passenger_id, bus_id, seat_id)` and fares resolve
/// from the bus the rider currently occupies, so without reconciliation bus 2
/// bills the full ₹2,000 as if nothing was ever paid and the ₹1,500 is stranded
/// on bus 1. What the agent needs is the DIFFERENCE — ₹500 to collect, or money
/// back when the destination is cheaper.
///
/// Seats are laid out so row 0 is the cheap band and row 1 the dear one, which
/// is how the price actually diverges between buses in practice.
Bus _bus({
  required String id,
  required String name,
  required double row0,
  required double row1,
}) => Bus(
  id: id,
  name: name,
  pricePerSeat: row0,
  priceBands: [
    PriceBand(label: 'Front', fromRow: 0, toRow: 0, price: row0),
    PriceBand(label: 'Rear', fromRow: 1, toRow: 1, price: row1),
  ],
  layout: BusLayout(
    rows: 2,
    cols: 4,
    grid: [
      SeatCell(row: 0, col: 0, seatType: SeatType.seater, seatId: '${id}_A'),
      SeatCell(row: 1, col: 0, seatType: SeatType.seater, seatId: '${id}_B'),
      SeatCell(row: 1, col: 1, seatType: SeatType.seater, seatId: '${id}_C'),
    ],
  ),
);

Passenger _rider(
  String id, {
  required List<SeatAssignment> seats,
  TripType leg = TripType.roundTrip,
}) => Passenger(
  id: id,
  tourId: 't1',
  name: id,
  phone: '',
  assignedSeats: seats,
  requestLines: [
    for (final t in SeatType.values) RequestLine(seatType: t, qty: 1, leg: leg),
  ],
  tripType: leg,
);

Collection _row({
  required String passengerId,
  required String busId,
  required String seatId,
  required double due,
  required double received,
  double refunded = 0,
}) => Collection(
  id: '$passengerId-$busId-$seatId',
  tourId: 't1',
  busId: busId,
  passengerId: passengerId,
  seatId: seatId,
  amountDue: due,
  amountReceived: received,
  amountRefunded: refunded,
);

Tour _tour({required List<Bus> buses, required List<Passenger> passengers}) =>
    Tour(
      id: 't1',
      title: 'T',
      fromCity: 'A',
      toCity: 'B',
      departureDate: DateTime(2026, 1, 1),
      pricePerSeat: 1500,
      buses: buses,
      passengers: passengers,
    );

void main() {
  // bus1 bands: row0 ₹1,300 / row1 ₹1,500. bus2: row0 ₹2,000 / row1 ₹2,200.
  final bus1 = _bus(id: 'bus1', name: 'Bus 1', row0: 1300, row1: 1500);
  final bus2 = _bus(id: 'bus2', name: 'Bus 2', row0: 2000, row1: 2200);

  group('cross-bus move of a paid rider', () {
    test('carries the row across and bills only the difference', () {
      // Paid ₹1,500 in bus 1's rear band, then moved into bus 2's ₹2,000 front.
      final p = _rider(
        'p1',
        seats: const [SeatAssignment(busId: 'bus2', seatId: 'bus2_A')],
      );
      final plan = CollectionReconciler.plan(
        tour: _tour(buses: [bus1, bus2], passengers: [p]),
        passengerIds: const ['p1'],
        collections: [
          _row(
            passengerId: 'p1',
            busId: 'bus1',
            seatId: 'bus1_B',
            due: 1500,
            received: 1500,
          ),
        ],
      );

      expect(plan.updates, hasLength(1));
      final moved = plan.updates.single;
      expect(moved.busId, 'bus2', reason: 'cash follows the rider');
      expect(moved.seatId, 'bus2_A');
      expect(moved.amountDue, 2000, reason: 're-priced at the new bus band');
      expect(
        moved.amountReceived,
        1500,
        reason: 'cash already taken is never rewritten',
      );
      // The whole point: ₹500 outstanding, not ₹2,000 all over again.
      expect(moved.stillToCollect, 500);

      final d = plan.deltas.single;
      expect(d.paid, 1500);
      expect(d.due, 2000);
      expect(d.toCollect, 500);
      expect(d.toReturn, 0);
      expect(d.isCollectMore, isTrue);
      expect(d.fromBusNames, ['Bus 1']);
      expect(d.toBusNames, ['Bus 2']);
    });

    test('a cheaper destination leaves money to return, not a shortfall', () {
      // Paid ₹2,200 in bus 2's rear band, moved down to bus 1's ₹1,300 front.
      final p = _rider(
        'p1',
        seats: const [SeatAssignment(busId: 'bus1', seatId: 'bus1_A')],
      );
      final plan = CollectionReconciler.plan(
        tour: _tour(buses: [bus1, bus2], passengers: [p]),
        passengerIds: const ['p1'],
        collections: [
          _row(
            passengerId: 'p1',
            busId: 'bus2',
            seatId: 'bus2_B',
            due: 2200,
            received: 2200,
          ),
        ],
      );

      final moved = plan.updates.single;
      expect(moved.busId, 'bus1');
      expect(moved.amountDue, 1300);
      expect(moved.changeToReturn, 900);

      final d = plan.deltas.single;
      expect(d.isReturnDue, isTrue);
      expect(d.toReturn, 900);
      expect(
        moved.amountRefunded,
        0,
        reason: 'the refund is surfaced, never auto-recorded',
      );
    });

    test('a part-paid rider carries the part payment, not the whole fare', () {
      final p = _rider(
        'p1',
        seats: const [SeatAssignment(busId: 'bus2', seatId: 'bus2_A')],
      );
      final plan = CollectionReconciler.plan(
        tour: _tour(buses: [bus1, bus2], passengers: [p]),
        passengerIds: const ['p1'],
        collections: [
          _row(
            passengerId: 'p1',
            busId: 'bus1',
            seatId: 'bus1_B',
            due: 1500,
            received: 1000,
          ),
        ],
      );
      expect(plan.updates.single.stillToCollect, 1000); // 2000 − 1000
      expect(plan.deltas.single.toCollect, 1000);
    });

    test('an earlier refund counts against what was carried', () {
      // ₹1,500 taken, ₹200 handed back → ₹1,300 of real cash travels with them.
      final p = _rider(
        'p1',
        seats: const [SeatAssignment(busId: 'bus2', seatId: 'bus2_A')],
      );
      final plan = CollectionReconciler.plan(
        tour: _tour(buses: [bus1, bus2], passengers: [p]),
        passengerIds: const ['p1'],
        collections: [
          _row(
            passengerId: 'p1',
            busId: 'bus1',
            seatId: 'bus1_B',
            due: 1500,
            received: 1500,
            refunded: 200,
          ),
        ],
      );
      expect(plan.deltas.single.paid, 1300);
      expect(plan.deltas.single.toCollect, 700); // 2000 − 1300
    });

    test('a one-leg rider is carried at the destination half-fare', () {
      final p = _rider(
        'p1',
        seats: const [SeatAssignment(busId: 'bus2', seatId: 'bus2_A')],
        leg: TripType.outboundOnly,
      );
      final plan = CollectionReconciler.plan(
        tour: _tour(buses: [bus1, bus2], passengers: [p]),
        passengerIds: const ['p1'],
        collections: [
          _row(
            passengerId: 'p1',
            busId: 'bus1',
            seatId: 'bus1_B',
            due: 750,
            received: 750,
          ),
        ],
      );
      expect(plan.updates.single.amountDue, 1000); // half of 2000
      expect(plan.deltas.single.toCollect, 250);
    });
  });

  group('rows that must not move', () {
    test('a rider with no collection row is left entirely alone', () {
      final p = _rider(
        'p1',
        seats: const [SeatAssignment(busId: 'bus2', seatId: 'bus2_A')],
      );
      final plan = CollectionReconciler.plan(
        tour: _tour(buses: [bus1, bus2], passengers: [p]),
        passengerIds: const ['p1'],
        collections: const [],
      );
      expect(plan.isEmpty, isTrue);
    });

    test('an UNSEATED payer keeps their cash where it was taken', () {
      // No seat to re-home onto. The money must stay put and stay visible as
      // detachedCash rather than being silently rewritten or dropped.
      final p = _rider('p1', seats: const []);
      final rows = [
        _row(
          passengerId: 'p1',
          busId: 'bus1',
          seatId: 'bus1_B',
          due: 1500,
          received: 1500,
        ),
      ];
      final plan = CollectionReconciler.plan(
        tour: _tour(buses: [bus1, bus2], passengers: [p]),
        passengerIds: const ['p1'],
        collections: rows,
      );
      expect(plan.updates, isEmpty);
      expect(plan.deltas, isEmpty);
    });

    test('same-bus move into a cheaper band emits return delta', () {
      // Seat changed within bus 1 (rear ₹1500 → front ₹1300): cash follows and
      // the agent must see ₹200 to return — same-bus is not always silent.
      final p = _rider(
        'p1',
        seats: const [SeatAssignment(busId: 'bus1', seatId: 'bus1_A')],
      );
      final plan = CollectionReconciler.plan(
        tour: _tour(buses: [bus1, bus2], passengers: [p]),
        passengerIds: const ['p1'],
        collections: [
          _row(
            passengerId: 'p1',
            busId: 'bus1',
            seatId: 'bus1_B',
            due: 1500,
            received: 1500,
          ),
        ],
      );
      expect(plan.updates.single.seatId, 'bus1_A');
      expect(plan.updates.single.amountDue, 1300);
      expect(plan.deltas.single.toReturn, 200);
    });

    test('re-running against its own output changes nothing', () {
      final p = _rider(
        'p1',
        seats: const [SeatAssignment(busId: 'bus2', seatId: 'bus2_A')],
      );
      final tour = _tour(buses: [bus1, bus2], passengers: [p]);
      final first = CollectionReconciler.plan(
        tour: tour,
        passengerIds: const ['p1'],
        collections: [
          _row(
            passengerId: 'p1',
            busId: 'bus1',
            seatId: 'bus1_B',
            due: 1500,
            received: 1500,
          ),
        ],
      );
      final second = CollectionReconciler.plan(
        tour: tour,
        passengerIds: const ['p1'],
        collections: first.updates,
      );
      expect(second.isEmpty, isTrue, reason: 'reconciliation is idempotent');
    });
  });

  group('multi-seat riders', () {
    test('each row lands on its own seat and is priced there', () {
      // Two seats, both carried from bus 1 onto bus 2's two rear seats.
      final p = _rider(
        'p1',
        seats: const [
          SeatAssignment(busId: 'bus2', seatId: 'bus2_B'),
          SeatAssignment(busId: 'bus2', seatId: 'bus2_C'),
        ],
      );
      final plan = CollectionReconciler.plan(
        tour: _tour(buses: [bus1, bus2], passengers: [p]),
        passengerIds: const ['p1'],
        collections: [
          _row(
            passengerId: 'p1',
            busId: 'bus1',
            seatId: 'bus1_B',
            due: 1500,
            received: 1500,
          ),
          _row(
            passengerId: 'p1',
            busId: 'bus1',
            seatId: 'bus1_C',
            due: 1500,
            received: 1500,
          ),
        ],
      );

      expect(plan.updates, hasLength(2));
      expect(plan.updates.map((c) => c.seatId).toSet(), {'bus2_B', 'bus2_C'});
      expect(plan.updates.every((c) => c.busId == 'bus2'), isTrue);
      expect(plan.updates.every((c) => c.amountDue == 2200), isTrue);

      // Reported once for the person, across both seats: paid 3000, due 4400.
      final d = plan.deltas.single;
      expect(d.paid, 3000);
      expect(d.due, 4400);
      expect(d.toCollect, 1400);
    });

    test('a rider holding seats on two buses keeps each row on its own bus', () {
      // p1 sits on bus1_A and bus2_A. The bus-1 row must stay with bus 1 rather
      // than jump to bus 2 — the cash was taken by bus 1's drawer.
      final p = _rider(
        'p1',
        seats: const [
          SeatAssignment(busId: 'bus1', seatId: 'bus1_A'),
          SeatAssignment(busId: 'bus2', seatId: 'bus2_A'),
        ],
      );
      final plan = CollectionReconciler.plan(
        tour: _tour(buses: [bus1, bus2], passengers: [p]),
        passengerIds: const ['p1'],
        collections: [
          _row(
            passengerId: 'p1',
            busId: 'bus1',
            seatId: 'bus1_B',
            due: 1500,
            received: 1500,
          ),
        ],
      );
      final moved = plan.updates.single;
      expect(moved.busId, 'bus1', reason: 'same-bus seat preferred over a jump');
      expect(moved.seatId, 'bus1_A');
      // Repriced 1500 → 1300 on the same bus: return-due, not silent.
      expect(plan.deltas.single.toReturn, 200);
    });
  });

  group('Wave A explicit band deltas', () {
    test('₹1600 bus1 → ₹2000 bus2 collects ₹400', () {
      final busCheap = _bus(id: 'bus1', name: 'Bus 1', row0: 1600, row1: 1600);
      final busDear = _bus(id: 'bus2', name: 'Bus 2', row0: 2000, row1: 2000);
      final p = _rider(
        'p1',
        seats: const [SeatAssignment(busId: 'bus2', seatId: 'bus2_A')],
      );
      final plan = CollectionReconciler.plan(
        tour: _tour(buses: [busCheap, busDear], passengers: [p]),
        passengerIds: const ['p1'],
        collections: [
          _row(
            passengerId: 'p1',
            busId: 'bus1',
            seatId: 'bus1_A',
            due: 1600,
            received: 1600,
          ),
        ],
      );
      expect(plan.updates.single.stillToCollect, 400);
      expect(plan.deltas.single.toCollect, 400);
    });

    test('₹1600 bus1 → ₹1400 bus2 returns ₹200', () {
      final busA = _bus(id: 'bus1', name: 'Bus 1', row0: 1600, row1: 1600);
      final busB = _bus(id: 'bus2', name: 'Bus 2', row0: 1400, row1: 1400);
      final p = _rider(
        'p1',
        seats: const [SeatAssignment(busId: 'bus2', seatId: 'bus2_A')],
      );
      final plan = CollectionReconciler.plan(
        tour: _tour(buses: [busA, busB], passengers: [p]),
        passengerIds: const ['p1'],
        collections: [
          _row(
            passengerId: 'p1',
            busId: 'bus1',
            seatId: 'bus1_A',
            due: 1600,
            received: 1600,
          ),
        ],
      );
      expect(plan.deltas.single.toReturn, 200);
      expect(plan.updates.single.amountRefunded, 0);
    });

    test('same-bus move into dearer band emits collect delta', () {
      final p = _rider(
        'p1',
        seats: const [SeatAssignment(busId: 'bus1', seatId: 'bus1_B')],
      );
      final plan = CollectionReconciler.plan(
        tour: _tour(buses: [bus1, bus2], passengers: [p]),
        passengerIds: const ['p1'],
        collections: [
          _row(
            passengerId: 'p1',
            busId: 'bus1',
            seatId: 'bus1_A',
            due: 1300,
            received: 1300,
          ),
        ],
      );
      expect(plan.updates, isNotEmpty);
      expect(plan.deltas, isNotEmpty);
      expect(plan.deltas.single.toCollect, 200);
    });

    test('same-bus same-band seat move stays silent (no delta)', () {
      final p = _rider(
        'p1',
        seats: const [SeatAssignment(busId: 'bus1', seatId: 'bus1_C')],
      );
      final plan = CollectionReconciler.plan(
        tour: _tour(buses: [bus1, bus2], passengers: [p]),
        passengerIds: const ['p1'],
        collections: [
          _row(
            passengerId: 'p1',
            busId: 'bus1',
            seatId: 'bus1_B',
            due: 1500,
            received: 1500,
          ),
        ],
      );
      expect(plan.deltas, isEmpty);
    });
  });

  test('a whole double sofa carries as ONE row at the whole-sofa price', () {
    // A whole double is two SeatAssignment entries on one cell but a single
    // collection row — de-duplication must not invent a second row.
    final busD = Bus(
      id: 'busD',
      name: 'Bus D',
      pricePerSeat: 1000,
      doubleSofaPrice: 3000,
      layout: BusLayout(
        rows: 1,
        cols: 2,
        grid: const [
          SeatCell(
            row: 0,
            col: 0,
            seatType: SeatType.doubleSofa,
            position: SeatPosition.lower,
            seatId: 'DL1',
          ),
        ],
      ),
    );
    final p = _rider(
      'p1',
      seats: const [
        SeatAssignment(busId: 'busD', seatId: 'DL1'),
        SeatAssignment(busId: 'busD', seatId: 'DL1'),
      ],
    );
    final plan = CollectionReconciler.plan(
      tour: _tour(buses: [bus1, busD], passengers: [p]),
      passengerIds: const ['p1'],
      collections: [
        _row(
          passengerId: 'p1',
          busId: 'bus1',
          seatId: 'bus1_B',
          due: 1500,
          received: 1500,
        ),
      ],
    );
    expect(plan.updates, hasLength(1));
    expect(plan.updates.single.amountDue, 3000);
    expect(plan.deltas.single.toCollect, 1500);
  });
}
