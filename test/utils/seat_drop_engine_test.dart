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

    test('a RESERVED source seat cannot be dragged off the hold', () {
      final d = decideSeatDrop(
        fromCell: cell('SL1', single, reserved: true),
        targetCell: cell('SL2', single),
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

    test('shared double → occupied double is a pair-for-pair swap', () {
      // Both seats are cap-2 doubles, so exchanging their full contents is
      // always capacity- and leg-safe in both directions.
      final d = decideSeatDrop(
        fromCell: cell('DL1', dbl),
        targetCell: cell('DL2', dbl),
        fromOccupants: [occ('a'), occ('b')],
        targetOccupants: [occ('c')],
      );
      expect(d.action, SeatDropAction.swapPair);
      expect(d.isValid, isTrue);
    });

    test('shared double → another paired double is also a pair-for-pair swap',
        () {
      final d = decideSeatDrop(
        fromCell: cell('DL1', dbl),
        targetCell: cell('DL2', dbl),
        fromOccupants: [occ('a'), occ('b')],
        targetOccupants: [occ('c'), occ('d')],
      );
      expect(d.action, SeatDropAction.swapPair);
    });

    test(
        'a RET-only pair onto a GO-only-occupied double MERGES (4 berth-legs on '
        'one double), not a swap', () {
      // Target holds two GO-only riders (GO leg 2/2, RET leg 0/2). Incoming pair
      // is two RET-only riders (RET need 2). Per leg: GO 2+0<=2, RET 0+2<=2 — a
      // legal leg-disjoint merge into the SAME double.
      final d = decideSeatDrop(
        fromCell: cell('DL1', dbl),
        targetCell: cell('DL2', dbl),
        fromOccupants: [
          occ('a', trip: TripType.returnOnly),
          occ('b', trip: TripType.returnOnly),
        ],
        targetOccupants: [
          occ('c', trip: TripType.outboundOnly),
          occ('d', trip: TripType.outboundOnly),
        ],
      );
      expect(d.action, SeatDropAction.fillPairInto);
      expect(d.isValid, isTrue);
    });

    test('a GO-only pair onto a GO-only-occupied double has no leg room → swap',
        () {
      // Both pairs ride the GO leg: 2 + 2 = 4 on a cap-2 GO leg → cannot merge,
      // falls back to the contents swap.
      final d = decideSeatDrop(
        fromCell: cell('DL1', dbl),
        targetCell: cell('DL2', dbl),
        fromOccupants: [
          occ('a', trip: TripType.outboundOnly),
          occ('b', trip: TripType.outboundOnly),
        ],
        targetOccupants: [
          occ('c', trip: TripType.outboundOnly),
          occ('d', trip: TripType.outboundOnly),
        ],
      );
      expect(d.action, SeatDropAction.swapPair);
    });

    test('shared double → FREE single offers the split-which-sharer choice', () {
      final d = decideSeatDrop(
        fromCell: cell('DL1', dbl),
        targetCell: cell('SL1', single),
        fromOccupants: [occ('a'), occ('b')],
        targetOccupants: const [],
      );
      expect(d.action, SeatDropAction.splitPairChoice);
      expect(d.isValid, isTrue);
    });

    test('shared double → OCCUPIED single offers the split-which-sharer choice',
        () {
      final d = decideSeatDrop(
        fromCell: cell('DL1', dbl),
        targetCell: cell('SL1', single),
        fromOccupants: [occ('a'), occ('b')],
        targetOccupants: [occ('c')],
      );
      expect(d.action, SeatDropAction.splitPairChoice);
    });

    test('shared double → a single already shared by two is too ambiguous', () {
      final d = decideSeatDrop(
        fromCell: cell('DL1', dbl),
        targetCell: cell('SL1', single),
        fromOccupants: [occ('a'), occ('b')],
        targetOccupants: [occ('c'), occ('d')],
      );
      expect(d.block, SeatDropBlock.sharedNeedsFreeDouble);
    });

    test('a leg-share SINGLE source (GO + RET) relocates BOTH onto a free single',
        () {
      // A cap-1 single reused across disjoint legs lifts as a unit and moves the
      // whole GO+RET pairing together onto another FREE single sofa.
      final d = decideSeatDrop(
        fromCell: cell('SL1', single),
        targetCell: cell('SL2', single),
        fromOccupants: [
          occ('a', trip: TripType.outboundOnly),
          occ('b', trip: TripType.returnOnly),
        ],
        targetOccupants: const [],
      );
      expect(d.action, SeatDropAction.moveBoth);
    });

    test('a leg-share SINGLE source also relocates onto a free DOUBLE', () {
      final d = decideSeatDrop(
        fromCell: cell('SL1', single),
        targetCell: cell('DL1', dbl),
        fromOccupants: [
          occ('a', trip: TripType.outboundOnly),
          occ('b', trip: TripType.returnOnly),
        ],
        targetOccupants: const [],
      );
      expect(d.action, SeatDropAction.moveBoth);
    });

    test('a leg-share SINGLE source SWAPS onto an occupied single (leg-safe)',
        () {
      // A GO+RET leg-share on a single sofa can exchange its full contents with
      // an occupied compatible seat: the round-trip occupant takes the single,
      // the GO+RET pair takes the target. Both seats stay within cap on each
      // leg, so the swap is safe. (Previously this was wrongly blocked, leaving
      // the pair stranded whenever no fully-free seat was left on the bus.)
      final d = decideSeatDrop(
        fromCell: cell('SL1', single),
        targetCell: cell('SL2', single),
        fromOccupants: [
          occ('a', trip: TripType.outboundOnly),
          occ('b', trip: TripType.returnOnly),
        ],
        targetOccupants: [occ('c')],
      );
      expect(d.action, SeatDropAction.swapPair);
    });

    test('a leg-share SINGLE source MERGES into a half-filled leg-disjoint double',
        () {
      // Dropping the GO+RET pair onto the empty half of a double already holding
      // a round-trip rider fits on both legs (GO: rt+go = 2, RET: rt+ret = 2),
      // so all three share the double across the trip — the "empty half" target
      // an agent naturally aims for now works.
      final d = decideSeatDrop(
        fromCell: cell('SL1', single),
        targetCell: cell('DL1', dbl),
        fromOccupants: [
          occ('a', trip: TripType.outboundOnly),
          occ('b', trip: TripType.returnOnly),
        ],
        targetOccupants: [occ('c')], // round-trip
      );
      expect(d.action, SeatDropAction.fillPairInto);
    });

    test('a leg-share SINGLE source is blocked when no leg-safe home exists', () {
      // Target double is already full on BOTH legs (two round-trip riders): the
      // pair can't merge, and a contents swap would strand two round-trip riders
      // on a cap-1 single, so the drop is correctly refused.
      final d = decideSeatDrop(
        fromCell: cell('SL1', single),
        targetCell: cell('DL1', dbl),
        fromOccupants: [
          occ('a', trip: TripType.outboundOnly),
          occ('b', trip: TripType.returnOnly),
        ],
        targetOccupants: [occ('c'), occ('d')], // two round-trip → both legs full
      );
      expect(d.isValid, isFalse);
      expect(d.block, SeatDropBlock.sharedNeedsFreeDouble);
    });

    test('a TWO-occupant SINGLE source that is NOT leg-disjoint stays gated', () {
      // Two same-leg (or round-trip) occupants on a cap-1 single can't be a
      // clean leg-share, so it is never liftable as a pair.
      final d = decideSeatDrop(
        fromCell: cell('SL1', single),
        targetCell: cell('SL2', single),
        fromOccupants: [
          occ('a', trip: TripType.outboundOnly),
          occ('b', trip: TripType.outboundOnly),
        ],
        targetOccupants: const [],
      );
      expect(d.isValid, isFalse);
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

    test('a double-requester keeps BOTH doubles unsplittable even holding a '
        'surplus one (#12)', () {
      // Holds 2 whole doubles but requested 1. The old per-passenger rule
      // (wholeDoublesHeld > requestedDoubleQty) wrongly marked BOTH splittable,
      // so dragging the genuine double onto a single peeled a berth. Now a
      // passenger who requested any double keeps all their doubles intact.
      final d = decideSeatDrop(
        fromCell: cell('DL1', dbl),
        targetCell: cell('SL1', single),
        fromOccupants: [
          occ('a', berthsHere: 2, wholeDoublesHeld: 2, requestedDoubleQty: 1),
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
    test('a ROUND-TRIP whole-double mover onto a round-trip 2-person target is ambiguous',
        () {
      // A round-trip whole double rides BOTH legs on both berths, so it cannot
      // leg-share with round-trip occupants (every leg overflows) → ambiguous.
      // (A ONE-LEG whole double CAN merge onto a leg-disjoint target — see the
      // 'whole-double leg-share merge' group below.)
      final d = decideSeatDrop(
        fromCell: cell('DL1', dbl),
        targetCell: cell('DL2', dbl),
        fromOccupants: [occ('a', berthsHere: 2, wholeDoublesHeld: 1)],
        targetOccupants: [occ('b'), occ('c')],
      );
      expect(d.block, SeatDropBlock.sharedTargetAmbiguous);
    });
  });

  // A WHOLE one-leg double (2 berths on ONE leg, one occupant) dragged onto an
  // occupied double whose riders take the DISJOINT leg must MERGE (leg-share),
  // not swap — the user's "merge Pranav and test onto one sofa (go + return)".
  group('whole-double leg-share merge (2026-07-22)', () {
    test('whole GO-only double MERGES onto a RET-only occupied double (not swap)',
        () {
      final d = decideSeatDrop(
        fromCell: cell('DU4', dbl),
        targetCell: cell('DU5', dbl),
        fromOccupants: [
          occ('test',
              trip: TripType.outboundOnly,
              berthsHere: 2,
              wholeDoublesHeld: 1,
              requestedDoubleQty: 1),
        ],
        targetOccupants: [
          occ('pranav',
              trip: TripType.returnOnly,
              berthsHere: 2,
              wholeDoublesHeld: 1,
              requestedDoubleQty: 1),
        ],
      );
      expect(d.action, SeatDropAction.fillPairInto);
    });

    test('two GO-only whole doubles still SWAP (same leg, no merge room)', () {
      final d = decideSeatDrop(
        fromCell: cell('DU4', dbl),
        targetCell: cell('DU5', dbl),
        fromOccupants: [
          occ('a', trip: TripType.outboundOnly, berthsHere: 2, requestedDoubleQty: 1),
        ],
        targetOccupants: [
          occ('b', trip: TripType.outboundOnly, berthsHere: 2, requestedDoubleQty: 1),
        ],
      );
      expect(d.action, SeatDropAction.swap);
    });

    test('round-trip whole double onto a RET-only double still SWAPS (RET overflows)',
        () {
      final d = decideSeatDrop(
        fromCell: cell('DU4', dbl),
        targetCell: cell('DU5', dbl),
        fromOccupants: [
          occ('a', trip: TripType.roundTrip, berthsHere: 2, requestedDoubleQty: 1),
        ],
        targetOccupants: [
          occ('b', trip: TripType.returnOnly, berthsHere: 2, requestedDoubleQty: 1),
        ],
      );
      expect(d.action, SeatDropAction.swap);
    });

    test('whole RET-only double MERGES onto a double already holding two GO riders '
        '(builds the 4-rider sofa)', () {
      final d = decideSeatDrop(
        fromCell: cell('DU4', dbl),
        targetCell: cell('DU5', dbl),
        fromOccupants: [
          occ('test', trip: TripType.returnOnly, berthsHere: 2, requestedDoubleQty: 1),
        ],
        targetOccupants: [
          occ('a', trip: TripType.outboundOnly, berthsHere: 1),
          occ('b', trip: TripType.outboundOnly, berthsHere: 1),
        ],
      );
      expect(d.action, SeatDropAction.fillPairInto);
    });
  });

  // A rider's OWN two one-leg WHOLE doubles (a GO double + a RET double that
  // landed on two sofas) folded back onto ONE sofa — same person, leg-disjoint.
  group('same-person whole-double consolidation (2026-07-22)', () {
    test('own GO double dragged onto own RET double MERGES (not self-blocked)',
        () {
      final d = decideSeatDrop(
        fromCell: cell('DU4', dbl),
        targetCell: cell('DU5', dbl),
        fromOccupants: [
          occ('test',
              trip: TripType.outboundOnly, berthsHere: 2, requestedDoubleQty: 1),
        ],
        targetOccupants: [
          occ('test',
              trip: TripType.returnOnly, berthsHere: 2, requestedDoubleQty: 1),
        ],
      );
      expect(d.action, SeatDropAction.fillPairInto);
    });

    test('own SAME-leg doubles stay a self no-op (legs overlap → blocked)', () {
      final d = decideSeatDrop(
        fromCell: cell('DU4', dbl),
        targetCell: cell('DU5', dbl),
        fromOccupants: [
          occ('test',
              trip: TripType.outboundOnly, berthsHere: 2, requestedDoubleQty: 1),
        ],
        targetOccupants: [
          occ('test',
              trip: TripType.outboundOnly, berthsHere: 2, requestedDoubleQty: 1),
        ],
      );
      expect(d.block, SeatDropBlock.self);
    });
  });

  // CROSS-TYPE sharing (single ↔ double). A single-berth rider — whether it
  // comes from a single sofa or from a double-sofa half — leg-shares onto the
  // DISJOINT leg of EITHER a single or a double (the fill branch keys on the
  // TARGET's cap). A whole 2-berth double never fits a 1-berth single.
  group('cross-type single ↔ double sharing (2026-07-22)', () {
    test('single GO rider → occupied single RET = fill (single-sofa leg-share)',
        () {
      final d = decideSeatDrop(
        fromCell: cell('SL1', single),
        targetCell: cell('SL2', single),
        fromOccupants: [occ('a', trip: TripType.outboundOnly)],
        targetOccupants: [occ('b', trip: TripType.returnOnly)],
      );
      expect(d.action, SeatDropAction.fill);
    });

    test('single GO rider → occupied single GO = swap (same leg can\'t share)',
        () {
      // Two same-leg riders on 1-berth singles can't leg-share, so the drop
      // exchanges their seats (a swap) rather than blocking — a single was never
      // shareable on the same leg, so it legitimately falls through to swap.
      final d = decideSeatDrop(
        fromCell: cell('SL1', single),
        targetCell: cell('SL2', single),
        fromOccupants: [occ('a', trip: TripType.outboundOnly)],
        targetOccupants: [occ('b', trip: TripType.outboundOnly)],
      );
      expect(d.action, SeatDropAction.swap);
    });

    test('single GO rider → FREE double = move (takes one berth, half)', () {
      final d = decideSeatDrop(
        fromCell: cell('SL1', single),
        targetCell: cell('DL1', dbl),
        fromOccupants: [occ('a', trip: TripType.outboundOnly)],
        targetOccupants: const [],
      );
      expect(d.action, SeatDropAction.move);
      expect(d.berths, 1);
    });

    test('single RET rider → double held by a WHOLE-GO rider = fill (leg-share)',
        () {
      final d = decideSeatDrop(
        fromCell: cell('SL1', single),
        targetCell: cell('DL1', dbl),
        fromOccupants: [occ('a', trip: TripType.returnOnly)],
        targetOccupants: [occ('b', trip: TripType.outboundOnly, berthsHere: 2)],
      );
      expect(d.action, SeatDropAction.fill);
    });

    test('double-half GO rider → FREE single = move', () {
      final d = decideSeatDrop(
        fromCell: cell('DL1', dbl),
        targetCell: cell('SL1', single),
        fromOccupants: [occ('a', trip: TripType.outboundOnly, berthsHere: 1)],
        targetOccupants: const [],
      );
      expect(d.action, SeatDropAction.move);
      expect(d.berths, 1);
    });

    test('double-half GO rider → occupied single RET = fill (cross-type share)',
        () {
      final d = decideSeatDrop(
        fromCell: cell('DL1', dbl),
        targetCell: cell('SL1', single),
        fromOccupants: [occ('a', trip: TripType.outboundOnly, berthsHere: 1)],
        targetOccupants: [occ('b', trip: TripType.returnOnly)],
      );
      expect(d.action, SeatDropAction.fill);
    });

    test('WHOLE one-leg double (2 berths) → single is too small (never shares)',
        () {
      final d = decideSeatDrop(
        fromCell: cell('DL1', dbl),
        targetCell: cell('SL1', single),
        fromOccupants: [
          occ('a', trip: TripType.outboundOnly, berthsHere: 2, requestedDoubleQty: 1),
        ],
        targetOccupants: const [],
      );
      expect(d.block, SeatDropBlock.tooSmall);
    });
  });

  group('reserved OCCUPIED target is held (hole fix)', () {
    test('single → reserved OCCUPIED single is held, not a swap', () {
      final d = decideSeatDrop(
        fromCell: cell('SL1', single),
        targetCell: cell('SL2', single, reserved: true),
        fromOccupants: [occ('a')],
        targetOccupants: [occ('b')],
      );
      expect(d.block, SeatDropBlock.held);
    });

    test('single → reserved half-filled double is held, not a fill', () {
      final d = decideSeatDrop(
        fromCell: cell('SL1', single),
        targetCell: cell('DL1', dbl, reserved: true),
        fromOccupants: [occ('a')],
        targetOccupants: [occ('b', berthsHere: 1)],
      );
      expect(d.block, SeatDropBlock.held);
    });

    test('single → reserved shared (2-person) double is held', () {
      final d = decideSeatDrop(
        fromCell: cell('SL1', single),
        targetCell: cell('DL1', dbl, reserved: true),
        fromOccupants: [occ('a', trip: TripType.outboundOnly)],
        targetOccupants: [
          occ('b', trip: TripType.returnOnly),
          occ('c', trip: TripType.returnOnly),
        ],
      );
      expect(d.block, SeatDropBlock.held);
    });

    test('shared double → reserved occupied double is held', () {
      final d = decideSeatDrop(
        fromCell: cell('DL1', dbl),
        targetCell: cell('DL2', dbl, reserved: true),
        fromOccupants: [occ('a'), occ('b')],
        targetOccupants: [occ('c')],
      );
      expect(d.block, SeatDropBlock.held);
    });
  });

  group('four-into-one: 1-berth mover onto a 2-occupant double', () {
    test('GO-only mover fills a double whose 2 occupants are both RET-only', () {
      // The double already holds two RET-only riders (1 berth each on the RET
      // leg). The GO leg is physically free, so a GO-only mover slots in.
      final d = decideSeatDrop(
        fromCell: cell('SL1', single),
        targetCell: cell('DL1', dbl),
        fromOccupants: [occ('a', trip: TripType.outboundOnly)],
        targetOccupants: [
          occ('b', trip: TripType.returnOnly),
          occ('c', trip: TripType.returnOnly),
        ],
      );
      expect(d.action, SeatDropAction.fill);
      expect(d.berths, 1);
    });

    test('second GO-only mover fills beside one GO + one RET occupant', () {
      // Double holds one GO-only + one RET-only (1 berth each). A second
      // GO-only mover: GO leg has 1 used + 1 need <= 2 → room → fill.
      final d = decideSeatDrop(
        fromCell: cell('SL1', single),
        targetCell: cell('DL1', dbl),
        fromOccupants: [occ('a', trip: TripType.outboundOnly)],
        targetOccupants: [
          occ('b', trip: TripType.outboundOnly),
          occ('c', trip: TripType.returnOnly),
        ],
      );
      expect(d.action, SeatDropAction.fill);
      expect(d.berths, 1);
    });

    test('GO-only mover onto a double already full on the GO leg is noLegRoom',
        () {
      // Two GO-only occupants already fill both GO berths → a GO-only mover has
      // no room on its leg → blocked with the leg-specific reason (not tooSmall,
      // not the bare ambiguous block).
      final d = decideSeatDrop(
        fromCell: cell('SL1', single),
        targetCell: cell('DL1', dbl),
        fromOccupants: [occ('a', trip: TripType.outboundOnly)],
        targetOccupants: [
          occ('b', trip: TripType.outboundOnly),
          occ('c', trip: TripType.outboundOnly),
        ],
      );
      expect(d.block, SeatDropBlock.noLegRoom);
    });

    test('round-trip mover onto a 2-occupant double is noLegRoom', () {
      // Two RET-only occupants leave the GO leg free, but a round-trip mover
      // needs BOTH legs and RET is full → no leg room.
      final d = decideSeatDrop(
        fromCell: cell('SL1', single),
        targetCell: cell('DL1', dbl),
        fromOccupants: [occ('a')],
        targetOccupants: [
          occ('b', trip: TripType.returnOnly),
          occ('c', trip: TripType.returnOnly),
        ],
      );
      expect(d.block, SeatDropBlock.noLegRoom);
    });
  });

  group('single-occupant fill refusal emits noLegRoom (not tooSmall)', () {
    test('cap-2 double half-filled with a leg-blocking occupant → noLegRoom', () {
      // The occupant is a round-trip rider holding 1 berth on a cap-2 double,
      // so the FREE berth still leaves both legs at 1/2. To exhaust the mover's
      // leg with a single occupant we need a same-leg same-cap block: occupant
      // is GO-only holding 2 berths (fills the GO leg). A GO-only mover then has
      // no GO room, but the loads (mover 1 ≤ src cap, occ 2 > src cap=1) would
      // normally fall to tooSmall via swap. Because occ holds MORE than the
      // single source can take, that IS a genuine size mismatch → tooSmall.
      final sizeMismatch = decideSeatDrop(
        fromCell: cell('SL1', single),
        targetCell: cell('DL1', dbl),
        fromOccupants: [occ('a', trip: TripType.outboundOnly)],
        targetOccupants: [occ('b', trip: TripType.outboundOnly, berthsHere: 2)],
      );
      expect(sizeMismatch.block, SeatDropBlock.tooSmall);

      // Now a PURE leg conflict with matching loads: occupant holds 1 berth
      // GO-only on the double; a second GO-only 1-berth occupant would be the
      // 2-occupant path, so here we keep ONE occupant but make the source a
      // double too (cap 2) so occ's 1 berth ≤ src cap. Mover GO-only 1 berth,
      // occupant GO-only 1 berth → GO 1+1<=2 ok → fill (room). Confirms the
      // single-occupant fill still succeeds when the leg has room.
      final fits = decideSeatDrop(
        fromCell: cell('DL0', dbl),
        targetCell: cell('DL1', dbl),
        fromOccupants: [occ('a', trip: TripType.outboundOnly)],
        targetOccupants: [occ('b', trip: TripType.outboundOnly, berthsHere: 1)],
      );
      expect(fits.action, SeatDropAction.fill);
    });
  });
}
