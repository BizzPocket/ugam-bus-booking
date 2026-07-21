import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/bus_details.dart';
import 'package:occubusbooking/models/bus_type.dart';
import 'package:occubusbooking/models/passenger.dart';
import 'package:occubusbooking/models/request_line.dart';
import 'package:occubusbooking/models/seat_assignment.dart';
import 'package:occubusbooking/models/seat_layout.dart';
import 'package:occubusbooking/models/seat_type.dart';
import 'package:occubusbooking/models/tour.dart';
import 'package:occubusbooking/models/trip_type.dart';

/// Regression for AS-1: the CHARTS tab's `n/total` fill indicator used to fold
/// raw [SeatAssignment] entries per bus, so a seat shared by two opposite
/// one-way riders (GO-only + RET-only on the same physical berth) counted
/// TWICE — the header could read past capacity, e.g. "40/37". `ChartsScreen`
/// has no test seam (it reads a live `TourController` singleton — see
/// `handler_bus_chart_screen_test.dart`), so this pins the leg-aware value
/// `Tour.occupiedBerthsFor` must supply and that the screen now displays,
/// mirroring the fixture pattern in `test/models/tour_leg_occupancy_test.dart`.
Passenger _p(String id, TripType trip, List<String> seats) => Passenger(
      id: id,
      tourId: 't1',
      name: id,
      phone: '+910000000000',
      tripType: trip,
      requestLines: [
        RequestLine(seatType: SeatType.seater, qty: seats.length, leg: trip),
      ],
      assignedSeats: [for (final s in seats) SeatAssignment(busId: 'b1', seatId: s)],
    );

void main() {
  test('charts fill uses the leg-aware count, never the raw entry fold', () {
    final bus = Bus(
      id: 'b1',
      name: 'Shivay',
      busType: 'Sleeper',
      layout: BusLayout.generate(busType: BusType.sleeper, totalSeats: 4),
    );
    final tour = Tour(
      id: 't1',
      title: 't',
      fromCity: 'A',
      toCity: 'B',
      departureDate: DateTime(2026, 7, 1),
      pricePerSeat: 1,
      buses: [bus],
      passengers: [
        _p('p1', TripType.roundTrip, ['S1']),
        _p('p2', TripType.roundTrip, ['S2']),
        _p('p3', TripType.outboundOnly, ['S3']),
        _p('p4', TripType.returnOnly, ['S3']), // shares S3 on the opposite leg
      ],
    );

    // OLD (buggy) fold the screen used: raw assignment entries per bus = 4.
    final rawFold = tour.passengers
        .expand((p) => p.assignedSeats)
        .where((a) => a.busId == 'b1')
        .length;
    expect(rawFold, 4);

    // NEW: the leg-aware berth count is 3 (busier leg), <= capacity — this is
    // the value ChartsScreen's `_FillIndicator` must now display instead of
    // the raw fold above.
    expect(tour.occupiedBerthsFor('b1'), 3);
    expect(tour.occupiedBerthsFor('b1'), lessThan(rawFold));
    expect(tour.occupiedBerthsFor('b1'), lessThanOrEqualTo(bus.totalSeats));
  });
}
