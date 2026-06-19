import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/controllers/tour_controller.dart';
import 'package:occubusbooking/models/passenger.dart';
import 'package:occubusbooking/models/request_line.dart';
import 'package:occubusbooking/models/seat_assignment.dart';
import 'package:occubusbooking/models/seat_type.dart';
import 'package:occubusbooking/models/trip_type.dart';

/// Unit tests for the pure transformation behind [TourController.cancelReturnSeat].
///
/// The controller method itself touches GetX + SyncService, but the *decision*
/// — remove vs. demote-to-outbound — is captured by the pure top-level
/// [cancelReturnSeatTransform]. Testing that in isolation keeps these cases
/// free of any Supabase/connectivity plumbing.
///
/// Contract: returns `null` when the rider should be removed outright (a
/// return-only rider never rode), otherwise the demoted passenger (round-trip
/// lines → outbound-only, return-only lines dropped, seats freed, journeyDone).
void main() {
  Passenger build(List<RequestLine> lines, {TripType? tripType}) => Passenger(
        id: 'p1',
        tourId: 't1',
        name: 'Rider',
        phone: '+910000000000',
        tripType: tripType ?? TripType.roundTrip,
        requestLines: lines,
        assignedSeats: [
          SeatAssignment(busId: 'b1', seatId: 'L1'),
          SeatAssignment(busId: 'b1', seatId: 'L2'),
        ],
      );

  test('return-only rider (all lines returnOnly) → null (=> remove)', () {
    final p = build(
      [
        RequestLine(
            seatType: SeatType.singleSofa, qty: 1, leg: TripType.returnOnly),
        RequestLine(
            seatType: SeatType.seater, qty: 1, leg: TripType.returnOnly),
      ],
      tripType: TripType.returnOnly,
    );

    expect(cancelReturnSeatTransform(p), isNull);
  });

  test('round-trip rider (1 roundTrip line) → demoted to outbound-only', () {
    final p = build(
      [RequestLine(seatType: SeatType.doubleSofa, qty: 1, leg: TripType.roundTrip)],
      tripType: TripType.roundTrip,
    );

    final out = cancelReturnSeatTransform(p);
    expect(out, isNotNull);
    // The single round-trip line is now outbound-only.
    expect(out!.requestLines.length, 1);
    expect(out.requestLines.single.leg, TripType.outboundOnly);
    expect(out.requestLines.single.seatType, SeatType.doubleSofa);
    expect(out.requestLines.single.qty, 1);
    // Seats freed, journey flagged done, passenger summary leg outbound-only.
    expect(out.assignedSeats, isEmpty);
    expect(out.journeyDone, isTrue);
    expect(out.tripType, TripType.outboundOnly);
  });

  test(
      'mixed rider (1 roundTrip + 1 returnOnly line) → roundTrip demoted, '
      'returnOnly dropped', () {
    final p = build(
      [
        RequestLine(
            seatType: SeatType.doubleSofa, qty: 1, leg: TripType.roundTrip),
        RequestLine(
            seatType: SeatType.singleSofa, qty: 1, leg: TripType.returnOnly),
      ],
      tripType: TripType.roundTrip,
    );

    final out = cancelReturnSeatTransform(p);
    expect(out, isNotNull);
    // Only the (demoted) former round-trip line survives.
    expect(out!.requestLines.length, 1);
    expect(out.requestLines.single.seatType, SeatType.doubleSofa);
    expect(out.requestLines.single.leg, TripType.outboundOnly);
    // The return-only portion is gone.
    expect(
      out.requestLines.any((l) => l.leg == TripType.returnOnly),
      isFalse,
    );
    expect(out.assignedSeats, isEmpty);
    expect(out.journeyDone, isTrue);
    expect(out.tripType, TripType.outboundOnly);
  });

  test('outbound-only line is preserved (not dropped) on a mixed demote', () {
    final p = build(
      [
        RequestLine(
            seatType: SeatType.seater, qty: 2, leg: TripType.outboundOnly),
        RequestLine(
            seatType: SeatType.singleSofa, qty: 1, leg: TripType.returnOnly),
      ],
      tripType: TripType.roundTrip,
    );

    final out = cancelReturnSeatTransform(p);
    expect(out, isNotNull);
    // The already-outbound-only seater line stays; the return-only line drops.
    expect(out!.requestLines.length, 1);
    expect(out.requestLines.single.seatType, SeatType.seater);
    expect(out.requestLines.single.qty, 2);
    expect(out.requestLines.single.leg, TripType.outboundOnly);
  });
}
