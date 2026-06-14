import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/seat_type.dart';
import 'package:occubusbooking/models/trip_type.dart';
import 'package:occubusbooking/utils/seat_fit.dart';
import 'package:occubusbooking/utils/seat_leg_capacity.dart';

/// A simple fixed-layout [SeatFitContext] built from a map of
/// `<busId>:<seatId>` to (SeatType, SeatPosition?).
SeatFitContext ctxFromCells(Map<String, (SeatType, SeatPosition?)> cells) {
  return SeatFitContext(
    cellTypeAt: (busId, seatId) => cells['$busId:$seatId']?.$1,
    cellPositionAt: (busId, seatId) => cells['$busId:$seatId']?.$2,
  );
}

/// A canClaimPartnerBerth callback that always grants (engine's tryClaim
/// returning true on a free partner berth).
bool alwaysClaim(PendingClaim c) => true;

/// A canClaimPartnerBerth callback that always refuses (partner berth full /
/// leg blocked).
bool neverClaim(PendingClaim c) => false;

void main() {
  group('computePendingLines — no held berths', () {
    test('returns request lines unchanged when nothing is held', () {
      final res = computePendingLines(
        requestLines: const [
          PendingLineInput(seatType: SeatType.doubleSofa, qty: 1),
          PendingLineInput(seatType: SeatType.seater, qty: 2),
        ],
        heldBerths: const [],
        ctx: ctxFromCells(const {}),
        canClaimPartnerBerth: alwaysClaim,
      );
      expect(res.remaining, [
        const PendingLineInput(seatType: SeatType.doubleSofa, qty: 1),
        const PendingLineInput(seatType: SeatType.seater, qty: 2),
      ]);
      expect(res.ownCellClaims, isEmpty);
    });
  });

  group('computePendingLines — single & seater draining', () {
    test('a held single sofa berth drains one position-matched single line', () {
      final res = computePendingLines(
        requestLines: const [
          PendingLineInput(
            seatType: SeatType.singleSofa,
            position: SeatPosition.lower,
            qty: 2,
          ),
        ],
        heldBerths: const [HeldBerth(busId: 'b1', seatId: 's1')],
        ctx: ctxFromCells({
          'b1:s1': (SeatType.singleSofa, SeatPosition.lower),
        }),
        canClaimPartnerBerth: alwaysClaim,
      );
      expect(res.remaining, [
        const PendingLineInput(
          seatType: SeatType.singleSofa,
          position: SeatPosition.lower,
          qty: 1,
        ),
      ]);
    });

    test('held single with no matching single line buckets as leftover', () {
      // Leftover single alone (odd) cannot cross-fill a double -> double stays.
      final res = computePendingLines(
        requestLines: const [
          PendingLineInput(seatType: SeatType.doubleSofa, qty: 1),
        ],
        heldBerths: const [HeldBerth(busId: 'b1', seatId: 's1')],
        ctx: ctxFromCells({
          'b1:s1': (SeatType.singleSofa, SeatPosition.lower),
        }),
        canClaimPartnerBerth: alwaysClaim,
      );
      expect(res.remaining, [
        const PendingLineInput(seatType: SeatType.doubleSofa, qty: 1),
      ]);
    });

    test('seater held berth drains a seater line', () {
      final res = computePendingLines(
        requestLines: const [
          PendingLineInput(seatType: SeatType.seater, qty: 2),
        ],
        heldBerths: const [HeldBerth(busId: 'b1', seatId: 'st1')],
        ctx: ctxFromCells({
          'b1:st1': (SeatType.seater, null),
        }),
        canClaimPartnerBerth: alwaysClaim,
      );
      expect(res.remaining, [
        const PendingLineInput(seatType: SeatType.seater, qty: 1),
      ]);
    });
  });

  group('computePendingLines — whole double', () {
    test('two held berths on a double drain one matching double line', () {
      final res = computePendingLines(
        requestLines: const [
          PendingLineInput(
            seatType: SeatType.doubleSofa,
            position: SeatPosition.lower,
            qty: 1,
          ),
        ],
        heldBerths: const [
          HeldBerth(busId: 'b1', seatId: 'd1'),
          HeldBerth(busId: 'b1', seatId: 'd1'),
        ],
        ctx: ctxFromCells({
          'b1:d1': (SeatType.doubleSofa, SeatPosition.lower),
        }),
        canClaimPartnerBerth: neverClaim,
      );
      expect(res.remaining, isEmpty);
      expect(res.ownCellClaims, isEmpty);
    });

    test('whole double with no double line drains two single lines', () {
      final res = computePendingLines(
        requestLines: const [
          PendingLineInput(seatType: SeatType.singleSofa, qty: 3),
        ],
        heldBerths: const [
          HeldBerth(busId: 'b1', seatId: 'd1'),
          HeldBerth(busId: 'b1', seatId: 'd1'),
        ],
        ctx: ctxFromCells({
          'b1:d1': (SeatType.doubleSofa, SeatPosition.lower),
        }),
        canClaimPartnerBerth: neverClaim,
      );
      expect(res.remaining, [
        const PendingLineInput(seatType: SeatType.singleSofa, qty: 1),
      ]);
    });
  });

  group('computePendingLines — own-cell double completion (the missing case)',
      () {
    test(
        'half-held double + matching double line + claimable partner '
        '-> completes in place, emits a claim, double line drained', () {
      final res = computePendingLines(
        requestLines: const [
          PendingLineInput(seatType: SeatType.doubleSofa, qty: 1),
        ],
        heldBerths: const [HeldBerth(busId: 'b1', seatId: 'd1')],
        ctx: ctxFromCells({
          'b1:d1': (SeatType.doubleSofa, SeatPosition.lower),
        }),
        canClaimPartnerBerth: alwaysClaim,
      );
      expect(res.remaining, isEmpty,
          reason: 'the double line is satisfied by the own cell');
      expect(res.ownCellClaims,
          [const PendingClaim(busId: 'b1', seatId: 'd1')]);
    });

    test(
        'own-cell completion is position-agnostic: an UPPER double line is '
        'completed by a LOWER half-held double cell', () {
      final res = computePendingLines(
        requestLines: const [
          PendingLineInput(
            seatType: SeatType.doubleSofa,
            position: SeatPosition.upper,
            qty: 1,
          ),
        ],
        heldBerths: const [HeldBerth(busId: 'b1', seatId: 'd1')],
        ctx: ctxFromCells({
          'b1:d1': (SeatType.doubleSofa, SeatPosition.lower),
        }),
        canClaimPartnerBerth: alwaysClaim,
      );
      expect(res.remaining, isEmpty);
      expect(res.ownCellClaims,
          [const PendingClaim(busId: 'b1', seatId: 'd1')]);
    });

    test(
        'partner NOT claimable -> NO claim, double line restored, '
        'falls back to draining a single line', () {
      final res = computePendingLines(
        requestLines: const [
          PendingLineInput(seatType: SeatType.doubleSofa, qty: 1),
          PendingLineInput(seatType: SeatType.singleSofa, qty: 1),
        ],
        heldBerths: const [HeldBerth(busId: 'b1', seatId: 'd1')],
        ctx: ctxFromCells({
          'b1:d1': (SeatType.doubleSofa, SeatPosition.lower),
        }),
        canClaimPartnerBerth: neverClaim,
      );
      // The double line was restored (claim refused) and a single line drained.
      expect(res.ownCellClaims, isEmpty);
      expect(res.remaining, [
        const PendingLineInput(seatType: SeatType.doubleSofa, qty: 1),
      ]);
    });

    test(
        'partner not claimable, no single line either -> buckets a leftover '
        'single (cannot cross-fill alone, double line stays)', () {
      final res = computePendingLines(
        requestLines: const [
          PendingLineInput(seatType: SeatType.doubleSofa, qty: 1),
        ],
        heldBerths: const [HeldBerth(busId: 'b1', seatId: 'd1')],
        ctx: ctxFromCells({
          'b1:d1': (SeatType.doubleSofa, SeatPosition.lower),
        }),
        canClaimPartnerBerth: neverClaim,
      );
      expect(res.ownCellClaims, isEmpty);
      expect(res.remaining, [
        const PendingLineInput(seatType: SeatType.doubleSofa, qty: 1),
      ]);
    });

    test(
        'half-held double with NO double line falls back to single drain '
        '(callback never consulted)', () {
      var consulted = false;
      final res = computePendingLines(
        requestLines: const [
          PendingLineInput(seatType: SeatType.singleSofa, qty: 1),
        ],
        heldBerths: const [HeldBerth(busId: 'b1', seatId: 'd1')],
        ctx: ctxFromCells({
          'b1:d1': (SeatType.doubleSofa, SeatPosition.lower),
        }),
        canClaimPartnerBerth: (c) {
          consulted = true;
          return true;
        },
      );
      expect(consulted, isFalse,
          reason: 'no double line exists, so no own-cell completion attempt');
      expect(res.remaining, isEmpty);
      expect(res.ownCellClaims, isEmpty);
    });
  });

  group('computePendingLines — cross-fill of leftover singles', () {
    test('two leftover single berths cross-fill one double line', () {
      final res = computePendingLines(
        requestLines: const [
          PendingLineInput(seatType: SeatType.doubleSofa, qty: 1),
        ],
        heldBerths: const [
          HeldBerth(busId: 'b1', seatId: 's1'),
          HeldBerth(busId: 'b1', seatId: 's2'),
        ],
        ctx: ctxFromCells({
          'b1:s1': (SeatType.singleSofa, SeatPosition.lower),
          'b1:s2': (SeatType.singleSofa, SeatPosition.lower),
        }),
        canClaimPartnerBerth: neverClaim,
      );
      expect(res.remaining, isEmpty);
      expect(res.ownCellClaims, isEmpty);
    });

    test('cross-fill ignores position (upper double, lower singles)', () {
      final res = computePendingLines(
        requestLines: const [
          PendingLineInput(
            seatType: SeatType.doubleSofa,
            position: SeatPosition.upper,
            qty: 1,
          ),
        ],
        heldBerths: const [
          HeldBerth(busId: 'b1', seatId: 's1'),
          HeldBerth(busId: 'b1', seatId: 's2'),
        ],
        ctx: ctxFromCells({
          'b1:s1': (SeatType.singleSofa, SeatPosition.lower),
          'b1:s2': (SeatType.singleSofa, SeatPosition.lower),
        }),
        canClaimPartnerBerth: neverClaim,
      );
      expect(res.remaining, isEmpty);
    });

    test('a half-held double (no double line) becomes a leftover single, '
        'pairs with another single to cross-fill a SEPARATE double line', () {
      // d1 is half-held; there is no double line that matches it for own-cell
      // completion ON ITS OWN PASS because the only double line is also needed.
      // Actually: one double line; half-held double tries own-cell first.
      // To exercise the leftover path we refuse the claim, then a real single
      // pairs with the leftover half to cross-fill the double line.
      final res = computePendingLines(
        requestLines: const [
          PendingLineInput(seatType: SeatType.doubleSofa, qty: 1),
        ],
        heldBerths: const [
          HeldBerth(busId: 'b1', seatId: 'd1'), // half double -> leftover
          HeldBerth(busId: 'b1', seatId: 's1'), // single -> leftover
        ],
        ctx: ctxFromCells({
          'b1:d1': (SeatType.doubleSofa, SeatPosition.lower),
          'b1:s1': (SeatType.singleSofa, SeatPosition.lower),
        }),
        canClaimPartnerBerth: neverClaim,
      );
      // Half-double leftover + single leftover = 1 pair -> drains the double.
      expect(res.remaining, isEmpty);
      expect(res.ownCellClaims, isEmpty);
    });
  });

  group('berthsForFreeCell — double sofa cell', () {
    final freeOccupants = <SeatLegHolder>[];

    test('matching double line -> 2 berths', () {
      final n = berthsForFreeCell(
        remaining: const [
          PendingLineInput(seatType: SeatType.doubleSofa, qty: 1),
        ],
        cellType: SeatType.doubleSofa,
        cellPosition: SeatPosition.lower,
        activeTrip: TripType.roundTrip,
        cap: 2,
        occupants: freeOccupants,
      );
      expect(n, 2);
    });

    test('two single lines cross-fill -> 2 berths', () {
      final n = berthsForFreeCell(
        remaining: const [
          PendingLineInput(seatType: SeatType.singleSofa, qty: 2),
        ],
        cellType: SeatType.doubleSofa,
        cellPosition: SeatPosition.lower,
        activeTrip: TripType.roundTrip,
        cap: 2,
        occupants: freeOccupants,
      );
      expect(n, 2);
    });

    test('one single line -> 1 berth (half double)', () {
      final n = berthsForFreeCell(
        remaining: const [
          PendingLineInput(seatType: SeatType.singleSofa, qty: 1),
        ],
        cellType: SeatType.doubleSofa,
        cellPosition: SeatPosition.lower,
        activeTrip: TripType.roundTrip,
        cap: 2,
        occupants: freeOccupants,
      );
      expect(n, 1);
    });

    test('position mismatch double line -> 0 berths', () {
      final n = berthsForFreeCell(
        remaining: const [
          PendingLineInput(
            seatType: SeatType.doubleSofa,
            position: SeatPosition.upper,
            qty: 1,
          ),
        ],
        cellType: SeatType.doubleSofa,
        cellPosition: SeatPosition.lower,
        activeTrip: TripType.roundTrip,
        cap: 2,
        occupants: freeOccupants,
      );
      expect(n, 0);
    });
  });

  group('berthsForFreeCell — single sofa cell (position gating bug fix)', () {
    test('matching single line -> 1 berth', () {
      final n = berthsForFreeCell(
        remaining: const [
          PendingLineInput(
            seatType: SeatType.singleSofa,
            position: SeatPosition.lower,
            qty: 1,
          ),
        ],
        cellType: SeatType.singleSofa,
        cellPosition: SeatPosition.lower,
        activeTrip: TripType.roundTrip,
        cap: 1,
        occupants: const [],
      );
      expect(n, 1);
    });

    test('single line position mismatch but a double line exists -> 1 '
        '(single may sit half a double, position-agnostic)', () {
      final n = berthsForFreeCell(
        remaining: const [
          PendingLineInput(
            seatType: SeatType.singleSofa,
            position: SeatPosition.upper,
            qty: 1,
          ),
          PendingLineInput(seatType: SeatType.doubleSofa, qty: 1),
        ],
        cellType: SeatType.singleSofa,
        cellPosition: SeatPosition.lower,
        activeTrip: TripType.roundTrip,
        cap: 1,
        occupants: const [],
      );
      expect(n, 1);
    });

    test('only a position-mismatched single line -> 0 berths', () {
      final n = berthsForFreeCell(
        remaining: const [
          PendingLineInput(
            seatType: SeatType.singleSofa,
            position: SeatPosition.upper,
            qty: 1,
          ),
        ],
        cellType: SeatType.singleSofa,
        cellPosition: SeatPosition.lower,
        activeTrip: TripType.roundTrip,
        cap: 1,
        occupants: const [],
      );
      expect(n, 0);
    });
  });

  group('berthsForFreeCell — seater cell', () {
    test('matching seater line -> 1 berth', () {
      final n = berthsForFreeCell(
        remaining: const [
          PendingLineInput(seatType: SeatType.seater, qty: 1),
        ],
        cellType: SeatType.seater,
        cellPosition: null,
        activeTrip: TripType.roundTrip,
        cap: 1,
        occupants: const [],
      );
      expect(n, 1);
    });

    test('no seater line -> 0 berths', () {
      final n = berthsForFreeCell(
        remaining: const [
          PendingLineInput(seatType: SeatType.singleSofa, qty: 1),
        ],
        cellType: SeatType.seater,
        cellPosition: null,
        activeTrip: TripType.roundTrip,
        cap: 1,
        occupants: const [],
      );
      expect(n, 0);
    });
  });

  group('berthsForFreeCell — leg-aware gating (symptoms B & C)', () {
    test('round-trip rider blocked on a double whose both legs are full', () {
      // Two round-trip occupants already fill both berths on GO and RET.
      final n = berthsForFreeCell(
        remaining: const [
          PendingLineInput(seatType: SeatType.singleSofa, qty: 1),
        ],
        cellType: SeatType.doubleSofa,
        cellPosition: SeatPosition.lower,
        activeTrip: TripType.roundTrip,
        cap: 2,
        occupants: const [
          (trip: TripType.roundTrip, berths: 2),
        ],
      );
      expect(n, 0, reason: 'no leg room: GO+RET both full');
    });

    test('GO-only rider reuses the RET-only half of a double (leg-disjoint)',
        () {
      // The cell already holds a RET-only occupant on 1 berth. A GO-only rider
      // can reuse: their GO slot is free.
      final n = berthsForFreeCell(
        remaining: const [
          PendingLineInput(seatType: SeatType.singleSofa, qty: 1),
        ],
        cellType: SeatType.doubleSofa,
        cellPosition: SeatPosition.lower,
        activeTrip: TripType.outboundOnly,
        cap: 2,
        occupants: const [
          (trip: TripType.returnOnly, berths: 1),
        ],
      );
      expect(n, 1, reason: 'GO slot is free; opposite-leg reuse allowed');
    });

    test('GO-only rider blocked when GO slots are full (same leg)', () {
      // Two GO-using occupants fill both GO slots of the double.
      final n = berthsForFreeCell(
        remaining: const [
          PendingLineInput(seatType: SeatType.singleSofa, qty: 1),
        ],
        cellType: SeatType.doubleSofa,
        cellPosition: SeatPosition.lower,
        activeTrip: TripType.outboundOnly,
        cap: 2,
        occupants: const [
          (trip: TripType.outboundOnly, berths: 2),
        ],
      );
      expect(n, 0, reason: 'both GO slots taken');
    });

    test('a free cell (no occupants) always passes the leg gate', () {
      final n = berthsForFreeCell(
        remaining: const [
          PendingLineInput(seatType: SeatType.singleSofa, qty: 1),
        ],
        cellType: SeatType.singleSofa,
        cellPosition: SeatPosition.lower,
        activeTrip: TripType.roundTrip,
        cap: 1,
        occupants: const [],
      );
      expect(n, 1);
    });

    test('type matches but leg full -> 0 (free path now leg-checked)', () {
      // Single sofa cap 1, already held by a round-trip rider -> no room.
      final n = berthsForFreeCell(
        remaining: const [
          PendingLineInput(seatType: SeatType.singleSofa, qty: 1),
        ],
        cellType: SeatType.singleSofa,
        cellPosition: SeatPosition.lower,
        activeTrip: TripType.roundTrip,
        cap: 1,
        occupants: const [
          (trip: TripType.roundTrip, berths: 1),
        ],
      );
      expect(n, 0);
    });
  });

  group('integration — drained remaining feeds berthsForFreeCell', () {
    test('half-held double completed in place -> nothing pending -> 0 on a '
        'fresh free double', () {
      final res = computePendingLines(
        requestLines: const [
          PendingLineInput(seatType: SeatType.doubleSofa, qty: 1),
        ],
        heldBerths: const [HeldBerth(busId: 'b1', seatId: 'd1')],
        ctx: ctxFromCells({
          'b1:d1': (SeatType.doubleSofa, SeatPosition.lower),
        }),
        canClaimPartnerBerth: alwaysClaim,
      );
      final n = berthsForFreeCell(
        remaining: res.remaining,
        cellType: SeatType.doubleSofa,
        cellPosition: SeatPosition.lower,
        activeTrip: TripType.roundTrip,
        cap: 2,
        occupants: const [],
      );
      expect(n, 0, reason: 'passenger is fully satisfied');
    });
  });
}
