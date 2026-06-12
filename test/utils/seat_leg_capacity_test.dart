import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/trip_type.dart';
import 'package:occubusbooking/utils/seat_leg_capacity.dart';

void main() {
  group('seatHasLegRoom — leg-disjoint reuse', () {
    test('a return-only rider reuses a single sofa held by an outbound-only rider',
        () {
      // Single sofa (cap 1). GO leg full (outbound-only occupant), RET leg free.
      final ok = seatHasLegRoom(
        activeTrip: TripType.returnOnly,
        need: 1,
        cap: 1,
        occupants: [(trip: TripType.outboundOnly, berths: 1)],
      );
      expect(ok, isTrue);
    });

    test('an outbound-only rider reuses a single sofa held by a return-only rider',
        () {
      final ok = seatHasLegRoom(
        activeTrip: TripType.outboundOnly,
        need: 1,
        cap: 1,
        occupants: [(trip: TripType.returnOnly, berths: 1)],
      );
      expect(ok, isTrue);
    });

    test('a return-only rider reuses a WHOLE double held solo by an outbound rider',
        () {
      // Double sofa (cap 2) wholly held by an outbound-only rider on the GO leg.
      // A return-only rider wanting the whole double reuses both berths on RET.
      final ok = seatHasLegRoom(
        activeTrip: TripType.returnOnly,
        need: 2,
        cap: 2,
        occupants: [(trip: TripType.outboundOnly, berths: 2)],
      );
      expect(ok, isTrue);
    });
  });

  group('seatHasLegRoom — blocked', () {
    test('a round-trip rider cannot reuse a one-way-held single sofa', () {
      // GO leg taken by the outbound-only occupant; a round-trip rider needs
      // BOTH legs, so the GO leg has no room.
      final ok = seatHasLegRoom(
        activeTrip: TripType.roundTrip,
        need: 1,
        cap: 1,
        occupants: [(trip: TripType.outboundOnly, berths: 1)],
      );
      expect(ok, isFalse);
    });

    test('a round-trip seat blocks an opposite leg — both legs are full', () {
      // A round-trip occupant fills GO and RET; nobody else can take this single.
      expect(
        seatHasLegRoom(
          activeTrip: TripType.returnOnly,
          need: 1,
          cap: 1,
          occupants: [(trip: TripType.roundTrip, berths: 1)],
        ),
        isFalse,
      );
      expect(
        seatHasLegRoom(
          activeTrip: TripType.outboundOnly,
          need: 1,
          cap: 1,
          occupants: [(trip: TripType.roundTrip, berths: 1)],
        ),
        isFalse,
      );
    });

    test('two outbound-only riders cannot both hold a single sofa on the GO leg',
        () {
      final ok = seatHasLegRoom(
        activeTrip: TripType.outboundOnly,
        need: 1,
        cap: 1,
        occupants: [(trip: TripType.outboundOnly, berths: 1)],
      );
      expect(ok, isFalse);
    });

    test('need of 0 is never placeable', () {
      expect(
        seatHasLegRoom(
          activeTrip: TripType.returnOnly,
          need: 0,
          cap: 1,
          occupants: const [],
        ),
        isFalse,
      );
    });
  });

  group('seatHasLegRoom — same-leg double-sofa split still works', () {
    test('two round-trip singles split a double sofa (both berths, both legs)',
        () {
      // Double sofa cap 2. One round-trip occupant holds one berth; a second
      // round-trip single takes the other — the classic split, unchanged.
      final ok = seatHasLegRoom(
        activeTrip: TripType.roundTrip,
        need: 1,
        cap: 2,
        occupants: [(trip: TripType.roundTrip, berths: 1)],
      );
      expect(ok, isTrue);
    });

    test('a third rider cannot squeeze onto a full double sofa (same leg)', () {
      final ok = seatHasLegRoom(
        activeTrip: TripType.roundTrip,
        need: 1,
        cap: 2,
        occupants: [
          (trip: TripType.roundTrip, berths: 1),
          (trip: TripType.roundTrip, berths: 1),
        ],
      );
      expect(ok, isFalse);
    });
  });
}
