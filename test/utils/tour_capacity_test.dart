import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/bus_details.dart';
import 'package:occubusbooking/models/passenger.dart';
import 'package:occubusbooking/models/request_line.dart';
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
}
