import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/passenger.dart';
import 'package:occubusbooking/models/request_line.dart';
import 'package:occubusbooking/models/seat_assignment.dart';
import 'package:occubusbooking/models/seat_type.dart';
import 'package:occubusbooking/models/trip_type.dart';
import 'package:occubusbooking/utils/seat_leg_cancel.dart';

/// Per-seat, per-leg cancellation.
///
/// The case that drove this: a party holds ONE whole Double Sofa plus ONE
/// Single, booked round-trip. The GO leg finishes, and the agent wants to drop
/// only the ride home — for one of those seats, or for the party. The old
/// whole-rider cancel cleared `assignedSeats` outright, so the entire party
/// disappeared off the chart and their live fare fell to zero even though they
/// had genuinely ridden out.
void main() {
  // A bus whose DL3 is a Double Sofa and SU2 a Single Sofa.
  SeatType? cells(String busId, String seatId) {
    if (busId != 'b1') return null;
    return const {
      'DL3': SeatType.doubleSofa,
      'SU2': SeatType.singleSofa,
      'ST5': SeatType.seater,
    }[seatId];
  }

  /// The party above: a whole double (two berths on DL3) + a single (SU2).
  Passenger party({TripType leg = TripType.roundTrip}) => Passenger(
        id: 'p1',
        tourId: 't1',
        name: 'Ramesh',
        phone: '+910000000001',
        tripType: leg,
        requestLines: [
          RequestLine(seatType: SeatType.doubleSofa, qty: 1, leg: leg),
          RequestLine(seatType: SeatType.singleSofa, qty: 1, leg: leg),
        ],
        assignedSeats: [
          SeatAssignment(busId: 'b1', seatId: 'DL3', leg: leg),
          SeatAssignment(busId: 'b1', seatId: 'DL3', leg: leg),
          SeatAssignment(busId: 'b1', seatId: 'SU2', leg: leg),
        ],
      );

  group('cancel the RETURN on one seat', () {
    test('the GO berths SURVIVE, re-stamped outbound-only', () {
      final out = cancelSeatLegTransform(
        party(),
        busId: 'b1',
        seatId: 'DL3',
        strike: TripType.returnOnly,
        cellTypeAt: cells,
      );

      expect(out, isNotNull);
      // THE REGRESSION THIS FILE EXISTS FOR: the chart must not empty out.
      final dl3 = out!.assignedSeats.where((a) => a.seatId == 'DL3').toList();
      expect(dl3, hasLength(2), reason: 'both double berths stay held');
      expect(dl3.every((a) => a.leg == TripType.outboundOnly), isTrue);
      // Every berth of the party is still held — three in, three out.
      expect(out.assignedSeats, hasLength(3));
    });

    test('the OTHER seat keeps its return', () {
      final out = cancelSeatLegTransform(
        party(),
        busId: 'b1',
        seatId: 'DL3',
        strike: TripType.returnOnly,
        cellTypeAt: cells,
      )!;

      final su2 = out.assignedSeats.singleWhere((a) => a.seatId == 'SU2');
      expect(su2.leg, TripType.roundTrip,
          reason: 'only the tapped seat loses its return');
      expect(out.legForSeat('SU2', busId: 'b1'), TripType.roundTrip);
      expect(out.legForSeat('DL3', busId: 'b1'), TripType.outboundOnly);
    });

    test('request lines follow: the double demotes, the single does not', () {
      final out = cancelSeatLegTransform(
        party(),
        busId: 'b1',
        seatId: 'DL3',
        strike: TripType.returnOnly,
        cellTypeAt: cells,
      )!;

      final dbl = out.requestLines
          .singleWhere((l) => l.seatType == SeatType.doubleSofa);
      expect(dbl.leg, TripType.outboundOnly);
      expect(dbl.qty, 1);
      final single = out.requestLines
          .singleWhere((l) => l.seatType == SeatType.singleSofa);
      expect(single.leg, TripType.roundTrip);
      // Berth demand is unchanged — they still hold every berth they booked, so
      // they must not resurface as needing a seat.
      expect(out.seatBerths, party().seatBerths);
      expect(out.isFullyAssigned, isTrue);
    });

    test('not retired while another seat still rides home', () {
      final out = cancelSeatLegTransform(
        party(),
        busId: 'b1',
        seatId: 'DL3',
        strike: TripType.returnOnly,
        cellTypeAt: cells,
      )!;

      expect(out.journeyDone, isFalse,
          reason: 'SU2 still carries them home — the journey is not over');
      expect(out.derivedTripType, TripType.roundTrip);
    });

    test('striking the LAST return seat retires them, berths intact', () {
      var p = party();
      for (final seat in ['DL3', 'SU2']) {
        p = cancelSeatLegTransform(
          p,
          busId: 'b1',
          seatId: seat,
          strike: TripType.returnOnly,
          cellTypeAt: cells,
        )!;
      }

      expect(p.journeyDone, isTrue, reason: 'no leg left to travel');
      // Retired, but NOT seatless — this is the invariant the seating engine
      // had to learn (it seeds these berths so nothing is placed on top).
      expect(p.assignedSeats, hasLength(3));
      expect(
        p.assignedSeats.every((a) => a.leg == TripType.outboundOnly),
        isTrue,
      );
      expect(p.requestLines.every((l) => l.leg == TripType.outboundOnly), isTrue);
      expect(p.derivedTripType, TripType.outboundOnly);
    });
  });

  group('cancel the GO leg on one seat', () {
    test('the RETURN berth survives and they are not retired', () {
      final out = cancelSeatLegTransform(
        party(),
        busId: 'b1',
        seatId: 'SU2',
        strike: TripType.outboundOnly,
        cellTypeAt: cells,
      )!;

      final su2 = out.assignedSeats.singleWhere((a) => a.seatId == 'SU2');
      expect(su2.leg, TripType.returnOnly, reason: 'they still ride home');
      expect(out.journeyDone, isFalse);
      final single = out.requestLines
          .singleWhere((l) => l.seatType == SeatType.singleSofa);
      expect(single.leg, TripType.returnOnly);
    });
  });

  group('one-leg berths', () {
    test('a return-only berth is REMOVED, not demoted', () {
      final p = Passenger(
        id: 'p2',
        tourId: 't1',
        name: 'Sita',
        phone: '+910000000002',
        tripType: TripType.returnOnly,
        requestLines: [
          RequestLine(
              seatType: SeatType.singleSofa,
              qty: 1,
              leg: TripType.returnOnly),
        ],
        assignedSeats: [
          SeatAssignment(
              busId: 'b1', seatId: 'SU2', leg: TripType.returnOnly),
        ],
      );

      // Nothing of a return-only rider survives losing the return.
      expect(
        cancelSeatLegTransform(
          p,
          busId: 'b1',
          seatId: 'SU2',
          strike: TripType.returnOnly,
          cellTypeAt: cells,
        ),
        isNull,
        reason: 'null tells the caller to remove the rider outright',
      );
    });

    test('striking a leg the seat does not travel is a NO-OP', () {
      final p = party(leg: TripType.outboundOnly);
      final out = cancelSeatLegTransform(
        p,
        busId: 'b1',
        seatId: 'DL3',
        strike: TripType.returnOnly,
        cellTypeAt: cells,
      );

      // A mis-aimed tap must never wipe a seat.
      expect(identical(out, p), isTrue);
    });

    test('an untouched seat on another bus is left alone', () {
      final p = party().copyWith(assignedSeats: [
        SeatAssignment(busId: 'b1', seatId: 'DL3', leg: TripType.roundTrip),
        SeatAssignment(busId: 'b1', seatId: 'DL3', leg: TripType.roundTrip),
        SeatAssignment(busId: 'b2', seatId: 'DL3', leg: TripType.roundTrip),
      ]);
      final out = cancelSeatLegTransform(
        p,
        busId: 'b1',
        seatId: 'DL3',
        strike: TripType.returnOnly,
        cellTypeAt: cells,
      )!;

      final other = out.assignedSeats.singleWhere((a) => a.busId == 'b2');
      expect(other.leg, TripType.roundTrip,
          reason: 'same seat id, different bus — must not be struck');
    });
  });

  group('shared double sofa', () {
    test('striking one holder leaves the other holder alone', () {
      // Two strangers share DL3 — one berth each, both round-trip.
      Passenger holder(String id) => Passenger(
            id: id,
            tourId: 't1',
            name: id,
            phone: '+91000000000$id',
            tripType: TripType.roundTrip,
            requestLines: [
              RequestLine(
                  seatType: SeatType.singleSofa,
                  qty: 1,
                  leg: TripType.roundTrip),
            ],
            assignedSeats: [
              SeatAssignment(
                  busId: 'b1', seatId: 'DL3', leg: TripType.roundTrip),
            ],
          );

      final a = cancelSeatLegTransform(
        holder('1'),
        busId: 'b1',
        seatId: 'DL3',
        strike: TripType.returnOnly,
        cellTypeAt: cells,
      )!;
      final b = holder('2');

      expect(a.assignedSeats.single.leg, TripType.outboundOnly);
      // A single-sofa LINE on a double CELL is one berth, so the unit maths
      // lands exactly: the line demotes whole, no berth is left unaccounted.
      expect(a.requestLines.single.leg, TripType.outboundOnly);
      expect(a.requestLines.single.qty, 1);
      expect(a.seatBerths, 1);
      expect(b.assignedSeats.single.leg, TripType.roundTrip,
          reason: 'the other holder of the shared sofa is untouched');
    });
  });

  group('cancellableSeatLegs gate', () {
    test('return offered only after the GO leg is done, GO only before', () {
      final p = party();

      final onGoLeg = cancellableSeatLegs(p,
          busId: 'b1', seatId: 'DL3', goLegCompleted: false);
      expect(onGoLeg.go, isTrue);
      expect(onGoLeg.ret, isFalse,
          reason: 'before departure the right action is an ordinary cancel');

      final returnPhase = cancellableSeatLegs(p,
          busId: 'b1', seatId: 'DL3', goLegCompleted: true);
      expect(returnPhase.ret, isTrue);
      expect(returnPhase.go, isFalse,
          reason: 'you cannot un-ride a leg the bus has already run');
    });

    test('a seat the rider does not hold offers nothing', () {
      final p = party();
      final none = cancellableSeatLegs(p,
          busId: 'b1', seatId: 'ST5', goLegCompleted: true);
      expect(none.go, isFalse);
      expect(none.ret, isFalse);
    });

    test('a GO-only berth never offers a return to cancel', () {
      final p = party(leg: TripType.outboundOnly);
      final g = cancellableSeatLegs(p,
          busId: 'b1', seatId: 'DL3', goLegCompleted: true);
      expect(g.ret, isFalse);
    });
  });
}
