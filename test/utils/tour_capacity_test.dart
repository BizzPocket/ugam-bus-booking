import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/bus_details.dart';
import 'package:occubusbooking/models/passenger.dart';
import 'package:occubusbooking/models/request_line.dart';
import 'package:occubusbooking/models/seat_assignment.dart';
import 'package:occubusbooking/models/seat_layout.dart';
import 'package:occubusbooking/models/seat_type.dart';
import 'package:occubusbooking/models/tour.dart';
import 'package:occubusbooking/models/trip_type.dart';
import 'package:occubusbooking/utils/tour_capacity.dart';

SeatCell _seat(int row, int col, SeatType type, SeatPosition? pos, String id) =>
    SeatCell(row: row, col: col, seatType: type, position: pos, seatId: id);

Bus _bus(String id, List<SeatCell> cells) {
  var maxRow = 0;
  for (final c in cells) {
    if (c.row > maxRow) maxRow = c.row;
  }
  return Bus(
    id: id,
    name: id,
    busType: 'Sleeper',
    layout: BusLayout(rows: maxRow + 1, cols: SeatGridCols.count, grid: cells),
  );
}

// The leg now lives PER REQUEST LINE, so apply [trip] to each line's leg (the
// capacity engine reads the per-line legs, not the passenger-level tripType).
Passenger _p(String id,
        {required List<RequestLine> lines,
        String? groupId,
        TripType trip = TripType.roundTrip}) =>
    Passenger(
      id: id,
      tourId: 't1',
      name: id,
      phone: '+910000000000',
      requestLines: lines.map((l) => l.copyWith(leg: trip)).toList(),
      groupId: groupId,
      tripType: trip,
    );

RequestLine _line(SeatType t, int qty) => RequestLine(seatType: t, qty: qty);

// A passenger who has been ASSIGNED real seats — the persisted state the seat
// GRID reads. [computeActualCapacity] must count these, NOT the engine's
// would-fill plan.
Passenger _pSeated(String id,
        {required List<RequestLine> lines,
        required List<SeatAssignment> seats,
        TripType trip = TripType.roundTrip}) =>
    Passenger(
      id: id,
      tourId: 't1',
      name: id,
      phone: '+910000000000',
      requestLines: lines.map((l) => l.copyWith(leg: trip)).toList(),
      assignedSeats: seats,
      tripType: trip,
    );

// A passenger whose travelled leg is finished: completeOutboundLeg() clears
// their seats and flags journeyDone. Their request lines stay on record.
Passenger _pDone(String id,
        {required List<RequestLine> lines, TripType trip = TripType.outboundOnly}) =>
    Passenger(
      id: id,
      tourId: 't1',
      name: id,
      phone: '+910000000000',
      requestLines: lines.map((l) => l.copyWith(leg: trip)).toList(),
      tripType: trip,
      assignedSeats: const [],
      journeyDone: true,
    );

Tour _tour(List<Bus> buses, List<Passenger> ps) => Tour(
      title: 'T',
      fromCity: 'A',
      toCity: 'B',
      departureDate: DateTime(2026, 1, 1),
      pricePerSeat: 100,
      buses: buses,
      passengers: ps,
    );

void main() {
  group('computeTourCapacity — never reads FULL while a seat is empty', () {
    test('two strangers, one Double Sofa: 1 berth free + 1 needs decision', () {
      final tour = _tour([
        _bus('b1', [_seat(0, 4, SeatType.doubleSofa, SeatPosition.lower, 'DL1')])
      ], [
        _p('A', lines: [_line(SeatType.singleSofa, 1)]),
        _p('B', lines: [_line(SeatType.singleSofa, 1)]),
      ]);

      final cap = computeTourCapacity(tour);
      expect(cap.capacity, 2);
      expect(cap.occupied, 1);
      expect(cap.free, 1, reason: 'the other Double Sofa berth is empty');
      expect(cap.needsDecision, 1, reason: 'B is blocked by stranger-share');
      expect(cap.isFull, isFalse, reason: 'a seat is free — must NOT read full');
    });

    test('seater request with only a sofa free: seat free + 1 needs decision',
        () {
      final tour = _tour([
        _bus('b1', [_seat(0, 0, SeatType.singleSofa, SeatPosition.upper, 'SU1')])
      ], [
        _p('A', lines: [_line(SeatType.seater, 1)]),
      ]);

      final cap = computeTourCapacity(tour);
      expect(cap.free, 1);
      expect(cap.needsDecision, 1);
      expect(cap.isFull, isFalse);
    });

    test('everyone fits: free seats, zero needs-decision', () {
      final tour = _tour([
        _bus('b1', [
          _seat(0, 0, SeatType.singleSofa, SeatPosition.upper, 'SU1'),
          _seat(0, 1, SeatType.singleSofa, SeatPosition.lower, 'SL1'),
        ])
      ], [
        _p('A', lines: [_line(SeatType.singleSofa, 1)]),
      ]);

      final cap = computeTourCapacity(tour);
      expect(cap.capacity, 2);
      expect(cap.occupied, 1);
      expect(cap.free, 1);
      expect(cap.needsDecision, 0);
    });

    test('one-way holder leaves the busier leg full (leg-honest 0 free)', () {
      final tour = _tour([
        _bus('b1', [_seat(0, 0, SeatType.singleSofa, SeatPosition.upper, 'SU1')])
      ], [
        _p('A', lines: [_line(SeatType.singleSofa, 1)], trip: TripType.outboundOnly),
        _p('B', lines: [_line(SeatType.singleSofa, 1)]),
      ]);

      final cap = computeTourCapacity(tour);
      // The single berth's GO slot is taken; a round-trip rider needs both legs.
      expect(cap.occupied, 1);
      expect(cap.free, 0);
      expect(cap.needsDecision, 1, reason: 'B surfaces as needing a decision');
    });
  });

  group('computeTourCapacity — per-leg free is plan-derived, never inverted', () {
    test('outbound-only rider surfaces a RETURN-only-free seat (not outbound)',
        () {
      // 3 single berths; one outbound-only rider takes the GO slot of one. That
      // seat returns EMPTY → 2 fully empty + 1 return-only empty (the screenshot
      // case). The free room is on the RETURN leg, so retOnlyFree carries it.
      final tour = _tour([
        _bus('b1', [
          _seat(0, 0, SeatType.singleSofa, SeatPosition.upper, 'SU1'),
          _seat(0, 1, SeatType.singleSofa, SeatPosition.lower, 'SL1'),
          _seat(1, 1, SeatType.singleSofa, SeatPosition.lower, 'SL2'),
        ])
      ], [
        _p('A',
            lines: [_line(SeatType.singleSofa, 1)],
            trip: TripType.outboundOnly),
      ]);

      final cap = computeTourCapacity(tour);
      expect(cap.free, 2, reason: 'two seats are empty on BOTH legs');
      expect(cap.retOnlyFree, 1, reason: "A's seat returns empty");
      expect(cap.goOnlyFree, 0);
    });

    test('blocked return rider no longer fabricates an outbound-only-free line',
        () {
      // The exact screenshot inversion: a returnOnly rider the engine CANNOT
      // seat (seater request, only sofas exist) inflates raw return demand above
      // go demand. The old banner read `goDemand < retDemand` and printed
      // "outbound-only free" — pointing at the wrong leg. Plan-derived truth:
      // the placed legs are balanced, so NEITHER one-way surplus exists.
      final tour = _tour([
        _bus('b1', [
          _seat(0, 0, SeatType.singleSofa, SeatPosition.upper, 'SU1'),
          _seat(0, 1, SeatType.singleSofa, SeatPosition.lower, 'SL1'),
        ])
      ], [
        _p('A', lines: [_line(SeatType.singleSofa, 1)]),
        _p('B', lines: [_line(SeatType.seater, 1)], trip: TripType.returnOnly),
      ]);

      final cap = computeTourCapacity(tour);
      expect(cap.needsDecision, 1, reason: 'B (seater on a sofa bus) is blocked');
      expect(cap.goOnlyFree, 0, reason: 'no phantom outbound-only-free seat');
      expect(cap.retOnlyFree, 0, reason: 'placed legs are balanced');
      expect(cap.free, 1);
    });
  });

  group('computeTourCapacity — a finished GO leg is excluded', () {
    test('journeyDone outbound rider no longer occupies a berth or blocks one',
        () {
      // Two single berths. One outbound-only rider finished the GO leg
      // (journeyDone, seats cleared) and one round-trip rider remains. The
      // finished rider must NOT be re-seated by the engine: only the round-trip
      // rider counts, leaving one berth genuinely free.
      final tour = _tour([
        _bus('b1', [
          _seat(0, 0, SeatType.singleSofa, SeatPosition.upper, 'SU1'),
          _seat(0, 1, SeatType.singleSofa, SeatPosition.lower, 'SL1'),
        ])
      ], [
        _pDone('A', lines: [_line(SeatType.singleSofa, 1)]),
        _p('B', lines: [_line(SeatType.singleSofa, 1)]),
      ]);

      final cap = computeTourCapacity(tour);
      expect(cap.occupied, 1, reason: 'only the round-trip rider B is on the bus');
      expect(cap.free, 1, reason: "A's berth returns empty — sellable for return");
      expect(cap.needsDecision, 0, reason: 'a finished rider is not pending');
      expect(cap.returnSeatsFree, 1, reason: 'one return seat is sellable');
    });
  });

  group('computeTourCapacity — same-type one-way split (the matrix bug)', () {
    test('1 seater GO + 1 seater RET on one booking occupy ONE berth, not two',
        () {
      // ONE booking requests the SAME seat type on OPPOSITE legs: a seater
      // GO-only line + a seater RET-only line. The engine leg-shares them onto
      // ONE physical seat (GO slot + RET slot of the same berth), so the busier
      // leg is 1 — capacity must read 1 occupied / 1 free, NOT 2. The per-seat
      // legs are what keep [freeByType] from double-counting the reuse.
      final matrix = Passenger(
        id: 'matrix',
        tourId: 't1',
        name: 'matrix',
        phone: '+910000000000',
        requestLines: const [
          RequestLine(
              seatType: SeatType.seater, qty: 1, leg: TripType.outboundOnly),
          RequestLine(
              seatType: SeatType.seater, qty: 1, leg: TripType.returnOnly),
        ],
      );
      final tour = _tour([
        _bus('b1', [
          _seat(0, 0, SeatType.seater, null, 'ST1'),
          _seat(0, 1, SeatType.seater, null, 'ST2'),
        ])
      ], [
        matrix,
      ]);

      final cap = computeTourCapacity(tour);
      expect(cap.capByType[SeatType.seater], 2);
      expect(cap.freeByType[SeatType.seater]?.round, 1,
          reason: 'GO+RET share one berth → max(GO,RET)=1 occupied seater');
      expect(cap.occupied, 1,
          reason: 'the reused berth is the busier leg = 1, not 2');
      expect(cap.free, 1, reason: 'the other seater seat is genuinely empty');
      expect(cap.needsDecision, 0);
    });
  });

  group('computeTourCapacity — by-type counts WHOLE tiles, not half-berths', () {
    test('capByType is in tiles: a Double Sofa cell counts as ONE unit, not two',
        () {
      // Two double-sofa tiles, empty. The "empty by type" row and the demand
      // summary must speak the same unit — "a Double Sofa counts as ONE unit" —
      // so a bus of two doubles reads capByType 2 (tiles), never 4 (berths).
      final tour = _tour([
        _bus('b1', [
          _seat(0, 4, SeatType.doubleSofa, SeatPosition.lower, 'DL1'),
          _seat(1, 4, SeatType.doubleSofa, SeatPosition.lower, 'DL2'),
        ])
      ], const []);

      final cap = computeTourCapacity(tour);
      expect(cap.capByType[SeatType.doubleSofa], 2,
          reason: 'two double tiles = 2 units, not 4 berths');
      expect(cap.freeByType[SeatType.doubleSofa]?.round, 2,
          reason: 'both doubles are wholly empty → 2 bookable doubles');
    });

    test(
        'a half-occupied Double Sofa is NOT a free double (the miscount bug)',
        () {
      // Two double tiles. One round-trip single rider takes ONE half of DL1,
      // leaving its other half physically empty; DL2 is wholly empty. A new
      // Double Sofa request (a pair) can only take DL2 — the half-open DL1 can't
      // seat a fresh pair. The OLD berth math read `4 − max(go,ret)=1 = 3` free,
      // over-reporting bookable doubles; the fix counts WHOLE-empty tiles → 1.
      final tour = _tour([
        _bus('b1', [
          _seat(0, 4, SeatType.doubleSofa, SeatPosition.lower, 'DL1'),
          _seat(1, 4, SeatType.doubleSofa, SeatPosition.lower, 'DL2'),
        ])
      ], [
        _p('A', lines: [_line(SeatType.singleSofa, 1)]),
      ]);

      final cap = computeTourCapacity(tour);
      expect(cap.capByType[SeatType.doubleSofa], 2);
      expect(cap.freeByType[SeatType.doubleSofa]?.round, 1,
          reason:
              'only the wholly-empty DL2 is a bookable double; the half-open '
              'DL1 is not — old berth math wrongly said 3');
      expect(cap.free, 3,
          reason: 'headline berth-free (2 empty berths on DL2 + 1 on DL1) is '
              'unchanged — only the by-type UNIT changed');
    });

    test('leg split: an outbound-only holder makes the seat RETURN-only free',
        () {
      // Two single sofas. One outbound-only rider takes the GO slot of SU1,
      // which returns EMPTY. SU1 is free on RETURN only; SU2 is free on both.
      // The by-type breakdown must read round=1 (SU2) + retOnly=1 (SU1) so the
      // agent sees a return-only single they can still sell.
      final tour = _tour([
        _bus('b1', [
          _seat(0, 0, SeatType.singleSofa, SeatPosition.upper, 'SU1'),
          _seat(0, 1, SeatType.singleSofa, SeatPosition.lower, 'SL1'),
        ])
      ], [
        _p('A',
            lines: [_line(SeatType.singleSofa, 1)], trip: TripType.outboundOnly),
      ]);

      final cap = computeTourCapacity(tour);
      final s = cap.freeByType[SeatType.singleSofa]!;
      expect(s.round, 1, reason: 'SL1 is empty on both legs');
      expect(s.retOnly, 1, reason: "SU1's GO slot is held; it returns empty");
      expect(s.goOnly, 0);
      expect(s.total, 2);
    });

    test('leg split: a Double free on GO but held on RETURN is go-only', () {
      // One double tile. A return-only single rider holds one berth coming back,
      // so BOTH berths are empty going out → a go-only pair still fits (goOnly),
      // but no round-trip pair does (retOnly berth is held on return).
      final tour = _tour([
        _bus('b1', [
          _seat(0, 4, SeatType.doubleSofa, SeatPosition.lower, 'DL1'),
        ])
      ], [
        _p('A',
            lines: [_line(SeatType.singleSofa, 1)], trip: TripType.returnOnly),
      ]);

      final cap = computeTourCapacity(tour);
      final d = cap.freeByType[SeatType.doubleSofa]!;
      expect(d.round, 0, reason: 'a return rider holds a berth — no round pair');
      expect(d.goOnly, 1, reason: 'both berths are empty going → go-only pair fits');
      expect(d.retOnly, 0);
    });
  });

  group('computeActualCapacity — reflects real assignedSeats, not the plan', () {
    test('unassigned demand reads FULL in the plan but EMPTY in actual (the bug)',
        () {
      // The reported bug: two riders REQUEST the only two berths but neither is
      // actually seated yet. The engine plan fills them → the overview said
      // "ભરાઈ ગઈ / full"; the grid (real seats) is empty. Actual capacity must
      // report the bus as genuinely empty so the two can never disagree.
      final tour = _tour([
        _bus('b1', [
          _seat(0, 0, SeatType.singleSofa, SeatPosition.upper, 'SU1'),
          _seat(0, 1, SeatType.singleSofa, SeatPosition.lower, 'SL1'),
        ])
      ], [
        _p('A', lines: [_line(SeatType.singleSofa, 1)]),
        _p('B', lines: [_line(SeatType.singleSofa, 1)]),
      ]);

      // Engine plan: both placeable → the OLD overview read the bus FULL.
      expect(computeTourCapacity(tour).byBus['b1']!.free, 0);

      // Actual seats: nobody is assigned → the bus is genuinely EMPTY.
      final actual = computeActualCapacity(tour);
      expect(actual.byBus['b1']!.occupied, 0);
      expect(actual.byBus['b1']!.free, 2, reason: 'no seat is actually assigned');
      expect(actual.free, 2);
      expect(actual.isFull, isFalse);
    });

    test('counts real assignedSeats and agrees with occupiedBerthsFor', () {
      final tour = _tour([
        _bus('b1', [
          _seat(0, 0, SeatType.singleSofa, SeatPosition.upper, 'SU1'),
          _seat(0, 1, SeatType.singleSofa, SeatPosition.lower, 'SL1'),
        ])
      ], [
        _pSeated('A',
            lines: [_line(SeatType.singleSofa, 1)],
            seats: const [SeatAssignment(busId: 'b1', seatId: 'SU1')]),
      ]);

      final actual = computeActualCapacity(tour);
      expect(actual.capacity, 2);
      expect(actual.byBus['b1']!.occupied, 1);
      expect(actual.byBus['b1']!.free, 1);
      expect(actual.occupied, tour.occupiedBerthsFor('b1'),
          reason: 'matches the model helper the grid header uses');
    });

    test('a genuinely full bus reads full', () {
      final tour = _tour([
        _bus('b1', [
          _seat(0, 0, SeatType.singleSofa, SeatPosition.upper, 'SU1'),
          _seat(0, 1, SeatType.singleSofa, SeatPosition.lower, 'SL1'),
        ])
      ], [
        _pSeated('A',
            lines: [_line(SeatType.singleSofa, 1)],
            seats: const [SeatAssignment(busId: 'b1', seatId: 'SU1')]),
        _pSeated('B',
            lines: [_line(SeatType.singleSofa, 1)],
            seats: const [SeatAssignment(busId: 'b1', seatId: 'SL1')]),
      ]);

      final actual = computeActualCapacity(tour);
      expect(actual.byBus['b1']!.free, 0);
      expect(actual.isFull, isTrue);
    });

    test('leg-aware: an outbound-only holder fills GO, leaves RETURN free', () {
      final tour = _tour([
        _bus('b1', [
          _seat(0, 0, SeatType.singleSofa, SeatPosition.upper, 'SU1'),
        ])
      ], [
        _pSeated('A',
            lines: [_line(SeatType.singleSofa, 1)],
            seats: const [SeatAssignment(busId: 'b1', seatId: 'SU1')],
            trip: TripType.outboundOnly),
      ]);

      final actual = computeActualCapacity(tour);
      final bc = actual.byBus['b1']!;
      expect(bc.goOccupied, 1);
      expect(bc.retOccupied, 0, reason: 'the seat returns empty');
      expect(bc.free, 0, reason: 'busier (GO) leg is full → no round-trip seat');
      expect(actual.legsSymmetric, isFalse);
    });
  });

  group('computeActualCapacity — per-bus free-by-type, leg-aware from real seats',
      () {
    test('mixed bus: round / return-only / go-only tiles bucket per type', () {
      // A bus with two singles, one double, one seater. Actual assignments:
      //  * SU1 — round-trip rider → taken BOTH legs (not free any leg).
      //  * SL1 — outbound-only rider → free RETURNING only (single retOnly).
      //  * DL1 — untouched double → free BOTH legs (double round).
      //  * ST1 — untouched seater → free BOTH legs (seater round).
      final tour = _tour([
        _bus('b1', [
          _seat(0, 0, SeatType.singleSofa, SeatPosition.upper, 'SU1'),
          _seat(0, 1, SeatType.singleSofa, SeatPosition.lower, 'SL1'),
          _seat(1, 4, SeatType.doubleSofa, SeatPosition.lower, 'DL1'),
          _seat(2, 0, SeatType.seater, null, 'ST1'),
        ])
      ], [
        _pSeated('A',
            lines: [_line(SeatType.singleSofa, 1)],
            seats: const [
              SeatAssignment(busId: 'b1', seatId: 'SU1', leg: TripType.roundTrip)
            ]),
        _pSeated('B',
            lines: [_line(SeatType.singleSofa, 1)],
            seats: const [
              SeatAssignment(
                  busId: 'b1', seatId: 'SL1', leg: TripType.outboundOnly)
            ],
            trip: TripType.outboundOnly),
      ]);

      final byType = computeActualCapacity(tour).freeByType['b1']!;
      final single = byType[SeatType.singleSofa]!;
      expect(single.round, 0, reason: 'SU1 taken both legs; SL1 taken going');
      expect(single.retOnly, 1, reason: 'SL1 returns empty → return-only single');
      expect(single.goOnly, 0);

      expect(byType[SeatType.doubleSofa]!.round, 1, reason: 'DL1 wholly empty');
      expect(byType[SeatType.seater]!.round, 1, reason: 'ST1 wholly empty');
    });

    test('a half-occupied double is a free double on NEITHER leg', () {
      // One round-trip single rider takes HALF of DL1; a fresh pair can't sit
      // there on either leg, so the double lands in no free bucket.
      final tour = _tour([
        _bus('b1', [
          _seat(0, 4, SeatType.doubleSofa, SeatPosition.lower, 'DL1'),
          _seat(1, 4, SeatType.doubleSofa, SeatPosition.lower, 'DL2'),
        ])
      ], [
        _pSeated('A',
            lines: [_line(SeatType.singleSofa, 1)],
            seats: const [
              SeatAssignment(busId: 'b1', seatId: 'DL1', leg: TripType.roundTrip)
            ]),
      ]);

      final d = computeActualCapacity(tour).freeByType['b1']![SeatType.doubleSofa]!;
      expect(d.round, 1, reason: 'only the wholly-empty DL2 is a bookable double');
      expect(d.total, 1, reason: 'the half-taken DL1 is free on no leg');
    });

    test('a fully-assigned bus has zero free of every type', () {
      final tour = _tour([
        _bus('b1', [
          _seat(0, 0, SeatType.singleSofa, SeatPosition.upper, 'SU1'),
          _seat(0, 1, SeatType.singleSofa, SeatPosition.lower, 'SL1'),
        ])
      ], [
        _pSeated('A',
            lines: [_line(SeatType.singleSofa, 1)],
            seats: const [
              SeatAssignment(busId: 'b1', seatId: 'SU1', leg: TripType.roundTrip)
            ]),
        _pSeated('B',
            lines: [_line(SeatType.singleSofa, 1)],
            seats: const [
              SeatAssignment(busId: 'b1', seatId: 'SL1', leg: TripType.roundTrip)
            ]),
      ]);

      final s = computeActualCapacity(tour).freeByType['b1']![SeatType.singleSofa]!;
      expect(s.total, 0, reason: 'both singles are taken round-trip');
    });
  });

  group('computeTourCapacity — layout deferred (2G Phase 2)', () {
    test('null layout uses total_seats so Home does not claim 0 free', () {
      final tour = _tour([
        Bus(
          id: 'b1',
          name: 'Bus 1',
          busType: 'Sleeper',
          totalSeatsLegacy: 40,
          // layout deliberately null — cold-start projection
        ),
      ], [
        _pSeated(
          'A',
          lines: [_line(SeatType.singleSofa, 1)],
          seats: const [SeatAssignment(busId: 'b1', seatId: 'SU1')],
        ),
      ]);

      final cap = computeTourCapacity(tour);
      expect(cap.capacity, 40);
      expect(cap.free, 39,
          reason: 'must not report free=0 while layout jsonb is still loading');
      expect(cap.byBus['b1']!.capacity, 40);
      expect(cap.byBus['b1']!.free, 39);
    });
  });

  // The twin of the group above. [computeActualCapacity] drives the tour
  // overview meter and every per-bus row; without the SAME total_seats fallback
  // those surfaces read 0/0 for a 37-seat bus whose layout jsonb is still in
  // flight (or was wiped), while the Requests screen — which routes through
  // [computeTourCapacity] — correctly reads 72/74 off the identical tour.
  group('computeActualCapacity — layout deferred (2G Phase 2)', () {
    Tour twoLayoutlessBuses() => _tour([
          Bus(
            id: 'b1',
            name: 'shivkamal-1',
            busType: 'Sleeper',
            totalSeatsLegacy: 37,
          ),
          Bus(
            id: 'b2',
            name: 'shivkamal-2',
            busType: 'Sleeper',
            totalSeatsLegacy: 37,
          ),
        ], [
          _pSeated(
            'A',
            lines: [_line(SeatType.singleSofa, 2)],
            seats: const [
              SeatAssignment(busId: 'b1', seatId: 'SU1'),
              SeatAssignment(busId: 'b2', seatId: 'SU1'),
            ],
          ),
        ]);

    test('null layout uses total_seats for tour capacity', () {
      final actual = computeActualCapacity(twoLayoutlessBuses());
      expect(actual.capacity, 74,
          reason: 'must agree with computeTourCapacity on the same tour');
      expect(actual.occupied, 2);
      expect(actual.free, 72);
    });

    test('null layout counts real assignments per bus', () {
      final actual = computeActualCapacity(twoLayoutlessBuses());
      expect(actual.byBus['b1']!.capacity, 37);
      expect(actual.byBus['b1']!.goOccupied, 1);
      expect(actual.byBus['b1']!.retOccupied, 1);
      expect(actual.byBus['b2']!.capacity, 37);
      expect(actual.byBus['b2']!.free, 36);
    });

    test('a layout-less bus never reads as full while seats remain', () {
      final actual = computeActualCapacity(twoLayoutlessBuses());
      expect(actual.isFull, isFalse,
          reason: '72 of 74 berths are still sellable');
      expect(actual.byBus['b1']!.free, greaterThan(0));
    });

    test('assignments beyond the legacy count clamp instead of going negative',
        () {
      final tour = _tour([
        Bus(id: 'b1', name: 'Bus 1', busType: 'Sleeper', totalSeatsLegacy: 2),
      ], [
        _pSeated(
          'A',
          lines: [_line(SeatType.singleSofa, 3)],
          seats: const [
            SeatAssignment(busId: 'b1', seatId: 'SU1'),
            SeatAssignment(busId: 'b1', seatId: 'SU2'),
            SeatAssignment(busId: 'b1', seatId: 'SU3'),
          ],
        ),
      ]);

      final actual = computeActualCapacity(tour);
      expect(actual.byBus['b1']!.goOccupied, 2, reason: 'clamped to capacity');
      expect(actual.free, 0);
    });

    test('a loaded layout still wins over the legacy count', () {
      final tour = _tour([
        _bus('b1', [
          _seat(0, 0, SeatType.singleSofa, SeatPosition.upper, 'SU1'),
          _seat(0, 1, SeatType.singleSofa, SeatPosition.upper, 'SU2'),
        ]).copyWith(totalSeatsLegacy: 99),
      ], [
        _pSeated(
          'A',
          lines: [_line(SeatType.singleSofa, 1)],
          seats: const [SeatAssignment(busId: 'b1', seatId: 'SU1')],
        ),
      ]);

      final actual = computeActualCapacity(tour);
      expect(actual.capacity, 2,
          reason: 'the real grid is authoritative once it has loaded');
      expect(actual.free, 1);
    });
  });
}
