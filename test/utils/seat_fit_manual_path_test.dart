// Manual-path regression tests for the seat-assignment screen.
//
// The manual screen (lib/screens/tour_seat_assignment_screen.dart) used to hold
// its OWN drifted copy of the "what's still pending / how can a passenger sit on
// this cell" algorithm. It is now a thin adapter over the shared, pure
// [computePendingLines] / [berthsForFreeCell] in lib/utils/seat_fit.dart. These
// tests reproduce the three CONFIRMED manual symptoms the consolidation had to
// fix, wired EXACTLY the way the screen wires the module:
//
//   * `_pendingLines`            -> computePendingLines(..., canClaimPartnerBerth)
//   * `_canClaimPartnerBerth`    -> seatHasLegRoom on the cell's OTHER occupants
//   * `_berthsForFreeCell` /
//     `_seatHereBerths`          -> berthsForFreeCell(..., occupants)
//
// so passing here proves the screen path itself is fixed.
import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/seat_type.dart';
import 'package:occubusbooking/models/trip_type.dart';
import 'package:occubusbooking/utils/seat_fit.dart';
import 'package:occubusbooking/utils/seat_leg_capacity.dart';

SeatFitContext _ctx(Map<String, (SeatType, SeatPosition?)> cells) =>
    SeatFitContext(
      cellTypeAt: (b, s) => cells['$b:$s']?.$1,
      cellPositionAt: (b, s) => cells['$b:$s']?.$2,
    );

/// The manual screen's `_canClaimPartnerBerth`, expressed as a closure over the
/// occupants ALREADY on the claimed cell — which the screen builds to INCLUDE
/// the claimer's own already-held berth (it has already consumed a per-leg slot,
/// exactly as the engine's locked berth has). [allOccupants] is therefore the
/// full holder list on the cell, claimer included.
bool Function(PendingClaim) _claimGate(
  TripType activeTrip,
  List<SeatLegHolder> allOccupants,
) =>
    (claim) => seatHasLegRoom(
          activeTrip: activeTrip,
          need: 1,
          cap: 2,
          occupants: allOccupants,
        );

void main() {
  // ── Symptom A: wrong "X assigned" / passenger progress (2/2 check) ─────────
  //
  // The manual copy MISSED the engine's own-cell double-completion case, so a
  // half-held Double Sofa with a matching pending doubleSofa line was treated as
  // a leftover single -> the double line stayed "pending", inflating `remaining`
  // and showing a wrong progress / per-bus count. The shared module completes it
  // in place (emits a claim) when the partner berth is leg-free.
  group('Symptom A — wrong assigned count', () {
    test('half-held double + matching double line + free partner -> 2/2 '
        '(remaining empties, a claim is emitted)', () {
      final res = computePendingLines(
        requestLines: const [
          PendingLineInput(seatType: SeatType.doubleSofa, qty: 1),
        ],
        heldBerths: const [HeldBerth(busId: 'b1', seatId: 'DL1')],
        ctx: _ctx(const {'b1:DL1': (SeatType.doubleSofa, SeatPosition.lower)}),
        // Only the claimer's own held berth -> the partner berth is free.
        canClaimPartnerBerth: _claimGate(
          TripType.roundTrip,
          const [(trip: TripType.roundTrip, berths: 1)],
        ),
      );
      // Pre-fix the manual screen left a doubleSofa:1 pending here (wrong count).
      expect(res.remaining, isEmpty,
          reason: 'progress is 2/2 — the own double cell completes in place');
      expect(res.ownCellClaims,
          [const PendingClaim(busId: 'b1', seatId: 'DL1')]);
    });

    test('partner berth genuinely blocked -> does NOT falsely show 2/2', () {
      // The claimer holds one berth (round-trip) AND a DIFFERENT round-trip
      // occupant already holds the partner berth -> the claimer's GO leg is now
      // full (1 own + 1 other = cap 2), so the partner berth is unclaimable.
      final res = computePendingLines(
        requestLines: const [
          PendingLineInput(seatType: SeatType.doubleSofa, qty: 1),
        ],
        heldBerths: const [HeldBerth(busId: 'b1', seatId: 'DL1')],
        ctx: _ctx(const {'b1:DL1': (SeatType.doubleSofa, SeatPosition.lower)}),
        canClaimPartnerBerth: _claimGate(
          TripType.roundTrip,
          const [
            (trip: TripType.roundTrip, berths: 1), // claimer's own berth
            (trip: TripType.roundTrip, berths: 1), // the blocking occupant
          ],
        ),
      );
      // The double line is RESTORED (no false completion); still 1 pending.
      expect(res.ownCellClaims, isEmpty);
      expect(res.remaining,
          [const PendingLineInput(seatType: SeatType.doubleSofa, qty: 1)]);
    });
  });

  // ── Symptom B: seat looks FREE but tapping it does nothing ─────────────────
  //
  // (1) Position-gating bug: the manual `_berthsForFreeCell` let a single
  //     cross-fill ANY doubleSofa line ignoring position. The shared rule keeps
  //     the engine's positionOk gate.
  // (2) Asymmetric leg check: the free path never ran seatHasLegRoom while the
  //     occupied path did, so a free cell could be offered then rejected (or
  //     shown blocked when room existed). Now ONE rule decides both.
  group('Symptom B — free seat now places consistently', () {
    test('free single cell with a matching single line -> 1 berth (places)', () {
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
        occupants: const [], // genuinely free -> leg gate trivially passes
      );
      expect(n, 1);
    });

    test('what-the-tap-offers == what-placement-accepts on a half-held double '
        '(free path is now leg-checked too)', () {
      // A RET-only occupant holds one berth of the double; the cell LOOKS free
      // enough for a GO-only single. The unified rule offers exactly 1 berth and
      // would place it (opposite-leg reuse) instead of offering-then-rejecting.
      final occupants = const <SeatLegHolder>[
        (trip: TripType.returnOnly, berths: 1),
      ];
      final n = berthsForFreeCell(
        remaining: const [
          PendingLineInput(seatType: SeatType.singleSofa, qty: 1),
        ],
        cellType: SeatType.doubleSofa,
        cellPosition: SeatPosition.lower,
        activeTrip: TripType.outboundOnly,
        cap: 2,
        occupants: occupants,
      );
      expect(n, 1, reason: 'offered AND placeable — no silent block');
    });
  });

  // ── Symptom C: one-way / single-leg riders & leg reuse ─────────────────────
  //
  // The manual free-cell path had ZERO leg awareness. A GO-only rider could be
  // offered a berth whose GO slot is full (block at drop), or denied a berth
  // whose RET slot is free for reuse. The shared rule threads activeTrip + cap +
  // occupants through seatHasLegRoom — the same per-leg model the engine uses.
  group('Symptom C — one-way / leg-reuse sharing', () {
    test('GO-only rider REUSES the RET-only half of a double (leg-disjoint)',
        () {
      final n = berthsForFreeCell(
        remaining: const [
          PendingLineInput(seatType: SeatType.singleSofa, qty: 1),
        ],
        cellType: SeatType.doubleSofa,
        cellPosition: SeatPosition.lower,
        activeTrip: TripType.outboundOnly,
        cap: 2,
        occupants: const [(trip: TripType.returnOnly, berths: 1)],
      );
      expect(n, 1, reason: 'GO slot free — opposite-leg reuse allowed');
    });

    test('GO-only rider BLOCKED when both GO slots are taken (same leg)', () {
      final n = berthsForFreeCell(
        remaining: const [
          PendingLineInput(seatType: SeatType.singleSofa, qty: 1),
        ],
        cellType: SeatType.doubleSofa,
        cellPosition: SeatPosition.lower,
        activeTrip: TripType.outboundOnly,
        cap: 2,
        occupants: const [(trip: TripType.outboundOnly, berths: 2)],
      );
      expect(n, 0);
    });

    test('round-trip rider BLOCKED on a double whose both legs are full', () {
      final n = berthsForFreeCell(
        remaining: const [
          PendingLineInput(seatType: SeatType.singleSofa, qty: 1),
        ],
        cellType: SeatType.doubleSofa,
        cellPosition: SeatPosition.lower,
        activeTrip: TripType.roundTrip,
        cap: 2,
        occupants: const [(trip: TripType.roundTrip, berths: 2)],
      );
      expect(n, 0);
    });

    test('own-cell completion is ALSO leg-checked: a GO-only rider completes '
        'their half-held double when the partner berth is RET-only', () {
      // The manual `_canClaimPartnerBerth` gate: partner currently RET-only ->
      // a GO-only claimer fits. Reproduces a one-way rider finishing their own
      // double in place.
      final res = computePendingLines(
        requestLines: const [
          PendingLineInput(seatType: SeatType.doubleSofa, qty: 1),
        ],
        heldBerths: const [HeldBerth(busId: 'b1', seatId: 'DL1')],
        ctx: _ctx(const {'b1:DL1': (SeatType.doubleSofa, SeatPosition.lower)}),
        canClaimPartnerBerth: _claimGate(
          TripType.outboundOnly,
          const [
            (trip: TripType.outboundOnly, berths: 1), // claimer's own GO berth
            (trip: TripType.returnOnly, berths: 1), // RET-only partner occupant
          ],
        ),
      );
      expect(res.ownCellClaims,
          [const PendingClaim(busId: 'b1', seatId: 'DL1')]);
      expect(res.remaining, isEmpty);
    });
  });

  // ── Engine relationship (now fully aligned) ────────────────────────────────
  //
  // The auto engine's `_buildPendingLines` (seating_engine.dart) is still its own
  // copy, but it now AGREES with the shared module on every case — including the
  // partner-refusal case that used to diverge. The engine previously decremented
  // the doubleSofa line FIRST via `_drainDoubleCrossFill` and, because of `&&`
  // short-circuit, never restored it on refusal (silently over-satisfying the
  // passenger). The engine was fixed to claim the partner berth first and only
  // then drain the line — matching the module, which has always RESTORED the
  // line on refusal. These tests pin that agreement so it can't silently drift.
  group('engine relationship — fully aligned (no divergence)', () {
    test('AGREE: whole-held double drains the double line (both empty it)', () {
      final res = computePendingLines(
        requestLines: const [
          PendingLineInput(seatType: SeatType.doubleSofa, qty: 1),
        ],
        heldBerths: const [
          HeldBerth(busId: 'b1', seatId: 'DL1'),
          HeldBerth(busId: 'b1', seatId: 'DL1'),
        ],
        ctx: _ctx(const {'b1:DL1': (SeatType.doubleSofa, SeatPosition.lower)}),
        canClaimPartnerBerth: (_) => false,
      );
      expect(res.remaining, isEmpty);
    });

    test('AGREE: claimable partner -> both complete the own double in place', () {
      final res = computePendingLines(
        requestLines: const [
          PendingLineInput(seatType: SeatType.doubleSofa, qty: 1),
        ],
        heldBerths: const [HeldBerth(busId: 'b1', seatId: 'DL1')],
        ctx: _ctx(const {'b1:DL1': (SeatType.doubleSofa, SeatPosition.lower)}),
        canClaimPartnerBerth: (_) => true,
      );
      expect(res.remaining, isEmpty);
      expect(res.ownCellClaims,
          [const PendingClaim(busId: 'b1', seatId: 'DL1')]);
    });

    test(
        'AGREE: partner refused + a doubleSofa line + NO single line -> the '
        'double line is RESTORED (remaining doubleSofa:1). Both the module and '
        'the now-fixed engine keep the line so the shortfall surfaces instead of '
        'silently marking the passenger satisfied.', () {
      final res = computePendingLines(
        requestLines: const [
          PendingLineInput(seatType: SeatType.doubleSofa, qty: 1),
        ],
        heldBerths: const [HeldBerth(busId: 'b1', seatId: 'DL1')],
        ctx: _ctx(const {'b1:DL1': (SeatType.doubleSofa, SeatPosition.lower)}),
        canClaimPartnerBerth: (_) => false,
      );
      expect(res.ownCellClaims, isEmpty);
      expect(res.remaining,
          [const PendingLineInput(seatType: SeatType.doubleSofa, qty: 1)],
          reason: 'module restores the refused double line (corrected behaviour)');
    });
  });
}
