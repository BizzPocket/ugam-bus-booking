import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/bus_details.dart';
import 'package:occubusbooking/models/passenger.dart';
import 'package:occubusbooking/models/request_line.dart';
import 'package:occubusbooking/models/seat_assignment.dart';
import 'package:occubusbooking/models/seat_layout.dart';
import 'package:occubusbooking/models/seat_type.dart';
import 'package:occubusbooking/models/tour.dart';
import 'package:occubusbooking/models/trip_type.dart';
import 'package:occubusbooking/services/seat_swap_guard.dart';

/// The swap guard judged the INCOMING rider on their coarse
/// `effectiveTripType`. A mixed-leg party (one GO line, one RET line) reads as
/// round-trip there, so moving its RET-only seat onto a single sofa whose GO
/// leg another rider holds was flagged as a GO overbook and offered to bump
/// that rider — on a swap that double-books nothing. The per-seat leg
/// (`legForSeat`) is canonical.
void main() {
  final bus = Bus(
    id: 'b1',
    name: 'b1',
    busType: 'Sleeper',
    layout: BusLayout(
      rows: 2,
      cols: SeatGridCols.count,
      grid: const [
        SeatCell(row: 0, col: 0, seatType: SeatType.singleSofa, seatId: 'S1'),
        SeatCell(row: 1, col: 0, seatType: SeatType.singleSofa, seatId: 'S2'),
      ],
    ),
  );

  Passenger rider(
    String id,
    List<RequestLine> lines,
    List<SeatAssignment> seats,
  ) =>
      Passenger(
        id: id,
        tourId: 't1',
        name: id,
        phone: '+919800000000',
        requestLines: lines,
        assignedSeats: seats,
      );

  // GO-only rider holding S1's outbound leg — must NOT be bumped.
  final goRider = rider(
    'go',
    const [
      RequestLine(
          seatType: SeatType.singleSofa, qty: 1, leg: TripType.outboundOnly),
    ],
    const [
      SeatAssignment(busId: 'b1', seatId: 'S1', leg: TripType.outboundOnly),
    ],
  );
  // RET-only occupant of S1 that leaves in the swap.
  final leaver = rider(
    'leaver',
    const [
      RequestLine(
          seatType: SeatType.singleSofa, qty: 1, leg: TripType.returnOnly),
    ],
    const [
      SeatAssignment(busId: 'b1', seatId: 'S1', leg: TripType.returnOnly),
    ],
  );
  // Mixed-leg party: coarse leg = round-trip, but its S2 seat is RET only.
  final mixed = rider(
    'mixed',
    const [
      RequestLine(
          seatType: SeatType.singleSofa, qty: 1, leg: TripType.outboundOnly),
      RequestLine(
          seatType: SeatType.singleSofa, qty: 1, leg: TripType.returnOnly),
    ],
    const [
      SeatAssignment(busId: 'b1', seatId: 'S2', leg: TripType.returnOnly),
    ],
  );

  final tour = Tour(
    id: 't1',
    title: 't',
    fromCity: 'a',
    toCity: 'b',
    departureDate: DateTime(2026, 9, 1),
    pricePerSeat: 1000,
    buses: [bus],
    passengers: [goRider, leaver, mixed],
  );

  test('fixture: the mixed party reads round-trip coarsely', () {
    expect(mixed.effectiveTripType, TripType.roundTrip);
  });

  test('a RET-only seat swapped onto a GO-held single sofa bumps nobody', () {
    final bumped = SeatSwapGuard.overbookedOn(
      tour,
      busId: 'b1',
      seatId: 'S1',
      incoming: mixed,
      incomingTrip: mixed.legForSeat('S2', busId: 'b1'),
      incomingBerths: 1,
      leavingId: 'leaver',
    );
    expect(bumped, isEmpty);
  });

  test('a real overlap is still caught', () {
    final bumped = SeatSwapGuard.overbookedOn(
      tour,
      busId: 'b1',
      seatId: 'S1',
      incoming: mixed,
      incomingTrip: TripType.outboundOnly,
      incomingBerths: 1,
      leavingId: 'leaver',
    );
    expect(bumped.map((p) => p.id), ['go']);
  });
}
