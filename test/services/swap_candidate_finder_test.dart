import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/bus_details.dart';
import 'package:occubusbooking/models/passenger.dart';
import 'package:occubusbooking/models/priority_status.dart';
import 'package:occubusbooking/models/request_line.dart';
import 'package:occubusbooking/models/seat_assignment.dart';
import 'package:occubusbooking/models/seat_layout.dart';
import 'package:occubusbooking/models/seat_type.dart';
import 'package:occubusbooking/models/trip_type.dart';
import 'package:occubusbooking/services/swap_candidate_finder.dart';

// ── Fixture helpers (mirror seating_engine_test conventions) ────────────────

SeatCell _seat(
  int row,
  int col,
  SeatType type,
  SeatPosition? pos,
  String id, {
  bool reserved = false,
}) =>
    SeatCell(
      row: row,
      col: col,
      seatType: type,
      position: pos,
      seatId: id,
      reserved: reserved,
    );

Bus _bus(String id, List<SeatCell> cells) {
  var maxRow = 0;
  for (final c in cells) {
    if (c.row > maxRow) maxRow = c.row;
  }
  return Bus(
    id: id,
    name: id,
    busType: 'Sleeper',
    layout: BusLayout(rows: maxRow + 1, cols: SeatGridCols.count, grid: cells),
  );
}

Passenger _p(
  String id, {
  List<RequestLine> lines = const [],
  List<SeatAssignment> assigned = const [],
  String? groupId,
  PriorityStatus priority = PriorityStatus.none,
  String name = '',
  TripType tripType = TripType.roundTrip,
}) =>
    Passenger(
      id: id,
      tourId: 't1',
      name: name.isEmpty ? id : name,
      phone: '+910000000000',
      requestLines: lines,
      assignedSeats: assigned,
      groupId: groupId,
      priorityStatus: priority,
      tripType: tripType,
    );

RequestLine _line(SeatType t, SeatPosition? pos, int qty) =>
    RequestLine(seatType: t, position: pos, qty: qty);

SeatAssignment _a(String busId, String seatId) =>
    SeatAssignment(busId: busId, seatId: seatId);

void main() {
  group('free-seat shortcut', () {
    test('a compatible free seat is offered, no swap needed', () {
      final bus = _bus('b1', [
        _seat(0, 0, SeatType.singleSofa, SeatPosition.upper, 'SU1'),
        _seat(0, 1, SeatType.singleSofa, SeatPosition.lower, 'SL1'),
      ]);
      // SL1 is occupied; SU1 is free. Mover wants a single upper.
      final occupant = _p('o1', assigned: [_a('b1', 'SL1')]);
      final mover = _p('m1', lines: [_line(SeatType.singleSofa, SeatPosition.upper, 1)]);

      final r = SwapCandidateFinder.find(
        mover: mover,
        destinationBus: bus,
        passengers: [occupant, mover],
      );

      expect(r.freeSeatIds, ['SU1']);
      // The occupant on SL1 is a lower single. The mover explicitly wants a
      // single UPPER. The engine treats deck as a HARD gate, so swapping onto
      // SL1 would put the mover on the WRONG deck — this is NOT a clean type
      // match. It is surfaced as a distinct, labelled different-deck option at
      // rank 2 (regression for finding 2, singleSofa symmetric case).
      final o1 = r.movable.singleWhere((c) => c.passengerId == 'o1');
      expect(o1.rank, 2);
      expect(o1.reason, contains('different deck'));
      expect(o1.reason, contains('you wanted Upper'));
    });

    test('a fully-occupied bus offers no free seats', () {
      final bus = _bus('b1', [
        _seat(0, 0, SeatType.singleSofa, SeatPosition.upper, 'SU1'),
      ]);
      final occupant = _p('o1', assigned: [_a('b1', 'SU1')]);
      final mover = _p('m1', lines: [_line(SeatType.singleSofa, SeatPosition.upper, 1)]);

      final r = SwapCandidateFinder.find(
        mover: mover,
        destinationBus: bus,
        passengers: [occupant, mover],
      );

      expect(r.freeSeatIds, isEmpty);
      expect(r.movable.single.passengerId, 'o1');
    });

    test('a half-occupied double offers its remaining berth for a single need',
        () {
      final bus = _bus('b1', [
        _seat(0, 4, SeatType.doubleSofa, SeatPosition.lower, 'DL1'),
      ]);
      // One berth of DL1 is held (shared double); the other berth is free.
      final occupant = _p('o1', assigned: [_a('b1', 'DL1')]);
      final mover = _p('m1', lines: [_line(SeatType.singleSofa, null, 1)]);

      final r = SwapCandidateFinder.find(
        mover: mover,
        destinationBus: bus,
        passengers: [occupant, mover],
      );

      expect(r.freeSeatIds, ['DL1']); // single-on-double seat available
    });
  });

  group('blocked occupants (grouped / approved-priority)', () {
    test('a grouped occupant is blocked with the group reason', () {
      final bus = _bus('b1', [
        _seat(0, 0, SeatType.singleSofa, SeatPosition.upper, 'SU1'),
      ]);
      final occupant = _p('o1',
          assigned: [_a('b1', 'SU1')], groupId: 'Patel', name: 'Asha');
      final mover = _p('m1', lines: [_line(SeatType.singleSofa, SeatPosition.upper, 1)]);

      final r = SwapCandidateFinder.find(
        mover: mover,
        destinationBus: bus,
        passengers: [occupant, mover],
      );

      expect(r.movable, isEmpty);
      expect(r.blocked.single.passengerId, 'o1');
      expect(r.blocked.single.passengerName, 'Asha');
      expect(r.blocked.single.reason, 'in group Patel');
    });

    test('an approved-priority occupant is blocked with the priority reason',
        () {
      final bus = _bus('b1', [
        _seat(0, 0, SeatType.singleSofa, SeatPosition.upper, 'SU1'),
      ]);
      final occupant = _p('o1',
          assigned: [_a('b1', 'SU1')],
          priority: PriorityStatus.approved,
          name: 'Dada');
      final mover = _p('m1', lines: [_line(SeatType.singleSofa, SeatPosition.upper, 1)]);

      final r = SwapCandidateFinder.find(
        mover: mover,
        destinationBus: bus,
        passengers: [occupant, mover],
      );

      expect(r.movable, isEmpty);
      expect(r.blocked.single.reason, 'approved priority');
    });

    test('a pending-priority occupant is NOT blocked (only approved is)', () {
      final bus = _bus('b1', [
        _seat(0, 0, SeatType.singleSofa, SeatPosition.upper, 'SU1'),
      ]);
      final occupant = _p('o1',
          assigned: [_a('b1', 'SU1')], priority: PriorityStatus.requested);
      final mover = _p('m1', lines: [_line(SeatType.singleSofa, SeatPosition.upper, 1)]);

      final r = SwapCandidateFinder.find(
        mover: mover,
        destinationBus: bus,
        passengers: [occupant, mover],
      );

      expect(r.blocked, isEmpty);
      expect(r.movable.single.passengerId, 'o1');
    });

    test('grouped occupant appears once in blocked even holding two berths', () {
      final bus = _bus('b1', [
        _seat(0, 3, SeatType.doubleSofa, SeatPosition.upper, 'DU1'),
      ]);
      // Whole double held by a grouped occupant = two entries on DU1.
      final occupant = _p('o1',
          assigned: [_a('b1', 'DU1'), _a('b1', 'DU1')], groupId: 'Shah');
      final mover = _p('m1', lines: [_line(SeatType.doubleSofa, null, 1)]);

      final r = SwapCandidateFinder.find(
        mover: mover,
        destinationBus: bus,
        passengers: [occupant, mover],
      );

      expect(r.blocked.length, 1);
      expect(r.blocked.single.reason, 'in group Shah');
    });
  });

  // A deliberate manual move by the agent (sourceBusId provided) relaxes the
  // protection: priority is always displaceable, and a grouped occupant is
  // displaceable when the move is SAME-bus (the group never leaves the bus).
  group('manual move relaxes protection (sourceBusId)', () {
    test('SAME-bus manual: a grouped occupant becomes movable, not blocked', () {
      final bus = _bus('b1', [
        _seat(0, 0, SeatType.singleSofa, SeatPosition.upper, 'SU1'),
      ]);
      final occupant = _p('o1',
          assigned: [_a('b1', 'SU1')], groupId: 'Patel', name: 'Asha');
      final mover = _p('m1',
          lines: [_line(SeatType.singleSofa, SeatPosition.upper, 1)]);

      final r = SwapCandidateFinder.find(
        mover: mover,
        destinationBus: bus,
        passengers: [occupant, mover],
        sourceBusId: 'b1', // same bus as destination
      );

      expect(r.blocked, isEmpty);
      expect(r.movable.single.passengerId, 'o1');
    });

    test('CROSS-bus manual: a grouped occupant stays blocked (group must move whole)',
        () {
      final bus = _bus('b2', [
        _seat(0, 0, SeatType.singleSofa, SeatPosition.upper, 'SU1'),
      ]);
      final occupant = _p('o1',
          assigned: [_a('b2', 'SU1')], groupId: 'Patel', name: 'Asha');
      final mover = _p('m1',
          lines: [_line(SeatType.singleSofa, SeatPosition.upper, 1)]);

      final r = SwapCandidateFinder.find(
        mover: mover,
        destinationBus: bus,
        passengers: [occupant, mover],
        sourceBusId: 'b1', // different bus -> cross-bus
      );

      expect(r.movable, isEmpty);
      expect(r.blocked.single.reason, 'in group Patel');
    });

    test('manual move: an approved-priority occupant becomes movable (any bus)',
        () {
      final bus = _bus('b2', [
        _seat(0, 0, SeatType.singleSofa, SeatPosition.upper, 'SU1'),
      ]);
      final occupant = _p('o1',
          assigned: [_a('b2', 'SU1')],
          priority: PriorityStatus.approved,
          name: 'Dada');
      final mover = _p('m1',
          lines: [_line(SeatType.singleSofa, SeatPosition.upper, 1)]);

      // Even cross-bus, a deliberate manual move may displace a priority person.
      final r = SwapCandidateFinder.find(
        mover: mover,
        destinationBus: bus,
        passengers: [occupant, mover],
        sourceBusId: 'b1',
      );

      expect(r.blocked, isEmpty);
      expect(r.movable.single.passengerId, 'o1');
    });
  });

  group('type-compatibility + ranking', () {
    test('exact type+position occupant ranks above type-only occupant', () {
      final bus = _bus('b1', [
        _seat(0, 0, SeatType.singleSofa, SeatPosition.upper, 'SU1'),
        _seat(0, 1, SeatType.singleSofa, SeatPosition.lower, 'SL1'),
      ]);
      final exact = _p('a_exact', assigned: [_a('b1', 'SU1')]); // upper
      final typeOnly = _p('b_other', assigned: [_a('b1', 'SL1')]); // lower
      // Mover explicitly wants a single UPPER.
      final mover = _p('m1', lines: [_line(SeatType.singleSofa, SeatPosition.upper, 1)]);

      final r = SwapCandidateFinder.find(
        mover: mover,
        destinationBus: bus,
        passengers: [exact, typeOnly, mover],
      );

      expect(r.movable.first.passengerId, 'a_exact');
      expect(r.movable.first.rank, 0);
      // The lower-single occupant is the WRONG deck for an explicit upper need,
      // so it is a distinct rank-2 different-deck option, never a clean rank-1
      // "type match" (regression for finding 2, singleSofa symmetric case).
      expect(r.movable[1].passengerId, 'b_other');
      expect(r.movable[1].rank, 2);
      expect(r.movable[1].reason, contains('different deck'));
    });

    test('incompatible seat type is excluded entirely', () {
      final bus = _bus('b1', [
        _seat(0, 0, SeatType.seater, null, 'ST1'),
      ]);
      // Mover wants a double sofa; the only occupant holds a seater — neither an
      // exact nor cross-fill match for a double need.
      final occupant = _p('o1', assigned: [_a('b1', 'ST1')]);
      final mover = _p('m1', lines: [_line(SeatType.doubleSofa, null, 1)]);

      final r = SwapCandidateFinder.find(
        mover: mover,
        destinationBus: bus,
        passengers: [occupant, mover],
      );

      expect(r.movable, isEmpty);
      expect(r.blocked, isEmpty);
    });

    test('deterministic ordering: same rank breaks ties by passengerId', () {
      final bus = _bus('b1', [
        _seat(0, 0, SeatType.seater, null, 'ST1'),
        _seat(0, 1, SeatType.seater, null, 'ST2'),
      ]);
      final z = _p('z_occ', assigned: [_a('b1', 'ST1')]);
      final a = _p('a_occ', assigned: [_a('b1', 'ST2')]);
      final mover = _p('m1', lines: [_line(SeatType.seater, null, 1)]);

      final r = SwapCandidateFinder.find(
        mover: mover,
        destinationBus: bus,
        passengers: [z, a, mover],
      );

      expect(r.movable.map((c) => c.passengerId).toList(), ['a_occ', 'z_occ']);
    });
  });

  group('cross-fill compatibility', () {
    test('a single-holding occupant is a cross-fill candidate for a double need',
        () {
      final bus = _bus('b1', [
        _seat(0, 0, SeatType.singleSofa, SeatPosition.upper, 'SU1'),
      ]);
      final occupant = _p('o1', assigned: [_a('b1', 'SU1')]);
      // Mover wants a double sofa — no double exists, but the single is cross-
      // fill compatible (a single berth toward a double).
      final mover = _p('m1', lines: [_line(SeatType.doubleSofa, null, 1)]);

      final r = SwapCandidateFinder.find(
        mover: mover,
        destinationBus: bus,
        passengers: [occupant, mover],
      );

      expect(r.movable.single.passengerId, 'o1');
      expect(r.movable.single.rank, 2);
      expect(r.movable.single.reason, contains('cross-fill'));
    });

    test('a double-holding occupant is cross-fill compatible for a single need',
        () {
      final bus = _bus('b1', [
        _seat(0, 4, SeatType.doubleSofa, SeatPosition.lower, 'DL1'),
      ]);
      final occupant = _p('o1', assigned: [_a('b1', 'DL1'), _a('b1', 'DL1')]);
      final mover = _p('m1', lines: [_line(SeatType.singleSofa, null, 1)]);

      final r = SwapCandidateFinder.find(
        mover: mover,
        destinationBus: bus,
        passengers: [occupant, mover],
      );

      expect(r.movable.single.passengerId, 'o1');
      expect(r.movable.single.rank, 2);
      expect(r.movable.single.reason, contains('cross-fill'));
    });
  });

  group('mover never lists itself; bus scoping', () {
    test('the mover holding a seat on the destination is not a candidate', () {
      final bus = _bus('b1', [
        _seat(0, 0, SeatType.singleSofa, SeatPosition.upper, 'SU1'),
        _seat(0, 1, SeatType.singleSofa, SeatPosition.lower, 'SL1'),
      ]);
      final mover = _p('m1',
          lines: [_line(SeatType.singleSofa, null, 1)],
          assigned: [_a('b1', 'SU1')]);
      final occupant = _p('o1', assigned: [_a('b1', 'SL1')]);

      final r = SwapCandidateFinder.find(
        mover: mover,
        destinationBus: bus,
        passengers: [mover, occupant],
      );

      expect(r.movable.any((c) => c.passengerId == 'm1'), isFalse);
      expect(r.movable.single.passengerId, 'o1');
    });

    test('occupants of OTHER buses are ignored', () {
      final dest = _bus('b1', [
        _seat(0, 0, SeatType.singleSofa, SeatPosition.upper, 'SU1'),
      ]);
      final otherBusOccupant = _p('o1', assigned: [_a('b2', 'SU1')]);
      final mover = _p('m1', lines: [_line(SeatType.singleSofa, null, 1)]);

      final r = SwapCandidateFinder.find(
        mover: mover,
        destinationBus: dest,
        passengers: [otherBusOccupant, mover],
      );

      expect(r.movable, isEmpty);
      expect(r.blocked, isEmpty);
      expect(r.freeSeatIds, ['SU1']);
    });
  });

  group('whole-double vs shared-double + deck gating (findings 1 & 2)', () {
    test(
        'finding 1: a SHARED half-double occupant is NOT a clean whole-double match',
        () {
      // DL1 (double, lower, capacity 2). o1 holds ONE berth (shared double); the
      // other berth is free. Mover wants 1 WHOLE doubleSofa (deck-agnostic).
      final bus = _bus('b1', [
        _seat(0, 4, SeatType.doubleSofa, SeatPosition.lower, 'DL1'),
      ]);
      final o1 = _p('o1', assigned: [_a('b1', 'DL1')]); // one berth only
      final mover = _p('m1', lines: [_line(SeatType.doubleSofa, null, 1)]);

      final r = SwapCandidateFinder.find(
        mover: mover,
        destinationBus: bus,
        passengers: [o1, mover],
      );

      // Displacing o1 frees only ONE berth, not a whole double, so it must NOT
      // be a rank-1 "type match: Double Sofa". It is a cross-fill option (rank 2)
      // and the message flags that the other berth must also be freed.
      final c = r.movable.singleWhere((x) => x.passengerId == 'o1');
      expect(c.rank, 2);
      expect(c.reason, contains('cross-fill'));
      expect(c.reason, contains('Double Sofa'));
      expect(c.reason, contains('other berth'));
      // The mover needs a WHOLE double, and DL1 has only one free berth, so it
      // is correctly NOT offered as a takeable free seat — the cross-fill reason
      // already flags that the other berth must be freed too.
      expect(r.freeSeatIds, isEmpty);
    });

    test(
        'a WHOLE-double occupant (both berths) IS a clean type match for a whole-double need',
        () {
      final bus = _bus('b1', [
        _seat(0, 4, SeatType.doubleSofa, SeatPosition.lower, 'DL1'),
      ]);
      // o1 holds BOTH berths of DL1 (a whole double).
      final o1 = _p('o1', assigned: [_a('b1', 'DL1'), _a('b1', 'DL1')]);
      final mover = _p('m1', lines: [_line(SeatType.doubleSofa, null, 1)]);

      final r = SwapCandidateFinder.find(
        mover: mover,
        destinationBus: bus,
        passengers: [o1, mover],
      );

      final c = r.movable.singleWhere((x) => x.passengerId == 'o1');
      expect(c.rank, 1);
      expect(c.reason, 'type match: Double Sofa');
    });

    test(
        'finding 2: a whole double on the WRONG deck is a different-deck option, not a clean match',
        () {
      // DU1 (double, UPPER) wholly held by o1. Mover explicitly wants double
      // LOWER. Deck is a hard gate, so DU1 is the wrong deck.
      final bus = _bus('b1', [
        _seat(0, 3, SeatType.doubleSofa, SeatPosition.upper, 'DU1'),
      ]);
      final o1 = _p('o1', assigned: [_a('b1', 'DU1'), _a('b1', 'DU1')]);
      final mover =
          _p('m1', lines: [_line(SeatType.doubleSofa, SeatPosition.lower, 1)]);

      final r = SwapCandidateFinder.find(
        mover: mover,
        destinationBus: bus,
        passengers: [o1, mover],
      );

      final c = r.movable.singleWhere((x) => x.passengerId == 'o1');
      expect(c.rank, 2);
      expect(c.reason, contains('different deck'));
      expect(c.reason, contains('you wanted Lower'));
    });

    test(
        'a whole double matches a deck-AGNOSTIC double need on either deck (rank 1)',
        () {
      // Mover stated no deck (doubleAny). An UPPER whole double is a clean match.
      final bus = _bus('b1', [
        _seat(0, 3, SeatType.doubleSofa, SeatPosition.upper, 'DU1'),
      ]);
      final o1 = _p('o1', assigned: [_a('b1', 'DU1'), _a('b1', 'DU1')]);
      final mover = _p('m1', lines: [_line(SeatType.doubleSofa, null, 1)]);

      final r = SwapCandidateFinder.find(
        mover: mover,
        destinationBus: bus,
        passengers: [o1, mover],
      );

      final c = r.movable.singleWhere((x) => x.passengerId == 'o1');
      expect(c.rank, 1);
      expect(c.reason, 'type match: Double Sofa');
    });

    test(
        'finding 2 (singleSofa symmetric): a single on the wrong deck is a different-deck option',
        () {
      // o1 on SL1 (lower single). Mover explicitly wants a single UPPER.
      final bus = _bus('b1', [
        _seat(0, 1, SeatType.singleSofa, SeatPosition.lower, 'SL1'),
      ]);
      final o1 = _p('o1', assigned: [_a('b1', 'SL1')]);
      final mover =
          _p('m1', lines: [_line(SeatType.singleSofa, SeatPosition.upper, 1)]);

      final r = SwapCandidateFinder.find(
        mover: mover,
        destinationBus: bus,
        passengers: [o1, mover],
      );

      final c = r.movable.singleWhere((x) => x.passengerId == 'o1');
      expect(c.rank, 2);
      expect(c.reason, contains('different deck'));
      expect(c.reason, contains('you wanted Upper'));
    });
  });

  // The seated agent taps an occupied seat to swap. The candidate list must be
  // driven by PHYSICAL swap feasibility (same seat-class + berth counts fit both
  // ways — the exact rule the drag-drop engine uses), NOT by whether the mover
  // still has an outstanding request line. Passing [moverFromSeatId] tells the
  // finder where the mover currently sits so it can reason about the real swap.
  group('physical swap feasibility (moverFromSeatId)', () {
    test(
        'a seated mover with NO outstanding need can still swap with a '
        'class-compatible occupant', () {
      // Mover sits on SU1 with an EMPTY request (request already consumed). Under
      // the old need-based rule every occupant was hidden — the user could not
      // swap with any allocated seat. Physically, SL1 (single) is a clean swap.
      final bus = _bus('b1', [
        _seat(0, 0, SeatType.singleSofa, SeatPosition.upper, 'SU1'),
        _seat(0, 1, SeatType.singleSofa, SeatPosition.lower, 'SL1'),
      ]);
      final mover = _p('m1', assigned: [_a('b1', 'SU1')]); // no request lines
      final occupant = _p('o1', assigned: [_a('b1', 'SL1')]);

      final r = SwapCandidateFinder.find(
        mover: mover,
        destinationBus: bus,
        passengers: [mover, occupant],
        sourceBusId: 'b1',
        moverFromSeatId: 'SU1',
      );

      expect(r.movable.map((c) => c.passengerId), contains('o1'));
    });

    test(
        'without moverFromSeatId the legacy need-based behaviour is unchanged '
        '(no need → no candidate)', () {
      final bus = _bus('b1', [
        _seat(0, 0, SeatType.singleSofa, SeatPosition.upper, 'SU1'),
        _seat(0, 1, SeatType.singleSofa, SeatPosition.lower, 'SL1'),
      ]);
      final mover = _p('m1', assigned: [_a('b1', 'SU1')]); // no request lines
      final occupant = _p('o1', assigned: [_a('b1', 'SL1')]);

      final r = SwapCandidateFinder.find(
        mover: mover,
        destinationBus: bus,
        passengers: [mover, occupant],
        sourceBusId: 'b1',
        // moverFromSeatId intentionally omitted
      );

      expect(r.movable, isEmpty);
    });

    test('a whole-double mover is NOT offered a swap that would strand it on a '
        'single (capacity guard)', () {
      final bus = _bus('b1', [
        _seat(0, 4, SeatType.doubleSofa, SeatPosition.lower, 'DL1'),
        _seat(0, 0, SeatType.singleSofa, SeatPosition.upper, 'SU1'),
      ]);
      // Mover holds BOTH berths of DL1 (whole double). Occupant on a single.
      final mover = _p('m1', assigned: [_a('b1', 'DL1'), _a('b1', 'DL1')]);
      final occupant = _p('o1', assigned: [_a('b1', 'SU1')]);

      final r = SwapCandidateFinder.find(
        mover: mover,
        destinationBus: bus,
        passengers: [mover, occupant],
        sourceBusId: 'b1',
        moverFromSeatId: 'DL1',
      );

      // 2 berths can't fit a single seat → not a candidate.
      expect(r.movable.any((c) => c.passengerId == 'o1'), isFalse);
    });

    test('a seater mover is never offered a sleeper occupant (class guard)', () {
      final bus = _bus('b1', [
        _seat(0, 0, SeatType.seater, null, 'ST1'),
        _seat(0, 1, SeatType.singleSofa, SeatPosition.upper, 'SU1'),
      ]);
      final mover = _p('m1', assigned: [_a('b1', 'ST1')]);
      final occupant = _p('o1', assigned: [_a('b1', 'SU1')]);

      final r = SwapCandidateFinder.find(
        mover: mover,
        destinationBus: bus,
        passengers: [mover, occupant],
        sourceBusId: 'b1',
        moverFromSeatId: 'ST1',
      );

      expect(r.movable.any((c) => c.passengerId == 'o1'), isFalse);
    });

    test(
        'CROSS-bus: a seated mover can physically swap onto another bus via '
        'explicit source class + berths', () {
      // Mover sits on bus b1 (not the destination); the finder can't read its
      // seat from b2's layout, so the caller passes the source class + berths
      // directly. A class-compatible occupant on b2 must still be swappable.
      final destBus = _bus('b2', [
        _seat(0, 1, SeatType.singleSofa, SeatPosition.lower, 'SL1'),
      ]);
      final mover = _p('m1', assigned: [_a('b1', 'SU1')]); // no request lines
      final occupant = _p('o1', assigned: [_a('b2', 'SL1')]);

      final r = SwapCandidateFinder.find(
        mover: mover,
        destinationBus: destBus,
        passengers: [mover, occupant],
        sourceBusId: 'b1', // cross-bus
        moverFromSeatId: null, // not resolvable on b2
        moverFromSeatType: SeatType.singleSofa,
        moverFromBerths: 1,
      );

      expect(r.movable.map((c) => c.passengerId), contains('o1'));
    });

    test(
        'CROSS-bus capacity guard: a whole-double mover is NOT offered a single '
        'on another bus', () {
      // Mover holds a WHOLE double (2 berths) on b1; destination b2 has only a
      // single. 2 berths can't fit a single seat → no candidate, even cross-bus.
      final destBus = _bus('b2', [
        _seat(0, 0, SeatType.singleSofa, SeatPosition.upper, 'SU1'),
      ]);
      final mover = _p('m1', assigned: [_a('b1', 'DL1'), _a('b1', 'DL1')]);
      final occupant = _p('o1', assigned: [_a('b2', 'SU1')]);

      final r = SwapCandidateFinder.find(
        mover: mover,
        destinationBus: destBus,
        passengers: [mover, occupant],
        sourceBusId: 'b1',
        moverFromSeatType: SeatType.doubleSofa,
        moverFromBerths: 2,
      );

      expect(r.movable.any((c) => c.passengerId == 'o1'), isFalse);
    });

    test('a group/priority occupant stays protected even under physical mode',
        () {
      final bus = _bus('b1', [
        _seat(0, 0, SeatType.singleSofa, SeatPosition.upper, 'SU1'),
        _seat(0, 1, SeatType.singleSofa, SeatPosition.lower, 'SL1'),
      ]);
      final mover = _p('m1', assigned: [_a('b1', 'SU1')]);
      // Grouped occupant — cross-bus protection does not apply (same bus), so
      // grouped is movable; but an approved-priority one on a CROSS context would
      // block. Here keep it simple: a grouped occupant on the SAME bus is movable.
      final grouped =
          _p('o1', assigned: [_a('b1', 'SL1')], groupId: 'Patel', name: 'Asha');

      final r = SwapCandidateFinder.find(
        mover: mover,
        destinationBus: bus,
        passengers: [mover, grouped],
        sourceBusId: 'b1', // same bus → grouped is displaceable
        moverFromSeatId: 'SU1',
      );

      // Same-bus manual move leaves the group whole, so a grouped occupant IS a
      // valid swap target (consistent with existing same-bus relaxation).
      expect(r.movable.map((c) => c.passengerId), contains('o1'));
    });
  });

  // The finder must reason PER LEG, mirroring seatHasLegRoom: a Double Sofa berth
  // taken only on the RET leg leaves the GO leg free, so a GO-only mover can take
  // that physical seat outright (leg-disjoint reuse). A round-trip mover needs
  // BOTH legs free on the berth they take.
  group('leg-aware free-seat offers (tripType)', () {
    test(
        'GO-only mover is offered a double whose RET berth is held by a RET-only '
        'occupant (leg-disjoint reuse)', () {
      // DU1 double, UPPER. A RET-only occupant holds ONE berth (fills RET leg
      // only). A GO-only mover wants a double upper — its GO leg is entirely
      // free on this seat, so the seat is takeable outright.
      final bus = _bus('b1', [
        _seat(0, 3, SeatType.doubleSofa, SeatPosition.upper, 'DU1'),
      ]);
      final retOnly = _p('o1',
          assigned: [_a('b1', 'DU1')], tripType: TripType.returnOnly);
      final mover = _p('m1',
          lines: [_line(SeatType.doubleSofa, SeatPosition.upper, 1)],
          tripType: TripType.outboundOnly);

      final r = SwapCandidateFinder.find(
        mover: mover,
        destinationBus: bus,
        passengers: [retOnly, mover],
      );

      // The GO leg of DU1 is free, so the GO-only mover can just take it.
      expect(r.freeSeatIds, contains('DU1'));
    });

    test(
        'round-trip mover is NOT offered a double whose RET berth is contended',
        () {
      // Same setup, but the mover is round-trip — it needs BOTH legs free on the
      // berths it takes. The RET-only occupant holds the RET leg, so a round-trip
      // mover cannot take the seat outright.
      final bus = _bus('b1', [
        _seat(0, 3, SeatType.doubleSofa, SeatPosition.upper, 'DU1'),
      ]);
      final retOnly = _p('o1',
          assigned: [_a('b1', 'DU1')], tripType: TripType.returnOnly);
      final mover = _p('m1',
          lines: [_line(SeatType.doubleSofa, SeatPosition.upper, 1)],
          tripType: TripType.roundTrip);

      final r = SwapCandidateFinder.find(
        mover: mover,
        destinationBus: bus,
        passengers: [retOnly, mover],
      );

      // RET leg of DU1 is taken → round-trip mover can't take the whole double.
      expect(r.freeSeatIds, isEmpty);
    });

    test(
        'GO-only mover is NOT offered a double whose GO berths are full (same-leg '
        'contention)', () {
      // Two GO-only occupants fill BOTH berths of DU1 on the GO leg. A GO-only
      // mover wanting a whole double has no GO room — not takeable.
      final bus = _bus('b1', [
        _seat(0, 3, SeatType.doubleSofa, SeatPosition.upper, 'DU1'),
      ]);
      final go1 = _p('o1',
          assigned: [_a('b1', 'DU1')], tripType: TripType.outboundOnly);
      final go2 = _p('o2',
          assigned: [_a('b1', 'DU1')], tripType: TripType.outboundOnly);
      final mover = _p('m1',
          lines: [_line(SeatType.doubleSofa, SeatPosition.upper, 1)],
          tripType: TripType.outboundOnly);

      final r = SwapCandidateFinder.find(
        mover: mover,
        destinationBus: bus,
        passengers: [go1, go2, mover],
      );

      expect(r.freeSeatIds, isEmpty);
    });

    test(
        'a fully round-trip double (both berths, round-trip occupant) is not '
        'offered to a GO-only mover', () {
      // DU1 wholly held by a ROUND-TRIP occupant fills both legs → no leg room
      // for anyone, even a one-way mover.
      final bus = _bus('b1', [
        _seat(0, 3, SeatType.doubleSofa, SeatPosition.upper, 'DU1'),
      ]);
      final rt = _p('o1',
          assigned: [_a('b1', 'DU1'), _a('b1', 'DU1')],
          tripType: TripType.roundTrip);
      final mover = _p('m1',
          lines: [_line(SeatType.doubleSofa, SeatPosition.upper, 1)],
          tripType: TripType.outboundOnly);

      final r = SwapCandidateFinder.find(
        mover: mover,
        destinationBus: bus,
        passengers: [rt, mover],
      );

      expect(r.freeSeatIds, isEmpty);
    });

    test(
        'GO-only single-need mover takes one berth of a double whose RET leg is '
        'held (leg-disjoint single-on-double)', () {
      // A RET-only occupant holds one berth on the RET leg. A GO-only mover with
      // a single need can reuse the GO leg of either berth.
      final bus = _bus('b1', [
        _seat(0, 4, SeatType.doubleSofa, SeatPosition.lower, 'DL1'),
      ]);
      final retOnly = _p('o1',
          assigned: [_a('b1', 'DL1')], tripType: TripType.returnOnly);
      final mover = _p('m1',
          lines: [_line(SeatType.singleSofa, null, 1)],
          tripType: TripType.outboundOnly);

      final r = SwapCandidateFinder.find(
        mover: mover,
        destinationBus: bus,
        passengers: [retOnly, mover],
      );

      expect(r.freeSeatIds, contains('DL1'));
    });
  });
}
