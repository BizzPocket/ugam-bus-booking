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

/// Regression for the "38/37 · full while a seat is empty" bug.
///
/// A physical berth offers ONE outbound slot + ONE return slot, so two opposite
/// one-way riders legitimately share a single seat (GO on one, RET on the
/// other) — producing TWO [SeatAssignment] entries on ONE physical berth. The
/// old indicators counted raw entries, so every leg-shared berth pushed the
/// tally +1 past physical occupancy and could read "full" while a seat sat
/// empty. The leg-aware count (busier leg = max(GO, RET)) must not.
Passenger _p(
  String id, {
  required TripType trip,
  required List<String> seats,
  String bus = 'b1',
}) =>
    Passenger(
      id: id,
      tourId: 't1',
      name: id,
      phone: '+910000000000',
      tripType: trip,
      // Leg now lives per request line; occupancy reads goBerths/retBerths from
      // the lines, not the passenger-level tripType. One line carrying [trip]
      // with a berth per assigned seat preserves the original per-passenger leg.
      requestLines: [
        RequestLine(seatType: SeatType.seater, qty: seats.length, leg: trip),
      ],
      assignedSeats: [
        for (final s in seats) SeatAssignment(busId: bus, seatId: s),
      ],
    );

Tour _tour(List<Passenger> passengers, {List<Bus> buses = const []}) => Tour(
      id: 't1',
      title: 't',
      fromCity: 'A',
      toCity: 'B',
      departureDate: DateTime(2026, 7, 1),
      pricePerSeat: 1,
      buses: buses,
      passengers: passengers,
    );

void main() {
  group('Tour leg-aware bus occupancy', () {
    test('opposite one-way riders sharing a berth do not inflate past capacity',
        () {
      final bus = Bus(
        id: 'b1',
        name: 'Shivay',
        busType: 'Sleeper',
        layout: BusLayout.generate(busType: BusType.sleeper, totalSeats: 4),
      );
      final capacity = bus.totalSeats; // >= 4 berths

      final tour = _tour(
        [
          _p('p1', trip: TripType.roundTrip, seats: ['S1']),
          _p('p2', trip: TripType.roundTrip, seats: ['S2']),
          _p('p3', trip: TripType.outboundOnly, seats: ['S3']),
          // Shares S3 with p3 on the OPPOSITE leg — same physical berth.
          _p('p4', trip: TripType.returnOnly, seats: ['S3']),
        ],
        buses: [bus],
      );

      // OLD behaviour: raw assignment entries = 4 on only 3 physical berths.
      // On a 4-berth bus that reads "4/4 → FULL" even though S4 is empty.
      final rawEntries = tour.passengers
          .expand((p) => p.assignedSeats)
          .where((a) => a.busId == 'b1')
          .length;
      expect(rawEntries, 4);

      // NEW behaviour: busier leg = 3 berths used (GO: p1,p2,p3 / RET: p1,p2,p4).
      // Strictly below the raw count, and below capacity → NOT full, seat free.
      expect(tour.occupiedBerthsFor('b1'), 3);
      expect(tour.occupiedBerthsFor('b1'), lessThan(rawEntries));
      expect(tour.occupiedBerthsFor('b1'), lessThan(capacity));
      expect(tour.occupiedBerthsByBus()['b1'], 3);
    });

    test('round-trip occupancy equals physical berths (no regression)', () {
      final tour = _tour([
        _p('p1', trip: TripType.roundTrip, seats: ['S1']),
        // Whole double held solo = two berths on the same seat id.
        _p('p2', trip: TripType.roundTrip, seats: ['S2', 'S2']),
      ]);
      expect(tour.occupiedBerthsFor('b1'), 3); // 1 + 2
      expect(tour.occupiedBerths, 3);
    });

    test('occupiedBerths sums the busier leg per bus across the tour', () {
      final tour = _tour([
        _p('p1', trip: TripType.outboundOnly, seats: ['S1'], bus: 'b1'),
        _p('p2', trip: TripType.returnOnly, seats: ['S1'], bus: 'b1'),
        _p('p3', trip: TripType.roundTrip, seats: ['S1'], bus: 'b2'),
      ]);
      // b1: max(GO 1, RET 1) = 1 ; b2: 1 -> total 2 (NOT the 3 raw entries).
      expect(tour.occupiedBerths, 2);
    });
  });
}
