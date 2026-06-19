import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/passenger.dart';
import 'package:occubusbooking/models/request_line.dart';
import 'package:occubusbooking/models/seat_assignment.dart';
import 'package:occubusbooking/models/seat_type.dart';
import 'package:occubusbooking/models/tour.dart';
import 'package:occubusbooking/models/tour_status.dart';
import 'package:occubusbooking/models/trip_type.dart';

Passenger _p(
  String id, {
  required List<RequestLine> lines,
  TripType trip = TripType.roundTrip,
  List<SeatAssignment> assigned = const [],
  bool journeyDone = false,
}) =>
    Passenger(
      id: id,
      tourId: 't1',
      name: id,
      phone: '+910000000000',
      requestLines: lines.map((l) => l.copyWith(leg: trip)).toList(),
      tripType: trip,
      assignedSeats: assigned,
      journeyDone: journeyDone,
    );

RequestLine _line(SeatType t, int qty) => RequestLine(seatType: t, qty: qty);

SeatAssignment _seat(String seatId) =>
    SeatAssignment(busId: 'b1', seatId: seatId);

Tour _tour(List<Passenger> ps, {TourStatus status = TourStatus.locked}) => Tour(
      title: 'T',
      fromCity: 'A',
      toCity: 'B',
      departureDate: DateTime(2026, 1, 1),
      pricePerSeat: 100,
      status: status,
      passengers: ps,
    );

void main() {
  group('Tour.pendingSeatsToAssign — finished riders are not pending', () {
    test('a journeyDone rider does not inflate pending demand', () {
      // Round-trip rider fully seated + an outbound-only rider who finished the
      // GO leg (seats cleared, journeyDone). Nothing is left to assign.
      final tour = _tour([
        _p('R', lines: [_line(SeatType.seater, 1)], assigned: [_seat('S1')]),
        _p('G',
            lines: [_line(SeatType.seater, 1)],
            trip: TripType.outboundOnly,
            journeyDone: true),
      ]);
      expect(tour.pendingSeatsToAssign, 0,
          reason: 'finished GO-leg rider must not reappear as unassigned');
    });

    test('an active unseated rider still counts as pending', () {
      final tour = _tour([
        _p('R', lines: [_line(SeatType.seater, 1)], assigned: [_seat('S1')]),
        _p('P', lines: [_line(SeatType.seater, 1)]),
      ]);
      expect(tour.pendingSeatsToAssign, 1);
    });
  });

  group('Tour return-phase detection', () {
    test('goLegCompleted is true once any rider is journeyDone', () {
      final tour = _tour([
        _p('G',
            lines: [_line(SeatType.seater, 1)],
            trip: TripType.outboundOnly,
            journeyDone: true),
      ]);
      expect(tour.goLegCompleted, isTrue);
      expect(tour.isReturnPhase, isTrue, reason: 'locked + GO done');
    });

    test('not return-phase before the GO leg is completed', () {
      final tour = _tour([
        _p('G', lines: [_line(SeatType.seater, 1)], trip: TripType.outboundOnly),
      ]);
      expect(tour.goLegCompleted, isFalse);
      expect(tour.isReturnPhase, isFalse);
    });

    test('not return-phase while the tour is still being assigned', () {
      final tour = _tour([
        _p('G',
            lines: [_line(SeatType.seater, 1)],
            trip: TripType.outboundOnly,
            journeyDone: true),
      ], status: TourStatus.assigning);
      expect(tour.isReturnPhase, isFalse, reason: 'not locked yet');
    });
  });
}
