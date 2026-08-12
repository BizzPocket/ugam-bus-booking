import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/controllers/tour_controller.dart';
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
    test('goLegCompleted is true once every one-way rider is journeyDone', () {
      final tour = _tour([
        _p('G',
            lines: [_line(SeatType.seater, 1)],
            trip: TripType.outboundOnly,
            journeyDone: true),
      ]);
      expect(tour.goLegCompleted, isTrue);
      expect(tour.isReturnPhase, isTrue, reason: 'locked + GO done');
    });

    test('round-trip riders holding return seats do not hold the leg open', () {
      // completeOutboundLeg never flags a round-trip rider — they keep their
      // seats for the ride home. Only the one-way riders answer "is GO over".
      final tour = _tour([
        _p('G',
            lines: [_line(SeatType.seater, 1)],
            trip: TripType.outboundOnly,
            journeyDone: true),
        _p('R', lines: [_line(SeatType.seater, 1)], assigned: [_seat('S1')]),
      ]);
      expect(tour.goLegCompleted, isTrue);
      expect(tour.isReturnPhase, isTrue);
    });

    test('cancelling ONE rider\'s return does not complete the GO leg', () {
      // A locked tour that has NOT departed. The agent cancels one round-trip
      // rider's return, and cancelReturnSeatTransform (tour_controller.dart
      // :3545) demotes them to outbound-only with journeyDone set + seats
      // cleared — byte-for-byte the shape of a rider who finished the outbound.
      // Rider G is still sitting on the bus waiting to go, so the tour's GO leg
      // is plainly not over. `any((p) => p.journeyDone)` said it was.
      final demoted = cancelReturnSeatTransform(
        _p('C', lines: [_line(SeatType.seater, 1)], assigned: [_seat('S1')]),
      )!;
      final stillToTravel = _p('G',
          lines: [_line(SeatType.seater, 1)],
          trip: TripType.outboundOnly,
          assigned: [_seat('S2')]);

      final tour = _tour([demoted, stillToTravel]);

      expect(demoted.journeyDone, isTrue,
          reason: 'the cancel really does set the flag');
      expect(tour.goLegCompleted, isFalse,
          reason: 'G has not ridden the outbound yet');
      expect(tour.isReturnPhase, isFalse,
          reason: 'no return tickets to sell while a rider waits to depart');
    });

    test('one bus arriving does not end the GO leg of a multi-bus tour', () {
      // handler_complete_outbound_leg (046_handler_settlement_and_leg.sql:481)
      // retires ONLY the outbound-only riders whose seats are on the bus that
      // arrived, so bus 1 landing must not put the whole tour in return phase
      // while bus 2 is still on the road.
      final busOneRetired = _p('A',
          lines: [_line(SeatType.seater, 1)],
          trip: TripType.outboundOnly,
          journeyDone: true);
      final busTwoTravelling = _p('B',
          lines: [_line(SeatType.seater, 1)],
          trip: TripType.outboundOnly,
          assigned: [_seat('S9')]);

      final tour = _tour([busOneRetired, busTwoTravelling]);
      expect(tour.goLegCompleted, isFalse);
      expect(tour.isReturnPhase, isFalse);
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
