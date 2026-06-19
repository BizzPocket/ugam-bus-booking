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

    test('double GO+RET on one berth, markHalfDouble → legShareHalf (half free)', () {
      final r = resolveSeatRender(
        cell: _cell(SeatType.doubleSofa),
        occupants: [_p('g', TripType.outboundOnly), _p('r', TripType.returnOnly)],
        markHalfDouble: true,
      );
      expect(r.kind, SeatRenderKind.legShareHalf);
    });

    test('double GO+RET, markHalfDouble OFF → legShare (no free-half info)', () {
      final r = resolveSeatRender(
        cell: _cell(SeatType.doubleSofa),
        occupants: [_p('g', TripType.outboundOnly), _p('r', TripType.returnOnly)],
        markHalfDouble: false,
      );
      expect(r.kind, SeatRenderKind.legShare);
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
}
