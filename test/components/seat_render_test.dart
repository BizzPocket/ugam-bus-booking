import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/components/seat_render.dart';
import 'package:occubusbooking/models/passenger.dart';
import 'package:occubusbooking/models/seat_layout.dart';
import 'package:occubusbooking/models/seat_type.dart';
import 'package:occubusbooking/models/trip_type.dart';

// resolveSeatRender is the ONE pure decision that picks which seat tile to draw.
// These tests LOCK the current SeatChartTile behaviour (the decision tree in its
// build()) so the extraction is provably a no-op, before any new state is added.

Passenger _p(String id, TripType trip) => Passenger(
      id: id,
      tourId: 't',
      name: id,
      phone: '+910000000000',
      tripType: trip,
    );

SeatCell _cell(SeatType type, {bool reserved = false}) => SeatCell(
      row: 0,
      col: 0,
      seatType: type,
      seatId: 'S1',
      reserved: reserved,
    );

void main() {
  group('resolveSeatRender — current behaviour (characterization)', () {
    test('empty free cell → free', () {
      final r = resolveSeatRender(cell: _cell(SeatType.singleSofa), occupants: const []);
      expect(r.kind, SeatRenderKind.free);
    });

    test('empty reserved cell → held', () {
      final r = resolveSeatRender(
          cell: _cell(SeatType.singleSofa, reserved: true), occupants: const []);
      expect(r.kind, SeatRenderKind.held);
    });

    test('anonymous overrides everything → anonymous', () {
      final r = resolveSeatRender(
        cell: _cell(SeatType.doubleSofa),
        occupants: [_p('a', TripType.roundTrip), _p('b', TripType.roundTrip)],
        anonymous: true,
      );
      expect(r.kind, SeatRenderKind.anonymous);
    });

    test('single sofa, one round-trip rider → booked', () {
      final r = resolveSeatRender(
          cell: _cell(SeatType.singleSofa), occupants: [_p('a', TripType.roundTrip)]);
      expect(r.kind, SeatRenderKind.booked);
      expect(r.primary?.id, 'a');
    });

    test('seater, one rider → booked', () {
      final r = resolveSeatRender(
          cell: _cell(SeatType.seater), occupants: [_p('a', TripType.roundTrip)]);
      expect(r.kind, SeatRenderKind.booked);
    });

    test('double held solo (same rider twice), markHalfDouble → booked (not half)', () {
      final p = _p('a', TripType.roundTrip);
      final r = resolveSeatRender(
          cell: _cell(SeatType.doubleSofa), occupants: [p, p], markHalfDouble: true);
      expect(r.kind, SeatRenderKind.booked);
    });

    test('WHOLE ONE-LEG double (same rider twice, GO only) → GO row taken, RET row free', () {
      // One rider holds BOTH berths but only on GO, so both RETURN berths are
      // free. It must NOT read as fully booked, so the agent can SEE and fill
      // the free opposite-leg capacity — now expressed as an empty RET row.
      final p = _p('a', TripType.outboundOnly);
      final r = resolveSeatRender(
          cell: _cell(SeatType.doubleSofa), occupants: [p, p], markHalfDouble: true);
      expect(r.kind, SeatRenderKind.quad);
      expect(r.quadGo.map((p) => p.id).toList(), ['a']);
      expect(r.quadRet, isEmpty); // the free RETURN leg
    });

    test('double, one berth used, markHalfDouble → halfDouble', () {
      final r = resolveSeatRender(
          cell: _cell(SeatType.doubleSofa),
          occupants: [_p('a', TripType.roundTrip)],
          markHalfDouble: true);
      expect(r.kind, SeatRenderKind.halfDouble);
    });

    test('double, one berth used, markHalfDouble OFF → booked', () {
      final r = resolveSeatRender(
          cell: _cell(SeatType.doubleSofa),
          occupants: [_p('a', TripType.roundTrip)],
          markHalfDouble: false);
      expect(r.kind, SeatRenderKind.booked);
    });

    test('double, two distinct same-leg riders → shared', () {
      final r = resolveSeatRender(
        cell: _cell(SeatType.doubleSofa),
        occupants: [_p('a', TripType.roundTrip), _p('b', TripType.roundTrip)],
        markHalfDouble: true,
      );
      expect(r.kind, SeatRenderKind.shared);
      expect(r.sharedA?.id, 'a');
      expect(r.sharedB?.id, 'b');
    });

    test('single sofa shared GO+RET (2 different legs) → legShare', () {
      final r = resolveSeatRender(
        cell: _cell(SeatType.singleSofa),
        occupants: [_p('g', TripType.outboundOnly), _p('r', TripType.returnOnly)],
      );
      expect(r.kind, SeatRenderKind.legShare);
      expect(r.go?.id, 'g');
      expect(r.ret?.id, 'r');
    });

    test('double GO+RET on one berth, markHalfDouble → leg rows (was legShareHalf)', () {
      // See the "draws its LEGS as rows" group: the spare berth no longer
      // quarters the two riders into the left column.
      final r = resolveSeatRender(
        cell: _cell(SeatType.doubleSofa),
        occupants: [_p('g', TripType.outboundOnly), _p('r', TripType.returnOnly)],
        markHalfDouble: true,
      );
      expect(r.kind, SeatRenderKind.quad);
    });

    test('double GO+RET, markHalfDouble OFF → same leg rows (berth count is irrelevant)', () {
      // The leg rows come from the riders' legs, not from counting berths, so a
      // leg-deduped chart draws the identical GO-over-RET tile.
      final r = resolveSeatRender(
        cell: _cell(SeatType.doubleSofa),
        occupants: [_p('g', TripType.outboundOnly), _p('r', TripType.returnOnly)],
        markHalfDouble: false,
      );
      expect(r.kind, SeatRenderKind.quad);
      expect(r.quadGo.map((p) => p.id).toList(), ['g']);
      expect(r.quadRet.map((p) => p.id).toList(), ['r']);
    });

    // ASYMMETRIC berth use: the whole sofa is booked on ONE leg (both berths)
    // but only one berth is used on the OTHER leg. Both of these now draw the
    // same leg rows — a rider owns the full width of the leg they ride, and a
    // spare berth WITHIN an occupied leg row is deliberately not carved out
    // (that carve-out is what quartered the riders). Free capacity still shows
    // whenever an entire leg row is empty.
    test('whole sofa on RET (r=2) + one GO rider (g=1) → one rider per leg row', () {
      final ret = _p('ret', TripType.returnOnly);
      final go = _p('go', TripType.outboundOnly);
      // Berth-accurate occupants: the RET holder owns BOTH return berths (id
      // appears twice), plus one GO rider reusing a berth on the outbound leg.
      final r = resolveSeatRender(
        cell: _cell(SeatType.doubleSofa),
        occupants: [ret, ret, go],
        markHalfDouble: true,
      );
      expect(r.kind, SeatRenderKind.quad);
      expect(r.quadGo.map((p) => p.id).toList(), ['go']);
      expect(r.quadRet.map((p) => p.id).toList(), ['ret']);
    });

    test('both legs fully booked (g=2, r=2) → both leg rows taken, none free', () {
      final ret = _p('ret', TripType.returnOnly);
      final go = _p('go', TripType.outboundOnly);
      final r = resolveSeatRender(
        cell: _cell(SeatType.doubleSofa),
        occupants: [ret, ret, go, go],
        markHalfDouble: true,
      );
      expect(r.kind, SeatRenderKind.quad);
      expect(r.quadGo, isNotEmpty);
      expect(r.quadRet, isNotEmpty);
    });
  });

  // NEW: a double sofa is two berths, each reusable across legs, so up to four
  // distinct riders can share it. The old tile drew two + a "+N" badge — the
  // case that read as a bug. quad lays them out as a GO row over a RET row.
  group('resolveSeatRender — quad (3-4 riders on a double)', () {
    test('four one-way riders → quad, two per leg row, no +N', () {
      final r = resolveSeatRender(
        cell: _cell(SeatType.doubleSofa),
        occupants: [
          _p('g1', TripType.outboundOnly),
          _p('g2', TripType.outboundOnly),
          _p('r1', TripType.returnOnly),
          _p('r2', TripType.returnOnly),
        ],
        markHalfDouble: true,
      );
      expect(r.kind, SeatRenderKind.quad);
      expect(r.quadGo.map((p) => p.id).toList(), ['g1', 'g2']);
      expect(r.quadRet.map((p) => p.id).toList(), ['r1', 'r2']);
      expect(r.extra, 0);
    });

    test('leg-share berth + whole round-trip berth (3 riders) → quad', () {
      final r = resolveSeatRender(
        cell: _cell(SeatType.doubleSofa),
        occupants: [
          _p('g', TripType.outboundOnly),
          _p('r', TripType.returnOnly),
          _p('rt', TripType.roundTrip),
        ],
        markHalfDouble: true,
      );
      expect(r.kind, SeatRenderKind.quad);
      // a round-trip rider holds BOTH legs of their berth → in both rows
      expect(r.quadGo.map((p) => p.id), containsAll(<String>['g', 'rt']));
      expect(r.quadRet.map((p) => p.id), containsAll(<String>['r', 'rt']));
    });

    test('three riders on the SAME leg (over-booked GO) → 3rd surfaces as +N, never hidden', () {
      final r = resolveSeatRender(
        cell: _cell(SeatType.doubleSofa),
        occupants: [
          _p('g1', TripType.outboundOnly),
          _p('g2', TripType.outboundOnly),
          _p('g3', TripType.outboundOnly),
        ],
        markHalfDouble: true,
      );
      expect(r.kind, SeatRenderKind.quad);
      // The GO row only seats two; the 3rd must be COUNTED, not silently dropped.
      expect(r.quadGo.length, 2);
      expect(r.extra, 1);
    });

    test('two round-trip + one one-way → the one-way rider surfaces as +N', () {
      final r = resolveSeatRender(
        cell: _cell(SeatType.doubleSofa),
        occupants: [
          _p('a', TripType.roundTrip),
          _p('b', TripType.roundTrip),
          _p('g', TripType.outboundOnly),
        ],
        markHalfDouble: true,
      );
      expect(r.kind, SeatRenderKind.quad);
      // a & b fill BOTH rows (round-trip holds each berth on both legs), so the
      // one-way rider has no slot on its leg → it must be counted, not hidden.
      expect(r.extra, 1);
    });

    test('a single sofa never quads — GO+RET stays legShare', () {
      final r = resolveSeatRender(
        cell: _cell(SeatType.singleSofa),
        occupants: [_p('g', TripType.outboundOnly), _p('r', TripType.returnOnly)],
      );
      expect(r.kind, SeatRenderKind.legShare);
    });
  });

  // REGRESSION (chart video, 2026-07-23). A Double Sofa tile is a LEG grid: the
  // GO riders on the top row, the RET riders on the bottom, each row splitting
  // side-by-side only when that leg actually carries two riders. The 3-4 rider
  // `quad` path already drew it that way, but the <=2 occupant paths each used
  // their OWN geometry, and both of those read as bugs on the chart:
  //   * a GO + RET pair with a spare berth quartered BOTH riders (legShareHalf's
  //     2x2: the leg pair squeezed into the left column, one merged empty berth
  //     down the right) instead of giving each rider the full width of their
  //     leg row;
  //   * two SAME-leg riders stacked over the WHOLE tile (`shared`), so the
  //     opposite leg — entirely free — read as fully booked.
  // One model for every occupancy: whenever the two legs carry different
  // riders, the tile draws leg rows.
  group('resolveSeatRender — a double draws its LEGS as rows', () {
    test('GO + RET rider, one berth each → leg rows, each rider FULL width', () {
      // Video: DL1 held by a GO-only rider; a RET-only single is shared in.
      // The GO rider must keep the whole top row, not shrink to a quarter.
      final r = resolveSeatRender(
        cell: _cell(SeatType.doubleSofa),
        occupants: [_p('go', TripType.outboundOnly), _p('ret', TripType.returnOnly)],
        markHalfDouble: true,
      );
      expect(r.kind, SeatRenderKind.quad);
      // One rider per row → each row renders as a single full-width half.
      expect(r.quadGo.map((p) => p.id).toList(), ['go']);
      expect(r.quadRet.map((p) => p.id).toList(), ['ret']);
      expect(r.extra, 0);
    });

    test('two SAME-leg riders → both on the GO row, RET row left free', () {
      // Video: two GO-only singles merged into the empty double DL2. They both
      // ride outbound, so they belong side-by-side on the GO row — the RETURN
      // leg is untouched and must still read as free, not fully booked.
      final r = resolveSeatRender(
        cell: _cell(SeatType.doubleSofa),
        occupants: [_p('g1', TripType.outboundOnly), _p('g2', TripType.outboundOnly)],
        markHalfDouble: true,
      );
      expect(r.kind, SeatRenderKind.quad);
      expect(r.quadGo.map((p) => p.id).toList(), ['g1', 'g2']);
      expect(r.quadRet, isEmpty); // free RETURN leg → empty bottom row
      expect(r.extra, 0);
    });

    test('two ROUND-TRIP sharers stay stacked — both legs carry the same pair', () {
      // The common "two people share a sofa for the whole trip" case. Leg rows
      // would print both names TWICE; keep the denser stacked tile.
      final r = resolveSeatRender(
        cell: _cell(SeatType.doubleSofa),
        occupants: [_p('a', TripType.roundTrip), _p('b', TripType.roundTrip)],
        markHalfDouble: true,
      );
      expect(r.kind, SeatRenderKind.shared);
    });

    test('lone RET-only rider sits on the RET row, not the top one', () {
      // The old halfDouble tile always drew the occupant on top, so a
      // return-only rider appeared on the outbound row.
      final r = resolveSeatRender(
        cell: _cell(SeatType.doubleSofa),
        occupants: [_p('ret', TripType.returnOnly)],
        markHalfDouble: true,
      );
      expect(r.kind, SeatRenderKind.quad);
      expect(r.quadGo, isEmpty);
      expect(r.quadRet.map((p) => p.id).toList(), ['ret']);
    });

    test('lone ROUND-TRIP rider on one berth still stacks over a free half', () {
      // Both legs carry the same (single) rider → no leg split to show.
      final r = resolveSeatRender(
        cell: _cell(SeatType.doubleSofa),
        occupants: [_p('a', TripType.roundTrip)],
        markHalfDouble: true,
      );
      expect(r.kind, SeatRenderKind.halfDouble);
    });
  });
}
