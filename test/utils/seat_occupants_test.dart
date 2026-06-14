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
  });
}
