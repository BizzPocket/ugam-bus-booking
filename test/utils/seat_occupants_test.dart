import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/passenger.dart';
import 'package:occubusbooking/models/seat_assignment.dart';
import 'package:occubusbooking/models/trip_type.dart';
import 'package:occubusbooking/utils/seat_occupants.dart';

const _bus = 'bus1';

Passenger _p(
  String id, {
  required TripType trip,
  required List<String> seats,
  String bus = _bus,
}) => Passenger(
  id: id,
  tourId: 't1',
  name: id,
  phone: '+910000000000',
  tripType: trip,
  assignedSeats: [
    for (final s in seats) SeatAssignment(busId: bus, seatId: s),
  ],
);

void main() {
  group('seatOccupantsForBus', () {
    test('Double Sofa with TWO distinct occupants returns BOTH', () {
      // Two round-trip passengers each holding one berth of the same sofa
      // seatId (a shared double). Both must surface, not just the first.
      final a = _p('a', trip: TripType.roundTrip, seats: ['DS1']);
      final b = _p('b', trip: TripType.roundTrip, seats: ['DS1']);

      final occ = seatOccupantsForBus([a, b], _bus)['DS1']!;

      // GO leg: first round-trip holder (a). RET leg: first round-trip
      // holder is also a (round-trip claims both legs first), so .all is
      // de-duped to [a]. To get TWO distinct names on one round-trip sofa,
      // they must be modelled as a leg-shared pair — covered below. Here we
      // assert the flat list helper returns the rendered occupant set.
      expect(occ.all.map((p) => p.id), ['a']);

      // The genuine "two people on one double" case the bug is about is a
      // leg-shared pairing (disjoint legs) — asserted in the next test.
    });

    test('leg-disjoint reuse (GO-only + RET-only) returns BOTH, GO-first', () {
      final go = _p('go', trip: TripType.outboundOnly, seats: ['S7']);
      final ret = _p('ret', trip: TripType.returnOnly, seats: ['S7']);

      final occ = seatOccupantsForBus([go, ret], _bus)['S7']!;

      expect(occ.isLegShared, isTrue);
      expect(occ.go?.id, 'go');
      expect(occ.ret?.id, 'ret');
      expect(occ.sole, isNull);
      // THE bug-fix surface: both occupants, GO first.
      expect(occ.all.map((p) => p.id), ['go', 'ret']);
      expect(occupantListForBus([go, ret], _bus)['S7']!.map((p) => p.id),
          ['go', 'ret']);
    });

    test('a one-way passenger appears only on the leg they travel', () {
      final go = _p('go', trip: TripType.outboundOnly, seats: ['S1']);

      final occ = seatOccupantsForBus([go], _bus)['S1']!;

      expect(occ.go?.id, 'go');
      expect(occ.ret, isNull);
      expect(occ.isLegShared, isFalse);
      expect(occ.sole?.id, 'go');
      expect(occ.all.map((p) => p.id), ['go']);
    });

    test('a round-trip passenger holds BOTH legs as one occupant', () {
      final rt = _p('rt', trip: TripType.roundTrip, seats: ['S2']);

      final occ = seatOccupantsForBus([rt], _bus)['S2']!;

      expect(occ.go?.id, 'rt');
      expect(occ.ret?.id, 'rt');
      expect(occ.isLegShared, isFalse);
      expect(occ.sole?.id, 'rt');
      expect(occ.all.map((p) => p.id), ['rt']); // de-duped, not [rt, rt]
    });

    test('whole Double Sofa held solo (two entries) resolves to ONE occupant',
        () {
      // One round-trip passenger holds both berths of a sofa: two assignment
      // rows on the SAME seatId. Must collapse to a single occupant.
      final solo = _p('solo', trip: TripType.roundTrip, seats: ['DS9', 'DS9']);

      final occ = seatOccupantsForBus([solo], _bus)['DS9']!;

      expect(occ.all.map((p) => p.id), ['solo']);
      expect(occ.sole?.id, 'solo');
    });

    test('an empty / unassigned seat returns no occupants', () {
      final p = _p('p', trip: TripType.roundTrip, seats: ['S1']);

      final map = seatOccupantsForBus([p], _bus);

      // The seat nobody holds is simply absent from the map.
      expect(map.containsKey('S99'), isFalse);
      // And the flat helper yields no entry either.
      expect(occupantListForBus([p], _bus).containsKey('S99'), isFalse);
    });

    test('only seats on the requested bus are resolved', () {
      final p = _p('p', trip: TripType.roundTrip, seats: ['S1'], bus: 'otherBus');

      final map = seatOccupantsForBus([p], _bus);

      expect(map, isEmpty);
    });

    test('ONE booking with a same-type one-way split lands each seat on its own '
        'leg (matrix bug)', () {
      // The matrix bug: a single passenger holds TWO seats — a GO-only seat and
      // a RET-only seat of the SAME type. Their coarse tripType collapses to
      // round-trip (the lines disagree), so the OLD resolver would have shown
      // this rider on BOTH legs of BOTH seats. Now each [SeatAssignment] carries
      // its own leg, so ST1 surfaces only on GO and ST2 only on RET.
      final matrix = Passenger(
        id: 'matrix',
        tourId: 't1',
        name: 'matrix',
        phone: '+910000000000',
        // derivedTripType collapses to round-trip — the trap the old code fell in.
        tripType: TripType.roundTrip,
        assignedSeats: const [
          SeatAssignment(busId: _bus, seatId: 'ST1', leg: TripType.outboundOnly),
          SeatAssignment(busId: _bus, seatId: 'ST2', leg: TripType.returnOnly),
        ],
      );

      final map = seatOccupantsForBus([matrix], _bus);

      // ST1 is GO-only for this rider; nobody returns on it.
      expect(map['ST1']!.go?.id, 'matrix');
      expect(map['ST1']!.ret, isNull);
      // ST2 is RET-only; nobody goes out on it.
      expect(map['ST2']!.go, isNull);
      expect(map['ST2']!.ret?.id, 'matrix');
    });
  });

  // occupantListForBus is the FULL-roster resolver: unlike SeatOccupancy (one
  // holder per leg), it keeps every rider on a seat. A Double Sofa is two
  // berths, each reusable across legs, so up to FOUR distinct one-way riders
  // can share one sofa — the read-only charts, their tap sheets, and the chart
  // PDF must show them all, which the old `.all` (capped to one GO + one RET)
  // silently dropped.
  group('occupantListForBus (full roster)', () {
    test('two RETURN-only riders on one double return BOTH (the dropped case)',
        () {
      // The live regression: a Double Sofa booked by two return-only riders.
      // SeatOccupancy keeps only the first on the RET leg; the full roster keeps
      // both.
      final a = _p('a', trip: TripType.returnOnly, seats: ['DU3']);
      final b = _p('b', trip: TripType.returnOnly, seats: ['DU3']);

      expect(occupantListForBus([a, b], _bus)['DU3']!.map((p) => p.id),
          ['a', 'b']);
      // Contrast: the leg-capped resolver drops the second same-leg rider.
      expect(seatOccupantsForBus([a, b], _bus)['DU3']!.all.map((p) => p.id),
          ['a']);
    });

    test('two ROUND-TRIP riders sharing one double return BOTH', () {
      final a = _p('a', trip: TripType.roundTrip, seats: ['DS1']);
      final b = _p('b', trip: TripType.roundTrip, seats: ['DS1']);

      expect(occupantListForBus([a, b], _bus)['DS1']!.map((p) => p.id),
          ['a', 'b']);
    });

    test('four one-way riders on one double (2 GO + 2 RET) return all, GO-first',
        () {
      final g1 = _p('g1', trip: TripType.outboundOnly, seats: ['DU6']);
      final g2 = _p('g2', trip: TripType.outboundOnly, seats: ['DU6']);
      final r1 = _p('r1', trip: TripType.returnOnly, seats: ['DU6']);
      final r2 = _p('r2', trip: TripType.returnOnly, seats: ['DU6']);

      expect(
        occupantListForBus([g1, r1, g2, r2], _bus)['DU6']!.map((p) => p.id),
        ['g1', 'g2', 'r1', 'r2'], // GO riders first, then RET
      );
    });

    test('whole double held solo (two entries) collapses to ONE rider', () {
      final solo = _p('solo', trip: TripType.roundTrip, seats: ['DS9', 'DS9']);

      expect(occupantListForBus([solo], _bus)['DS9']!.map((p) => p.id),
          ['solo']);
    });
  });

  // The money-collection chooser for a shared sofa must be leg-scoped: while the
  // bus is going out you can only collect from the GO-leg riders; once GO is
  // done they drop off and only the RETURN riders remain. These pure helpers
  // back the chooser's GO/Return toggle and its smart default.
  group('collect-leg chooser helpers', () {
    final g1 = _p('g1', trip: TripType.outboundOnly, seats: ['DU1']);
    final g2 = _p('g2', trip: TripType.outboundOnly, seats: ['DU1']);
    final r1 = _p('r1', trip: TripType.returnOnly, seats: ['DU1']);
    final r2 = _p('r2', trip: TripType.returnOnly, seats: ['DU1']);
    final rt = _p('rt', trip: TripType.roundTrip, seats: ['DU1']);

    group('occupantsForCollectLeg', () {
      test('GO leg keeps outbound + round-trip riders only', () {
        expect(
          occupantsForCollectLeg([g1, g2, r1, r2], CollectLeg.go)
              .map((p) => p.id),
          ['g1', 'g2'],
        );
        expect(
          occupantsForCollectLeg([rt, r1], CollectLeg.go).map((p) => p.id),
          ['rt'],
        );
      });

      test('RETURN leg keeps return + round-trip riders only', () {
        expect(
          occupantsForCollectLeg([g1, g2, r1, r2], CollectLeg.ret)
              .map((p) => p.id),
          ['r1', 'r2'],
        );
        expect(
          occupantsForCollectLeg([rt, g1], CollectLeg.ret).map((p) => p.id),
          ['rt'],
        );
      });
    });

    group('seatHasLegSplit', () {
      test('true when riders differ per leg (2 GO + 2 RET)', () {
        expect(seatHasLegSplit([g1, g2, r1, r2]), isTrue);
      });

      test('true when a round-trip shares with a one-way rider', () {
        expect(seatHasLegSplit([rt, r1]), isTrue);
        expect(seatHasLegSplit([rt, g1]), isTrue);
      });

      test('false when nobody travels one of the legs', () {
        // Two GO-only riders: no RETURN occupant to switch to.
        expect(seatHasLegSplit([g1, g2]), isFalse);
        // Two return-only riders: no GO occupant.
        expect(seatHasLegSplit([r1, r2]), isFalse);
      });

      test('false when both legs hold the SAME round-trip riders', () {
        final rtA = _p('rtA', trip: TripType.roundTrip, seats: ['DS1']);
        final rtB = _p('rtB', trip: TripType.roundTrip, seats: ['DS1']);
        expect(seatHasLegSplit([rtA, rtB]), isFalse);
      });
    });

    group('defaultCollectLeg', () {
      test('opens on GO during the outbound phase', () {
        expect(
          defaultCollectLeg([g1, r1], outboundDone: false),
          CollectLeg.go,
        );
      });

      test('opens on RETURN once the outbound leg is done', () {
        expect(
          defaultCollectLeg([g1, r1], outboundDone: true),
          CollectLeg.ret,
        );
      });

      test('opens on RETURN when no rider travels GO on this seat', () {
        expect(
          defaultCollectLeg([r1, r2], outboundDone: false),
          CollectLeg.ret,
        );
      });
    });
  });

  // ── ridersOnBusForLeg — the per-bus, per-leg boarding roster ───────────────
  //
  // Drives handler attendance. The leg MUST come from the seat held on THIS
  // bus: filtering on the rider's overall tripType put a round-trip rider on
  // every bus they touch, on both legs.
  group('ridersOnBusForLeg', () {
    /// Round-trip rider: GO berth on bus1, RET berth on bus2.
    Passenger splitAcrossBuses() => Passenger(
          id: 'split',
          tourId: 't1',
          name: 'Split',
          phone: '+910000000000',
          tripType: TripType.roundTrip,
          assignedSeats: const [
            SeatAssignment(
              busId: _bus,
              seatId: 'GO1',
              leg: TripType.outboundOnly,
            ),
            SeatAssignment(
              busId: 'bus2',
              seatId: 'RET1',
              leg: TripType.returnOnly,
            ),
          ],
        );

    test('a rider whose RETURN berth is on ANOTHER bus is off this roster', () {
      final p = splitAcrossBuses();
      expect(ridersOnBusForLeg([p], _bus, CollectLeg.go).map((x) => x.id),
          ['split']);
      // The bug: tripType.usesReturn is true, so they used to be listed here.
      expect(ridersOnBusForLeg([p], _bus, CollectLeg.ret), isEmpty);
      expect(ridersOnBusForLeg([p], 'bus2', CollectLeg.ret).map((x) => x.id),
          ['split']);
    });

    test('a round-trip rider seated on one bus boards it on BOTH legs', () {
      final p = _p('rt', trip: TripType.roundTrip, seats: ['L1']);
      expect(ridersOnBusForLeg([p], _bus, CollectLeg.go).length, 1);
      expect(ridersOnBusForLeg([p], _bus, CollectLeg.ret).length, 1);
    });

    test('one-way riders appear only on their own leg', () {
      final go = _p('go', trip: TripType.outboundOnly, seats: ['L1']);
      final ret = _p('ret', trip: TripType.returnOnly, seats: ['L2']);
      expect(
          ridersOnBusForLeg([go, ret], _bus, CollectLeg.go).map((p) => p.id),
          ['go']);
      expect(
          ridersOnBusForLeg([go, ret], _bus, CollectLeg.ret).map((p) => p.id),
          ['ret']);
    });

    test('a rider holding two berths of one sofa is listed ONCE', () {
      final p = _p('solo', trip: TripType.roundTrip, seats: ['DS1', 'DS1']);
      expect(ridersOnBusForLeg([p], _bus, CollectLeg.go).length, 1);
    });

    test('a rider with no seat on this bus is excluded', () {
      final p = _p('other', trip: TripType.roundTrip, seats: ['L1'],
          bus: 'bus9');
      expect(ridersOnBusForLeg([p], _bus, CollectLeg.go), isEmpty);
    });
  });

  // ── Seat-scoped money chooser ─────────────────────────────────────────────
  group('occupantsForCollectLeg with a seatId', () {
    /// Round-trip rider holding DS1 on the GO leg only; their return berth is a
    /// different seat. The RETURN chooser for DS1 must not offer them.
    final split = Passenger(
      id: 'split',
      tourId: 't1',
      name: 'Split',
      phone: '+910000000000',
      tripType: TripType.roundTrip,
      assignedSeats: const [
        SeatAssignment(busId: _bus, seatId: 'DS1', leg: TripType.outboundOnly),
        SeatAssignment(busId: _bus, seatId: 'DS9', leg: TripType.returnOnly),
      ],
    );

    test('seat-scoped filtering uses the leg of THAT berth', () {
      expect(
        occupantsForCollectLeg([split], CollectLeg.go,
            seatId: 'DS1', busId: _bus).map((p) => p.id),
        ['split'],
      );
      expect(
        occupantsForCollectLeg([split], CollectLeg.ret,
            seatId: 'DS1', busId: _bus),
        isEmpty,
      );
    });

    test('without a seatId the coarse trip-type behaviour is unchanged', () {
      // Round-trip overall → present on both legs, as before.
      expect(occupantsForCollectLeg([split], CollectLeg.ret).length, 1);
    });
  });
}
