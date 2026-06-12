import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/seat_type.dart';
import 'package:occubusbooking/models/trip_type.dart';
import 'package:occubusbooking/utils/seat_drop_engine.dart';

// ── Builders ───────────────────────────────────────────────────────────────
DropCell cell(
  String? id,
  SeatType? type, {
  bool reserved = false,
}) =>
    (seatId: id, seatType: type, reserved: reserved);

SeatOccupant occ(
  String id, {
  TripType trip = TripType.roundTrip,
  int berthsHere = 1,
  int wholeDoublesHeld = 0,
  int requestedDoubleQty = 0,
}) =>
    (
      passengerId: id,
      trip: trip,
      berthsHere: berthsHere,
      wholeDoublesHeld: wholeDoublesHeld,
      requestedDoubleQty: requestedDoubleQty,
    );

void main() {
  final single = SeatType.singleSofa;
  final dbl = SeatType.doubleSofa;
  final seater = SeatType.seater;

  group('guards', () {
    test('dropping on a non-seat is neutral', () {
      final d = decideSeatDrop(
        fromCell: cell('SL1', single),
        targetCell: cell(null, null),
        fromOccupants: [occ('a')],
        targetOccupants: const [],
      );
      expect(d.action, SeatDropAction.blocked);
      expect(d.block, SeatDropBlock.neutral);
    });

    test('dropping on its own seat is self', () {
      final d = decideSeatDrop(
        fromCell: cell('SL1', single),
        targetCell: cell('SL1', single),
        fromOccupants: [occ('a')],
        targetOccupants: [occ('a')],
      );
      expect(d.block, SeatDropBlock.self);
    });

    test('sleeper ↔ seater is a class mismatch', () {
      final d = decideSeatDrop(
        fromCell: cell('SL1', single),
        targetCell: cell('ST1', seater),
        fromOccupants: [occ('a')],
        targetOccupants: const [],
      );
      expect(d.block, SeatDropBlock.classMismatch);
    });
  });

  group('plain move / swap', () {
    test('single → free single is a move of 1 berth', () {
      final d = decideSeatDrop(
        fromCell: cell('SL1', single),
        targetCell: cell('SL2', single),
        fromOccupants: [occ('a')],
        targetOccupants: const [],
      );
      expect(d.action, SeatDropAction.move);
      expect(d.berths, 1);
    });

    test('single ↔ occupied single is a swap', () {
      final d = decideSeatDrop(
        fromCell: cell('SL1', single),
        targetCell: cell('SL2', single),
        fromOccupants: [occ('a')],
        targetOccupants: [occ('b')],
      );
      expect(d.action, SeatDropAction.swap);
    });

    test('free reserved target is held', () {
      final d = decideSeatDrop(
        fromCell: cell('SL1', single),
        targetCell: cell('SL2', single, reserved: true),
        fromOccupants: [occ('a')],
        targetOccupants: const [],
      );
      expect(d.block, SeatDropBlock.held);
    });
  });

  group('shared source moves both together', () {
    test('shared double → fully-free double moves both', () {
      final d = decideSeatDrop(
        fromCell: cell('DL1', dbl),
        targetCell: cell('DL2', dbl),
        fromOccupants: [occ('a'), occ('b')],
        targetOccupants: const [],
      );
      expect(d.action, SeatDropAction.moveBoth);
    });

    test('shared double → occupied double is blocked', () {
      final d = decideSeatDrop(
        fromCell: cell('DL1', dbl),
        targetCell: cell('DL2', dbl),
        fromOccupants: [occ('a'), occ('b')],
        targetOccupants: [occ('c')],
      );
      expect(d.block, SeatDropBlock.sharedNeedsFreeDouble);
    });

    test('shared double → single is blocked', () {
      final d = decideSeatDrop(
        fromCell: cell('DL1', dbl),
        targetCell: cell('SL1', single),
        fromOccupants: [occ('a'), occ('b')],
        targetOccupants: const [],
      );
      expect(d.block, SeatDropBlock.sharedNeedsFreeDouble);
    });

    test('shared double → free but reserved double is held', () {
      final d = decideSeatDrop(
        fromCell: cell('DL1', dbl),
        targetCell: cell('DL2', dbl, reserved: true),
        fromOccupants: [occ('a'), occ('b')],
        targetOccupants: const [],
      );
      expect(d.block, SeatDropBlock.held);
    });
  });

  group('smart fill on a half-filled double', () {
    test('single → half-double with leg room fills (shares)', () {
      final d = decideSeatDrop(
        fromCell: cell('SL1', single),
        targetCell: cell('DL1', dbl),
        fromOccupants: [occ('a')],
        targetOccupants: [occ('b', berthsHere: 1)],
      );
      expect(d.action, SeatDropAction.fill);
      expect(d.berths, 1);
    });

    test('round-trip single → half-double already round-trip-full falls to swap',
        () {
      // Occupant holds both legs on one berth of a cap-2 double; a round-trip
      // mover needs a berth on both legs → GO 1+1<=2 ok, RET 1+1<=2 ok → fits.
      // Make it NOT fit by having the occupant hold 2 berths (whole double):
      final d = decideSeatDrop(
        fromCell: cell('SL1', single),
        targetCell: cell('DL1', dbl),
        fromOccupants: [occ('a')],
        targetOccupants: [occ('b', berthsHere: 2)],
      );
      // No free berth on a whole-double target → swap, but berth loads differ
      // (occ holds 2, source single cap 1) → blocked tooSmall.
      expect(d.block, SeatDropBlock.tooSmall);
    });

    test('leg-disjoint single fills the opposite leg of a one-way occupant', () {
      final d = decideSeatDrop(
        fromCell: cell('SL1', single),
        targetCell: cell('DL1', dbl),
        fromOccupants: [occ('a', trip: TripType.returnOnly)],
        targetOccupants: [occ('b', trip: TripType.outboundOnly, berthsHere: 2)],
      );
      // Occupant fills BOTH berths but only the GO leg; a RET-only mover still
      // has leg room on RET → fill.
      expect(d.action, SeatDropAction.fill);
    });
  });

  group('whole-double split rules', () {
    test('substitute whole-double → free single splits one berth', () {
      final d = decideSeatDrop(
        fromCell: cell('DL1', dbl),
        targetCell: cell('SL1', single),
        // Holds 2 berths on this double, requested 0 doubles → substitute.
        fromOccupants: [occ('a', berthsHere: 2, wholeDoublesHeld: 1)],
        targetOccupants: const [],
      );
      expect(d.action, SeatDropAction.splitToSingle);
      expect(d.berths, 1);
    });

    test('genuine whole-double → free single is too small (no split)', () {
      final d = decideSeatDrop(
        fromCell: cell('DL1', dbl),
        targetCell: cell('SL1', single),
        // Requested a double and got one → genuine, not splittable.
        fromOccupants: [
          occ('a', berthsHere: 2, wholeDoublesHeld: 1, requestedDoubleQty: 1),
        ],
        targetOccupants: const [],
      );
      expect(d.block, SeatDropBlock.tooSmall);
    });

    test('whole-double → free double moves all berths (no split)', () {
      final d = decideSeatDrop(
        fromCell: cell('DL1', dbl),
        targetCell: cell('DL2', dbl),
        fromOccupants: [occ('a', berthsHere: 2, wholeDoublesHeld: 1)],
        targetOccupants: const [],
      );
      expect(d.action, SeatDropAction.move);
      expect(d.berths, 2);
    });
  });

  group('ambiguous target', () {
    test('dropping onto a shared (2-person) target is blocked', () {
      final d = decideSeatDrop(
        fromCell: cell('SL1', single),
        targetCell: cell('DL1', dbl),
        fromOccupants: [occ('a')],
        targetOccupants: [occ('b'), occ('c')],
      );
      expect(d.block, SeatDropBlock.sharedTargetAmbiguous);
    });
  });
}
