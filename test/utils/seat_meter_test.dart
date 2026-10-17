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

// THE seat meter ([SeatMeter]) is what every admin "x / n" now reads:
// tour-detail vitals + Buses tab + Seats sticky CTA, dashboard hero, Requests
// banner, manage-buses rows, bus status tally, charts fill bar and tours-list
// rows. These tests pin the agreement those screens used to break on a live
// tour (72/73 vs 68/73; a bus 36/37 on one screen, 35/37 on the next).

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

Passenger _p(
  String id, {
  required SeatType type,
  int qty = 1,
  TripType trip = TripType.roundTrip,
  List<SeatAssignment> seats = const [],
}) =>
    Passenger(
      id: id,
      tourId: 't1',
      name: id,
      phone: '+910000000000',
      requestLines: [RequestLine(seatType: type, qty: qty, leg: trip)],
      tripType: trip,
      assignedSeats: seats,
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

/// What each screen renders, derived exactly the way the screen derives it.
Map<String, String> _screenReadouts(Tour tour, SeatMeter m) => {
      // dashboard hero / Requests banner / tour-detail vitals / Seats CTA /
      // tours-list row: the tour-wide count.
      'tour': '${m.occupied}/${m.capacity}',
      // manage buses / bus status / charts / tour-detail Buses tab: the sum of
      // the per-bus slices must say the same thing as the tour headline.
      'busesSum': '${m.byBus.values.fold<int>(0, (s, b) => s + b.occupied)}/'
          '${m.byBus.values.fold<int>(0, (s, b) => s + b.capacity)}',
    };

void main() {
  late Bus b1;
  late Bus b2;

  setUp(() {
    b1 = _bus('b1', [
      _seat(0, 0, SeatType.singleSofa, SeatPosition.upper, 'SU1'),
      _seat(0, 1, SeatType.singleSofa, SeatPosition.lower, 'SL1'),
      _seat(1, 0, SeatType.singleSofa, SeatPosition.upper, 'SU2'),
    ]);
    b2 = _bus('b2', [
      _seat(0, 0, SeatType.singleSofa, SeatPosition.upper, 'SU1'),
      _seat(0, 1, SeatType.seater, null, 'ST1'),
    ]);
  });

  test('mixed-leg tour, nobody seated: meter = the plan (seats the riders '
      'will take), one GO-only + one RET-only rider share ONE berth', () {
    final tour = _tour([b1, b2], [
      _p('go', type: SeatType.singleSofa, trip: TripType.outboundOnly),
      _p('ret', type: SeatType.singleSofa, trip: TripType.returnOnly),
      _p('rt', type: SeatType.singleSofa),
    ]);
    final plan = computeTourCapacity(tour);
    final actual = computeActualCapacity(tour);
    final m = computeSeatMeter(tour, plan: plan, actual: actual);

    expect(actual.occupied, 0);
    expect(m.fromActual, isFalse);
    expect(m.capacity, 5);
    // Two-leg, whole seats: never 2.5, never a merged 3.
    expect(m.goOccupied, 2);
    expect(m.retOccupied, 2);
    expect(m.occupied, 2);
    expect(m.free, 3);
    final r = _screenReadouts(tour, m);
    expect(r['busesSum'], r['tour'], reason: 'per-bus rows add up');
  });

  test('everyone seated by hand where the engine would re-plan FEWER: '
      'meter = the chart (actual), not the plan', () {
    // A seater request seated by hand on a single sofa: the engine refuses
    // seater-on-sofa (needs decision), so the plan places 0 here while the
    // chart shows 1 — the live 68-vs-72 shape.
    final tour = _tour([b1, b2], [
      _p('s', type: SeatType.seater,
          seats: const [SeatAssignment(busId: 'b1', seatId: 'SU1')]),
      _p('go', type: SeatType.singleSofa, trip: TripType.outboundOnly,
          seats: const [
            SeatAssignment(
                busId: 'b1', seatId: 'SL1', leg: TripType.outboundOnly),
          ]),
      _p('ret', type: SeatType.singleSofa, trip: TripType.returnOnly,
          seats: const [
            SeatAssignment(busId: 'b1', seatId: 'SL1', leg: TripType.returnOnly),
          ]),
    ]);
    final plan = computeTourCapacity(tour);
    final actual = computeActualCapacity(tour);
    final m = computeSeatMeter(tour, plan: plan, actual: actual);

    expect(m.fromActual, isTrue);
    expect(m.occupied, actual.occupied);
    expect(m.occupied, 2, reason: 'SU1 + the leg-shared SL1');
    // Every per-bus slice equals the chart's own leg-aware count.
    for (final b in tour.buses) {
      expect(m.byBus[b.id]!.occupied, tour.occupiedBerthsFor(b.id),
          reason: 'bus ${b.id}: meter must match the seat grid');
    }
    final r = _screenReadouts(tour, m);
    expect(r['busesSum'], r['tour']);
    expect(r['tour'], '2/5');
  });

  test('the meter never under-reads either snapshot', () {
    final tour = _tour([b1, b2], [
      _p('a', type: SeatType.singleSofa,
          seats: const [SeatAssignment(busId: 'b2', seatId: 'SU1')]),
      _p('b', type: SeatType.singleSofa),
      _p('c', type: SeatType.seater),
    ]);
    final plan = computeTourCapacity(tour);
    final actual = computeActualCapacity(tour);
    final m = computeSeatMeter(tour, plan: plan, actual: actual);
    expect(m.occupied, greaterThanOrEqualTo(actual.occupied));
    expect(m.occupied,
        greaterThanOrEqualTo(
            plan.goOccupied > plan.retOccupied
                ? plan.goOccupied
                : plan.retOccupied));
    expect(m.occupied + m.free, m.capacity);
    final r = _screenReadouts(tour, m);
    expect(r['busesSum'], r['tour']);
  });
}
