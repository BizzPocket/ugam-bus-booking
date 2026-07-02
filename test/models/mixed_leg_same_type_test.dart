import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/passenger.dart';
import 'package:occubusbooking/models/request_line.dart';
import 'package:occubusbooking/models/seat_assignment.dart';
import 'package:occubusbooking/models/seat_type.dart';
import 'package:occubusbooking/models/trip_type.dart';
import 'package:occubusbooking/utils/seat_leg_resolver.dart';

/// THE bug this whole change fixes: ONE booking requests the SAME seat type
/// split across opposite one-way legs — "1 seater GO-only + 1 seater RET-only"
/// (two [RequestLine]s, each with its own [leg]). Once placed, each physical
/// seat must remember WHICH leg it satisfies, otherwise everything that rebuilds
/// the leg from the coarse passenger summary collapses both seats to round-trip.
///
/// Here we lock down the two foundation pieces that make per-seat legs possible:
///   (a) [SeatAssignment] serializes / parses its [leg] (and a legless map → null);
///   (b) [resolveAssignmentLegs] stamps two same-type seats with OPPOSITE legs.
void main() {
  // The passenger at the centre of the matrix bug: same type, opposite legs.
  const matrixLines = [
    RequestLine(seatType: SeatType.seater, qty: 1, leg: TripType.outboundOnly),
    RequestLine(seatType: SeatType.seater, qty: 1, leg: TripType.returnOnly),
  ];

  group('SeatAssignment.leg serialization', () {
    test('round-trips the leg through toMap/fromMap', () {
      const a = SeatAssignment(
        busId: 'b1',
        seatId: 'ST1',
        leg: TripType.returnOnly,
      );
      expect(a.toMap()['leg'], 'returnOnly');
      final back = SeatAssignment.fromMap(a.toMap());
      expect(back.leg, TripType.returnOnly);
      // Identity is still (busId, seatId) only — leg, like locked, is not part
      // of equality, so occupancy lookups keep working.
      expect(back, equals(a));
    });

    test('omits the leg key when null and parses a legless map to null', () {
      const a = SeatAssignment(busId: 'b1', seatId: 'ST1');
      expect(a.leg, isNull);
      expect(a.toMap().containsKey('leg'), isFalse);
      // A legacy row written before per-seat legs existed has no key → null,
      // so readers fall back to the passenger-level leg.
      final legacy = SeatAssignment.fromMap({'busId': 'b1', 'seatId': 'ST1'});
      expect(legacy.leg, isNull);
    });
  });

  group('resolveAssignmentLegs — same-type one-way split', () {
    test('stamps one seater seat GO and the other RET (request order)', () {
      // Two bare seater seats (no leg recorded yet); cellTypeAt says both are
      // seaters. The two seater lines — outbound-only then return-only — must
      // map onto the two seats in request order: ST1 → GO, ST2 → RET.
      final resolved = resolveAssignmentLegs(
        requestLines: matrixLines,
        assigned: const [
          SeatAssignment(busId: 'b1', seatId: 'ST1'),
          SeatAssignment(busId: 'b1', seatId: 'ST2'),
        ],
        cellTypeAt: (busId, seatId) => SeatType.seater,
      );

      expect(resolved.map((a) => a.seatId), ['ST1', 'ST2'],
          reason: 'same seats, same order, only the leg is stamped');
      expect(resolved[0].leg, TripType.outboundOnly);
      expect(resolved[1].leg, TripType.returnOnly);
    });
  });

  group('Passenger.legForSeat — drives the per-seat GO/RET tint', () {
    test('returns each held seat its own stamped leg, not the summary', () {
      // The placed passenger: derivedTripType/tripType collapse to roundTrip
      // (mixed legs), but each seat carries its own stamped leg.
      final p = Passenger(
        tourId: 't1',
        name: 'Mixed',
        phone: '1',
        requestLines: matrixLines,
        assignedSeats: const [
          SeatAssignment(busId: 'b1', seatId: 'ST1', leg: TripType.outboundOnly),
          SeatAssignment(busId: 'b1', seatId: 'ST2', leg: TripType.returnOnly),
        ],
      );
      expect(p.derivedTripType, TripType.roundTrip,
          reason: 'mixed legs collapse to the coarse summary');
      // ...but per seat the tint must read the seat's own leg.
      expect(p.legForSeat('ST1'), TripType.outboundOnly);
      expect(p.legForSeat('ST2'), TripType.returnOnly);
    });

    test('falls back to passenger tripType for an unstamped (legacy) seat', () {
      final p = Passenger(
        tourId: 't1',
        name: 'Legacy',
        phone: '1',
        tripType: TripType.outboundOnly,
        requestLines: const [
          RequestLine(seatType: SeatType.seater, qty: 1, leg: TripType.outboundOnly),
        ],
        assignedSeats: const [SeatAssignment(busId: 'b1', seatId: 'ST1')],
      );
      expect(p.legForSeat('ST1'), TripType.outboundOnly,
          reason: 'no leg on the seat → coarse passenger-level leg');
      // A seat the passenger does not hold also falls back to the summary.
      expect(p.legForSeat('ST9'), TripType.outboundOnly);
    });
  });
}
