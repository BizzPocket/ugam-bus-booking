import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/bus_details.dart';
import 'package:occubusbooking/models/passenger.dart';
import 'package:occubusbooking/models/priority_status.dart';
import 'package:occubusbooking/models/request_line.dart';
import 'package:occubusbooking/models/seat_assignment.dart';
import 'package:occubusbooking/models/seat_layout.dart';
import 'package:occubusbooking/models/seat_type.dart';
import 'package:occubusbooking/models/trip_type.dart';
import 'package:occubusbooking/services/seating_engine.dart';

// ── Fixture helpers ─────────────────────────────────────────────────────────
//
// We build tiny hand-rolled layouts so we control which row each seat is on
// (FRONT = low row index). Seat IDs are explicit and stable for assertions.

SeatCell _seat(
  int row,
  int col,
  SeatType type,
  SeatPosition? pos,
  String id, {
  bool reserved = false,
  bool forward = false,
}) =>
    SeatCell(
      row: row,
      col: col,
      seatType: type,
      position: pos,
      seatId: id,
      reserved: reserved,
      forward: forward,
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
    layout: BusLayout(
      rows: maxRow + 1,
      cols: SeatGridCols.count,
      grid: cells,
    ),
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

/// A 2-row bus: front row (0) has SU1 (single upper), SL1 (single lower);
/// back row (1) has DL1 (double lower, 2 berths) + a seater ST1.
Bus _mixedBus(String id) => _bus(id, [
      _seat(0, 0, SeatType.singleSofa, SeatPosition.upper, '${id}_SU1'),
      _seat(0, 1, SeatType.singleSofa, SeatPosition.lower, '${id}_SL1'),
      _seat(1, 4, SeatType.doubleSofa, SeatPosition.lower, '${id}_DL1'),
      _seat(1, 0, SeatType.seater, null, '${id}_ST1'),
    ]);

/// All assignments for a passenger in the plan, sorted by seatId for stable
/// comparison.
List<String> _seatIds(SeatingPlan plan, String passengerId) =>
    plan.forPassenger(passengerId).map((a) => a.seatId).toList()..sort();

void main() {
  group('type + position matching', () {
    test('a single-upper request lands on the single-upper seat', () {
      final buses = [_mixedBus('b1')];
      final p = _p('p1', lines: [_line(SeatType.singleSofa, SeatPosition.upper, 1)]);
      final plan = SeatingEngine.propose(buses: buses, passengers: [p]);

      expect(plan.exceptions, isEmpty);
      final seats = plan.forPassenger('p1');
      expect(seats.length, 1);
      expect(seats.single.seatId, 'b1_SU1');
    });

    test('position is honored — lower request never takes an upper seat', () {
      // Only an upper single is free; a lower-single request must NOT take it.
      final buses = [
        _bus('b1', [
          _seat(0, 0, SeatType.singleSofa, SeatPosition.upper, 'SU1'),
        ]),
      ];
      final p = _p('p1', lines: [_line(SeatType.singleSofa, SeatPosition.lower, 1)]);
      final plan = SeatingEngine.propose(buses: buses, passengers: [p]);

      expect(plan.forPassenger('p1'), isEmpty);
      expect(plan.exceptions.length, 1);
      expect(plan.exceptions.single.type,
          SeatingExceptionType.seatTypeUnavailable);
    });

    test('a seater request only fills a seater cell', () {
      final buses = [_mixedBus('b1')];
      final p = _p('p1', lines: [_line(SeatType.seater, null, 1)]);
      final plan = SeatingEngine.propose(buses: buses, passengers: [p]);

      expect(plan.exceptions, isEmpty);
      expect(plan.forPassenger('p1').single.seatId, 'b1_ST1');
    });
  });

  group('whole double sofa', () {
    test('a doubleSofa request claims BOTH berths of one double cell', () {
      final buses = [_mixedBus('b1')];
      final p = _p('p1', lines: [_line(SeatType.doubleSofa, SeatPosition.lower, 1)]);
      final plan = SeatingEngine.propose(buses: buses, passengers: [p]);

      expect(plan.exceptions, isEmpty);
      final seats = plan.forPassenger('p1');
      // Two SeatAssignment entries with the SAME seatId = whole double held solo.
      expect(seats.length, 2);
      expect(seats.every((a) => a.seatId == 'b1_DL1'), isTrue);
    });
  });

  group('cross-fill (2 singles satisfy 1 double line)', () {
    test('a doubleSofa line is satisfied by two free single sofas', () {
      // Bus with NO whole double free, but two single sofas.
      final buses = [
        _bus('b1', [
          _seat(0, 0, SeatType.singleSofa, SeatPosition.upper, 'SU1'),
          _seat(0, 1, SeatType.singleSofa, SeatPosition.lower, 'SL1'),
        ]),
      ];
      final p = _p('p1', lines: [_line(SeatType.doubleSofa, null, 1)]);
      final plan = SeatingEngine.propose(buses: buses, passengers: [p]);

      expect(plan.exceptions, isEmpty);
      final seats = plan.forPassenger('p1');
      expect(seats.length, 2);
      expect(_seatIds(plan, 'p1'), ['SL1', 'SU1']);
      // Both are distinct single cells (cross-fill), not the same cell twice.
      expect(seats.map((a) => a.seatId).toSet().length, 2);
    });

    test('a single leftover single can NOT satisfy a double line', () {
      final buses = [
        _bus('b1', [
          _seat(0, 0, SeatType.singleSofa, SeatPosition.upper, 'SU1'),
        ]),
      ];
      final p = _p('p1', lines: [_line(SeatType.doubleSofa, null, 1)]);
      final plan = SeatingEngine.propose(buses: buses, passengers: [p]);

      // Cannot cross-fill with only one single → exception, single left free.
      expect(plan.forPassenger('p1'), isEmpty);
      expect(plan.exceptions.length, 1);
    });
  });

  group('shared double sofa', () {
    test('two unrelated singles each take one berth of the SAME double cell', () {
      // The only sofa seating is ONE double cell (2 berths). Two separate
      // passengers each requesting a single sofa must share it as a half-double.
      final buses = [
        _bus('b1', [
          _seat(0, 3, SeatType.doubleSofa, SeatPosition.upper, 'DU1'),
        ]),
      ];
      final a = _p('a', lines: [_line(SeatType.singleSofa, null, 1)]);
      final b = _p('b', lines: [_line(SeatType.singleSofa, null, 1)]);
      final plan = SeatingEngine.propose(buses: buses, passengers: [a, b]);

      expect(plan.exceptions, isEmpty);
      // Each holds exactly one berth on the shared double cell.
      expect(plan.forPassenger('a').single.seatId, 'DU1');
      expect(plan.forPassenger('b').single.seatId, 'DU1');
      // Two DIFFERENT passengers, one entry each = shared double.
      final allOnDU1 = plan.allAssignments.where((x) => x.seatId == 'DU1');
      expect(allOnDU1.length, 2);
    });
  });

  group('groups', () {
    test('a group is kept entirely on one bus', () {
      // Two buses, each can hold the whole group; engine must pick ONE.
      final buses = [_mixedBus('b1'), _mixedBus('b2')];
      final a = _p('a', groupId: 'g1', lines: [_line(SeatType.seater, null, 1)]);
      final b = _p('b', groupId: 'g1', lines: [_line(SeatType.singleSofa, SeatPosition.upper, 1)]);
      final plan = SeatingEngine.propose(buses: buses, passengers: [a, b]);

      expect(plan.exceptions, isEmpty);
      final busA = plan.forPassenger('a').map((x) => x.busId).toSet();
      final busB = plan.forPassenger('b').map((x) => x.busId).toSet();
      expect(busA.length, 1);
      expect(busB.length, 1);
      expect(busA, busB, reason: 'group members must share one bus');
    });

    test('a group too big for any single bus raises groupWontFit', () {
      // Each bus seats only 1 seater. The group needs 2 seaters → no single
      // bus fits the whole group.
      final buses = [
        _bus('b1', [_seat(0, 0, SeatType.seater, null, 'ST1')]),
        _bus('b2', [_seat(0, 0, SeatType.seater, null, 'ST1')]),
      ];
      final a = _p('a', groupId: 'g1', lines: [_line(SeatType.seater, null, 1)]);
      final b = _p('b', groupId: 'g1', lines: [_line(SeatType.seater, null, 1)]);
      final plan = SeatingEngine.propose(buses: buses, passengers: [a, b]);

      expect(plan.exceptions.any((e) => e.type == SeatingExceptionType.groupWontFit),
          isTrue);
      // All-or-nothing: nothing placed for the group.
      expect(plan.forPassenger('a'), isEmpty);
      expect(plan.forPassenger('b'), isEmpty);
    });
  });

  group('approved priority', () {
    test('approved priority is seated in a FRONT row sofa', () {
      // Front row (0) has a single sofa; back rows (1,2) have sofas too.
      final buses = [
        _bus('b1', [
          _seat(0, 0, SeatType.singleSofa, SeatPosition.upper, 'SU_front'),
          _seat(1, 0, SeatType.singleSofa, SeatPosition.upper, 'SU_back'),
          _seat(2, 0, SeatType.singleSofa, SeatPosition.upper, 'SU_backer'),
        ]),
      ];
      final vip = _p('vip',
          priority: PriorityStatus.approved,
          lines: [_line(SeatType.singleSofa, null, 1)]);
      final plan = SeatingEngine.propose(buses: buses, passengers: [vip]);

      expect(plan.exceptions, isEmpty);
      expect(plan.forPassenger('vip').single.seatId, 'SU_front',
          reason: 'approved priority should take the front-row sofa');
    });

    test('priority seated but no front sofa → priorityNoFrontSeat exception', () {
      // The only sofa is on a back row (row 2 ≥ frontRowCount=2).
      final buses = [
        _bus('b1', [
          _seat(2, 0, SeatType.singleSofa, SeatPosition.upper, 'SU_back'),
        ]),
      ];
      final vip = _p('vip',
          priority: PriorityStatus.approved,
          lines: [_line(SeatType.singleSofa, null, 1)]);
      final plan = SeatingEngine.propose(buses: buses, passengers: [vip]);

      // They DID get a seat (no overflow), but it isn't a front sofa.
      expect(plan.forPassenger('vip').single.seatId, 'SU_back');
      expect(
          plan.exceptions.any(
              (e) => e.type == SeatingExceptionType.priorityNoFrontSeat),
          isTrue);
    });

    test('priority is spread across buses, not stacked on one', () {
      // Two buses, each with exactly one front sofa. Two approved-priority
      // passengers must land on different buses.
      final buses = [
        _bus('b1', [
          _seat(0, 0, SeatType.singleSofa, SeatPosition.upper, 'b1_front'),
          _seat(1, 0, SeatType.singleSofa, SeatPosition.upper, 'b1_back'),
        ]),
        _bus('b2', [
          _seat(0, 0, SeatType.singleSofa, SeatPosition.upper, 'b2_front'),
          _seat(1, 0, SeatType.singleSofa, SeatPosition.upper, 'b2_back'),
        ]),
      ];
      final v1 = _p('v1',
          priority: PriorityStatus.approved,
          lines: [_line(SeatType.singleSofa, null, 1)]);
      final v2 = _p('v2',
          priority: PriorityStatus.approved,
          lines: [_line(SeatType.singleSofa, null, 1)]);
      final plan = SeatingEngine.propose(buses: buses, passengers: [v1, v2]);

      expect(plan.exceptions, isEmpty);
      final b1 = plan.forPassenger('v1').single;
      final b2 = plan.forPassenger('v2').single;
      expect(b1.busId, isNot(b2.busId),
          reason: 'priority passengers should spread across buses');
      // And each got the FRONT seat of its bus.
      expect(b1.seatId.endsWith('front'), isTrue);
      expect(b2.seatId.endsWith('front'), isTrue);
    });
  });

  group('forward-flagged priority zone', () {
    test('a forward seat in a NON-front row wins over an unflagged front seat',
        () {
      // Row 0 is the historical "front" but is UNflagged; row 3 carries the
      // agent-marked forward seat. Approved priority must take the row-3
      // forward seat, not the row-0 one.
      final buses = [
        _bus('b1', [
          _seat(0, 0, SeatType.singleSofa, SeatPosition.upper, 'row0'),
          _seat(1, 0, SeatType.singleSofa, SeatPosition.upper, 'row1'),
          _seat(3, 0, SeatType.singleSofa, SeatPosition.upper, 'row3_fwd',
              forward: true),
        ]),
      ];
      final vip = _p('vip',
          priority: PriorityStatus.approved,
          lines: [_line(SeatType.singleSofa, null, 1)]);
      final plan = SeatingEngine.propose(buses: buses, passengers: [vip]);

      expect(plan.exceptions, isEmpty);
      expect(plan.forPassenger('vip').single.seatId, 'row3_fwd',
          reason: 'agent-marked forward seat overrides the lowest-row heuristic');
      // The placement reason names it the forward seat.
      final r = plan.reasons.singleWhere((r) => r.seatId == 'row3_fwd');
      expect(r.reason.contains('forward seat'), isTrue);
    });

    test('with a forward flag set, a non-priority passenger is kept off the '
        'forward seat for the priority one', () {
      // Only seat marked forward is row3_fwd. A normal passenger sorts first
      // but must yield the forward seat to the approved VIP.
      final buses = [
        _bus('b1', [
          _seat(0, 0, SeatType.singleSofa, SeatPosition.upper, 'plain'),
          _seat(3, 0, SeatType.singleSofa, SeatPosition.upper, 'row3_fwd',
              forward: true),
        ]),
      ];
      final normal =
          _p('normal', lines: [_line(SeatType.singleSofa, null, 1)]);
      final vip = _p('vip',
          priority: PriorityStatus.approved,
          lines: [_line(SeatType.singleSofa, null, 1)]);
      final plan =
          SeatingEngine.propose(buses: buses, passengers: [normal, vip]);

      expect(plan.exceptions, isEmpty);
      expect(plan.forPassenger('vip').single.seatId, 'row3_fwd');
      expect(plan.forPassenger('normal').single.seatId, 'plain');
    });

    test('no forward flag anywhere → fallback to lowest rows (unchanged)', () {
      // No seat is flagged forward; the lowest-frontRowCount-rows heuristic
      // still drives priority placement.
      final buses = [
        _bus('b1', [
          _seat(0, 0, SeatType.singleSofa, SeatPosition.upper, 'front'),
          _seat(2, 0, SeatType.singleSofa, SeatPosition.upper, 'back'),
        ]),
      ];
      final vip = _p('vip',
          priority: PriorityStatus.approved,
          lines: [_line(SeatType.singleSofa, null, 1)]);
      final plan = SeatingEngine.propose(buses: buses, passengers: [vip]);

      expect(plan.exceptions, isEmpty);
      expect(plan.forPassenger('vip').single.seatId, 'front',
          reason: 'fallback to lowest rows when nothing is flagged forward');
    });

    test('forward flags on one bus do not leak into another bus\' fallback',
        () {
      // b1 has a flagged forward seat in row 3. b2 has NO flag, so b2 still
      // uses the lowest-row fallback. Two VIPs spread across buses; each gets
      // its own bus\' forward zone.
      final buses = [
        _bus('b1', [
          _seat(0, 0, SeatType.singleSofa, SeatPosition.upper, 'b1_row0'),
          _seat(3, 0, SeatType.singleSofa, SeatPosition.upper, 'b1_fwd',
              forward: true),
        ]),
        _bus('b2', [
          _seat(0, 0, SeatType.singleSofa, SeatPosition.upper, 'b2_front'),
          _seat(2, 0, SeatType.singleSofa, SeatPosition.upper, 'b2_back'),
        ]),
      ];
      final v1 = _p('v1',
          priority: PriorityStatus.approved,
          lines: [_line(SeatType.singleSofa, null, 1)]);
      final v2 = _p('v2',
          priority: PriorityStatus.approved,
          lines: [_line(SeatType.singleSofa, null, 1)]);
      final plan = SeatingEngine.propose(buses: buses, passengers: [v1, v2]);

      expect(plan.exceptions, isEmpty);
      final placed = {
        plan.forPassenger('v1').single.seatId,
        plan.forPassenger('v2').single.seatId,
      };
      // Each VIP lands on the forward zone of a DIFFERENT bus: b1's flagged seat
      // and b2's lowest-row fallback. Never on b1_row0 (forward flag present, so
      // row0 is no longer forward) and never b2_back.
      expect(placed, {'b1_fwd', 'b2_front'});
    });

    test('priority with only NON-forward sofas still raises priorityNoFrontSeat',
        () {
      // A forward flag exists in the bus (row 3) but it is RESERVED, so the
      // only seat the VIP can take is a non-forward one → priorityNoFrontSeat.
      final buses = [
        _bus('b1', [
          _seat(0, 0, SeatType.singleSofa, SeatPosition.upper, 'plain'),
          _seat(3, 0, SeatType.singleSofa, SeatPosition.upper, 'fwd_reserved',
              forward: true, reserved: true),
        ]),
      ];
      final vip = _p('vip',
          priority: PriorityStatus.approved,
          lines: [_line(SeatType.singleSofa, null, 1)]);
      final plan = SeatingEngine.propose(buses: buses, passengers: [vip]);

      // The VIP gets the only free seat (the non-forward 'plain' one)...
      expect(plan.forPassenger('vip').single.seatId, 'plain');
      // ...but a forward seat was never available → exception fires.
      expect(
          plan.exceptions
              .any((e) => e.type == SeatingExceptionType.priorityNoFrontSeat),
          isTrue);
    });

    test('a reserved + forward seat is never filled (reserved wins)', () {
      // The forward seat is also reserved; it must stay empty, and the VIP
      // takes the only other (non-forward) seat instead.
      final buses = [
        _bus('b1', [
          _seat(0, 0, SeatType.singleSofa, SeatPosition.upper, 'open'),
          _seat(3, 0, SeatType.singleSofa, SeatPosition.upper, 'fwd_reserved',
              forward: true, reserved: true),
        ]),
      ];
      final vip = _p('vip',
          priority: PriorityStatus.approved,
          lines: [_line(SeatType.singleSofa, null, 1)]);
      final plan = SeatingEngine.propose(buses: buses, passengers: [vip]);

      // The reserved+forward seat is never auto-filled by anyone.
      expect(plan.allAssignments.any((a) => a.seatId == 'fwd_reserved'), isFalse);
      expect(plan.forPassenger('vip').single.seatId, 'open');
    });

    test('priority single line takes a forward DOUBLE over a non-forward single '
        '(forward preference spans the type-substitution fallback)', () {
      // b1 has a NON-forward single sofa 'plain' (row 0) and a FORWARD double
      // sofa 'fwdD' (row 3). A single approved-priority individual requests one
      // singleSofa. The VIP must land on a berth of the forward double, NOT on
      // the non-forward single — and no priorityNoFrontSeat may fire.
      final buses = [
        _bus('b1', [
          _seat(0, 0, SeatType.singleSofa, SeatPosition.upper, 'plain'),
          _seat(3, 3, SeatType.doubleSofa, SeatPosition.upper, 'fwdD',
              forward: true),
        ]),
      ];
      final vip = _p('vip',
          priority: PriorityStatus.approved,
          lines: [_line(SeatType.singleSofa, null, 1)]);
      final plan = SeatingEngine.propose(buses: buses, passengers: [vip]);

      expect(plan.forPassenger('vip').single.seatId, 'fwdD',
          reason: 'forward preference must reach the half-double substitute');
      expect(
          plan.exceptions
              .any((e) => e.type == SeatingExceptionType.priorityNoFrontSeat),
          isFalse,
          reason: 'a forward seat WAS available via type substitution');
      // 'plain' must be left free.
      expect(plan.allAssignments.any((a) => a.seatId == 'plain'), isFalse);
    });

    test('priority double line cross-fills two forward SINGLES over a '
        'non-forward whole double', () {
      // b1 has a NON-forward whole double 'plainD' (row 0) and TWO forward
      // singles 'fwdS1'/'fwdS2' (row 3). VIP requests one doubleSofa. The VIP
      // must cross-fill the two forward singles, NOT grab the plain double.
      final buses = [
        _bus('b1', [
          _seat(0, 3, SeatType.doubleSofa, SeatPosition.upper, 'plainD'),
          _seat(3, 0, SeatType.singleSofa, SeatPosition.upper, 'fwdS1',
              forward: true),
          _seat(3, 1, SeatType.singleSofa, SeatPosition.lower, 'fwdS2',
              forward: true),
        ]),
      ];
      final vip = _p('vip',
          priority: PriorityStatus.approved,
          lines: [_line(SeatType.doubleSofa, null, 1)]);
      final plan = SeatingEngine.propose(buses: buses, passengers: [vip]);

      expect(_seatIds(plan, 'vip'), ['fwdS1', 'fwdS2'],
          reason: 'forward cross-fill singles win over a non-forward double');
      expect(
          plan.exceptions
              .any((e) => e.type == SeatingExceptionType.priorityNoFrontSeat),
          isFalse);
      // 'plainD' must be left wholly free.
      expect(plan.allAssignments.any((a) => a.seatId == 'plainD'), isFalse);
    });

    test('determinism: identical input with forward flags is reproducible', () {
      List<Bus> mkBuses() => [
            _bus('b1', [
              _seat(0, 0, SeatType.singleSofa, SeatPosition.upper, 'b1_a'),
              _seat(3, 0, SeatType.singleSofa, SeatPosition.upper, 'b1_fwd',
                  forward: true),
              _seat(3, 1, SeatType.singleSofa, SeatPosition.lower, 'b1_fwd2',
                  forward: true),
            ]),
            _bus('b2', [
              _seat(2, 3, SeatType.doubleSofa, SeatPosition.upper, 'b2_fwd',
                  forward: true),
              _seat(0, 0, SeatType.singleSofa, SeatPosition.upper, 'b2_plain'),
            ]),
          ];
      List<Passenger> mkPax() => [
            _p('v1',
                priority: PriorityStatus.approved,
                lines: [_line(SeatType.singleSofa, null, 1)]),
            _p('v2',
                priority: PriorityStatus.approved,
                lines: [_line(SeatType.singleSofa, null, 1)]),
            _p('n1', lines: [_line(SeatType.singleSofa, null, 1)]),
          ];

      final plan1 = SeatingEngine.propose(buses: mkBuses(), passengers: mkPax());
      final plan2 = SeatingEngine.propose(buses: mkBuses(), passengers: mkPax());

      String repr(SeatingPlan p) {
        final keys = p.assignmentsByPassenger.keys.toList()..sort();
        return [
          for (final k in keys)
            '$k=${(p.forPassenger(k).map((a) => '${a.busId}:${a.seatId}').toList()..sort()).join(",")}'
        ].join('|');
      }

      expect(repr(plan1), repr(plan2));
    });
  });

  group('reserved seats', () {
    test('a reserved seat is never auto-filled', () {
      // The only seater is reserved → the request cannot be placed there.
      final buses = [
        _bus('b1', [
          _seat(0, 0, SeatType.seater, null, 'ST1', reserved: true),
        ]),
      ];
      final p = _p('p1', lines: [_line(SeatType.seater, null, 1)]);
      final plan = SeatingEngine.propose(buses: buses, passengers: [p]);

      expect(plan.forPassenger('p1'), isEmpty);
      expect(plan.allAssignments.any((a) => a.seatId == 'ST1'), isFalse);
      expect(plan.exceptions.length, 1);
    });

    test('a non-reserved seat is used while the reserved one is skipped', () {
      final buses = [
        _bus('b1', [
          _seat(0, 0, SeatType.seater, null, 'ST1', reserved: true),
          _seat(0, 1, SeatType.seater, null, 'ST2'),
        ]),
      ];
      final p = _p('p1', lines: [_line(SeatType.seater, null, 1)]);
      final plan = SeatingEngine.propose(buses: buses, passengers: [p]);

      expect(plan.exceptions, isEmpty);
      expect(plan.forPassenger('p1').single.seatId, 'ST2');
    });
  });

  group('locked assignments', () {
    test('a locked assignment is preserved verbatim across a re-propose', () {
      final buses = [_mixedBus('b1')];
      // p1 already holds a LOCKED seater on ST1, and still needs 1 single upper.
      final locked = SeatAssignment(busId: 'b1', seatId: 'b1_ST1', locked: true);
      final p = _p('p1',
          lines: [
            _line(SeatType.seater, null, 1),
            _line(SeatType.singleSofa, SeatPosition.upper, 1),
          ],
          assigned: [locked]);
      final plan = SeatingEngine.propose(buses: buses, passengers: [p]);

      final seats = plan.forPassenger('p1');
      // The locked seater is preserved exactly (still locked, same seat).
      final lockedBack =
          seats.where((a) => a.seatId == 'b1_ST1').toList();
      expect(lockedBack.length, 1);
      expect(lockedBack.single.locked, isTrue,
          reason: 'locked flag must be preserved');
      // The still-pending single upper got placed.
      expect(seats.any((a) => a.seatId == 'b1_SU1'), isTrue);
      // Locked seater line is NOT double-filled.
      expect(seats.where((a) => a.seatId == 'b1_ST1').length, 1);
    });

    test('a locked berth is not handed to anyone else', () {
      // p1 holds locked single SU1; p2 also requests a single upper. p2 must
      // get the OTHER single, never SU1.
      final buses = [
        _bus('b1', [
          _seat(0, 0, SeatType.singleSofa, SeatPosition.upper, 'SU1'),
          _seat(1, 0, SeatType.singleSofa, SeatPosition.upper, 'SU2'),
        ]),
      ];
      final p1 = _p('p1',
          lines: [_line(SeatType.singleSofa, SeatPosition.upper, 1)],
          assigned: [SeatAssignment(busId: 'b1', seatId: 'SU1', locked: true)]);
      final p2 = _p('p2',
          lines: [_line(SeatType.singleSofa, SeatPosition.upper, 1)]);
      final plan = SeatingEngine.propose(buses: buses, passengers: [p1, p2]);

      expect(plan.exceptions, isEmpty);
      expect(plan.forPassenger('p2').single.seatId, 'SU2');
      expect(plan.forPassenger('p1').any((a) => a.seatId == 'SU1'), isTrue);
    });
  });

  group('capacity / overflow', () {
    test('more requests than seats → overflowWaitlist exception', () {
      // One seat, two seater requests. Second overflows.
      final buses = [
        _bus('b1', [_seat(0, 0, SeatType.seater, null, 'ST1')]),
      ];
      final a = _p('a', lines: [_line(SeatType.seater, null, 1)]);
      final b = _p('b', lines: [_line(SeatType.seater, null, 1)]);
      final plan = SeatingEngine.propose(buses: buses, passengers: [a, b]);

      // a (sorted first) gets the seat; b overflows.
      expect(plan.forPassenger('a').single.seatId, 'ST1');
      expect(plan.forPassenger('b'), isEmpty);
      expect(
          plan.exceptions
              .any((e) => e.type == SeatingExceptionType.overflowWaitlist),
          isTrue);
    });

    test('engine never overbooks a cell', () {
      final buses = [_mixedBus('b1')];
      // Three passengers, all wanting the single seats; capacity is limited.
      final ps = [
        _p('p1', lines: [_line(SeatType.singleSofa, SeatPosition.upper, 1)]),
        _p('p2', lines: [_line(SeatType.singleSofa, SeatPosition.upper, 1)]),
        _p('p3', lines: [_line(SeatType.singleSofa, SeatPosition.upper, 1)]),
      ];
      final plan = SeatingEngine.propose(buses: buses, passengers: ps);

      // Count berths per cell across everyone — none may exceed its capacity.
      final perCell = <String, int>{};
      for (final a in plan.allAssignments) {
        perCell[a.seatId] = (perCell[a.seatId] ?? 0) + 1;
      }
      // SU1 is a single → at most 1 berth.
      expect(perCell['b1_SU1'] ?? 0, lessThanOrEqualTo(1));
    });
  });

  group('determinism', () {
    test('propose twice on identical input yields identical output', () {
      final buses = [_mixedBus('b1'), _mixedBus('b2')];
      List<Passenger> mk() => [
            _p('a', groupId: 'g1', lines: [_line(SeatType.seater, null, 1)]),
            _p('b', groupId: 'g1', lines: [_line(SeatType.singleSofa, null, 1)]),
            _p('c',
                priority: PriorityStatus.approved,
                lines: [_line(SeatType.singleSofa, SeatPosition.upper, 1)]),
            _p('d', lines: [_line(SeatType.doubleSofa, SeatPosition.lower, 1)]),
          ];

      final plan1 = SeatingEngine.propose(buses: buses, passengers: mk());
      final plan2 = SeatingEngine.propose(buses: buses, passengers: mk());

      String repr(SeatingPlan p) {
        final lines = <String>[];
        final keys = p.assignmentsByPassenger.keys.toList()..sort();
        for (final k in keys) {
          final seats = p
              .forPassenger(k)
              .map((a) => '${a.busId}:${a.seatId}:${a.locked}')
              .toList()
            ..sort();
          lines.add('$k=${seats.join(",")}');
        }
        final exc = p.exceptions.map((e) => e.toString()).toList()..sort();
        return '${lines.join("|")}#${exc.join("|")}';
      }

      expect(repr(plan1), repr(plan2));
    });

    test('caller list order does not change the result', () {
      final buses = [_mixedBus('b1')];
      final forward = [
        _p('a', lines: [_line(SeatType.seater, null, 1)]),
        _p('b', lines: [_line(SeatType.singleSofa, SeatPosition.upper, 1)]),
      ];
      final reversed = forward.reversed.toList();

      final p1 = SeatingEngine.propose(buses: buses, passengers: forward);
      final p2 = SeatingEngine.propose(buses: buses, passengers: reversed);

      expect(_seatIds(p1, 'a'), _seatIds(p2, 'a'));
      expect(_seatIds(p1, 'b'), _seatIds(p2, 'b'));
    });
  });

  group('missing / unknown data', () {
    test('a passenger with no request lines is simply unplaced, no exception', () {
      final buses = [_mixedBus('b1')];
      final p = _p('p1'); // no requestLines
      final plan = SeatingEngine.propose(buses: buses, passengers: [p]);

      expect(plan.forPassenger('p1'), isEmpty);
      expect(plan.exceptions, isEmpty);
    });

    test('unknown age group is treated as a normal adult (no priority boost)', () {
      // Default AgeGroup is adult; an un-approved-priority passenger never
      // gets front-seat preference over an approved one.
      final buses = [
        _bus('b1', [
          _seat(0, 0, SeatType.singleSofa, SeatPosition.upper, 'front'),
          _seat(1, 0, SeatType.singleSofa, SeatPosition.upper, 'back'),
        ]),
      ];
      final normal = _p('normal',
          lines: [_line(SeatType.singleSofa, null, 1)]);
      final vip = _p('vip',
          priority: PriorityStatus.approved,
          lines: [_line(SeatType.singleSofa, null, 1)]);
      final plan =
          SeatingEngine.propose(buses: buses, passengers: [normal, vip]);

      expect(plan.exceptions, isEmpty);
      // VIP (approved) must get the front seat even though 'normal' sorts first.
      expect(plan.forPassenger('vip').single.seatId, 'front');
      expect(plan.forPassenger('normal').single.seatId, 'back');
    });

    test('requested-but-not-approved priority gets NO front preference', () {
      final buses = [
        _bus('b1', [
          _seat(0, 0, SeatType.singleSofa, SeatPosition.upper, 'front'),
          _seat(1, 0, SeatType.singleSofa, SeatPosition.upper, 'back'),
        ]),
      ];
      // 'a' merely REQUESTED priority (not approved); 'b' is approved.
      final a = _p('a',
          priority: PriorityStatus.requested,
          lines: [_line(SeatType.singleSofa, null, 1)]);
      final b = _p('b',
          priority: PriorityStatus.approved,
          lines: [_line(SeatType.singleSofa, null, 1)]);
      final plan = SeatingEngine.propose(buses: buses, passengers: [a, b]);

      expect(plan.forPassenger('b').single.seatId, 'front');
      expect(plan.forPassenger('a').single.seatId, 'back');
    });
  });

  group('multi-line individual + balance', () {
    test('a passenger requesting several types gets each satisfied', () {
      final buses = [_mixedBus('b1')];
      final p = _p('p1', lines: [
        _line(SeatType.seater, null, 1),
        _line(SeatType.singleSofa, SeatPosition.upper, 1),
        _line(SeatType.doubleSofa, SeatPosition.lower, 1),
      ]);
      final plan = SeatingEngine.propose(buses: buses, passengers: [p]);

      expect(plan.exceptions, isEmpty);
      // 1 seater + 1 single + 2 double berths = 4 assignment entries.
      final seats = plan.forPassenger('p1');
      expect(seats.length, 4);
      expect(seats.where((a) => a.seatId == 'b1_DL1').length, 2);
      expect(seats.any((a) => a.seatId == 'b1_ST1'), isTrue);
      expect(seats.any((a) => a.seatId == 'b1_SU1'), isTrue);
    });

    test('every proposed berth carries a placement reason', () {
      final buses = [_mixedBus('b1')];
      final p = _p('p1', lines: [_line(SeatType.doubleSofa, SeatPosition.lower, 1)]);
      final plan = SeatingEngine.propose(buses: buses, passengers: [p]);

      expect(plan.forPassenger('p1').length, 2);
      // One reason entry per berth.
      final dlReasons =
          plan.reasons.where((r) => r.seatId == 'b1_DL1').toList();
      expect(dlReasons.length, 2);
      expect(dlReasons.every((r) => r.reason.isNotEmpty), isTrue);
    });
  });

  // ── Regression tests for adversarial-review findings ──────────────────────

  group('regression: positioned doubleSofa cross-fill (finding 1)', () {
    test(
        'a doubleSofa(lower) line cross-fills two DIFFERENT-position singles',
        () {
      // Bus has exactly two free single berths of DIFFERENT positions and no
      // whole double anywhere. A positioned double line must still cross-fill
      // (the singles\' positions are irrelevant for a 2-on-1 bench).
      final buses = [
        _bus('b1', [
          _seat(0, 0, SeatType.singleSofa, SeatPosition.upper, 'SU1'),
          _seat(0, 1, SeatType.singleSofa, SeatPosition.lower, 'SL1'),
        ]),
      ];
      final p =
          _p('p1', lines: [_line(SeatType.doubleSofa, SeatPosition.lower, 1)]);
      final plan = SeatingEngine.propose(buses: buses, passengers: [p]);

      expect(plan.exceptions, isEmpty,
          reason: 'cross-fill must ignore the double line\'s position');
      expect(_seatIds(plan, 'p1'), ['SL1', 'SU1']);
      expect(plan.forPassenger('p1').map((a) => a.seatId).toSet().length, 2);
    });

    test('a doubleSofa(lower) line cross-fills two UPPER half-doubles', () {
      // Two separate double cells, both upper, each contributing one berth.
      // Single berths from doubles must satisfy a positioned double line.
      final buses = [
        _bus('b1', [
          _seat(0, 0, SeatType.doubleSofa, SeatPosition.upper, 'DU1'),
          _seat(0, 2, SeatType.doubleSofa, SeatPosition.upper, 'DU2'),
        ]),
      ];
      // Pre-occupy one berth of each double so neither is a WHOLE double, only
      // a half-double each is free → cross-fill must pair them.
      final filler1 = _p('f1',
          lines: [_line(SeatType.singleSofa, null, 1)],
          assigned: [SeatAssignment(busId: 'b1', seatId: 'DU1', locked: true)]);
      final filler2 = _p('f2',
          lines: [_line(SeatType.singleSofa, null, 1)],
          assigned: [SeatAssignment(busId: 'b1', seatId: 'DU2', locked: true)]);
      final p =
          _p('p1', lines: [_line(SeatType.doubleSofa, SeatPosition.lower, 1)]);
      final plan = SeatingEngine.propose(
          buses: buses, passengers: [filler1, filler2, p]);

      expect(plan.exceptions, isEmpty);
      // p1 gets one berth on each remaining half-double (cross-fill).
      expect(_seatIds(plan, 'p1'), ['DU1', 'DU2']);
    });
  });

  group('regression: locked-single cross-fill drain (finding 2)', () {
    test(
        'two locked singles already satisfy a doubleSofa(lower) line → no '
        'exception on re-propose', () {
      final buses = [
        _bus('b1', [
          _seat(0, 0, SeatType.singleSofa, SeatPosition.upper, 'SU1'),
          _seat(0, 1, SeatType.singleSofa, SeatPosition.lower, 'SL1'),
        ]),
      ];
      // The agent already locked two single berths to satisfy the double
      // request, then re-runs propose.
      final p = _p('p1',
          lines: [_line(SeatType.doubleSofa, SeatPosition.lower, 1)],
          assigned: [
            SeatAssignment(busId: 'b1', seatId: 'SU1', locked: true),
            SeatAssignment(busId: 'b1', seatId: 'SL1', locked: true),
          ]);
      final plan = SeatingEngine.propose(buses: buses, passengers: [p]);

      expect(plan.exceptions, isEmpty,
          reason: 'locked singles cross-fill the positioned double line');
      // The two locked seats are preserved verbatim, nothing more is added.
      expect(_seatIds(plan, 'p1'), ['SL1', 'SU1']);
      expect(plan.forPassenger('p1').every((a) => a.locked), isTrue);
    });
  });

  group('regression: group anchored by a locked member (findings 3 & 6)', () {
    test('a group with one LOCKED member is never split across buses', () {
      // busA has 3 single-upper sofas; busB has exactly 1. g_a is locked on
      // busA; g_b is pending. busB is "tighter" (1 free berth) so the old
      // engine put g_b there — splitting the group. It must stay on busA.
      final buses = [
        _bus('busA', [
          _seat(0, 0, SeatType.singleSofa, SeatPosition.upper, 'A_s1'),
          _seat(1, 0, SeatType.singleSofa, SeatPosition.upper, 'A_s2'),
          _seat(2, 0, SeatType.singleSofa, SeatPosition.upper, 'A_s3'),
        ]),
        _bus('busB', [
          _seat(0, 0, SeatType.singleSofa, SeatPosition.upper, 'B_s1'),
        ]),
      ];
      final gA = _p('g_a',
          groupId: 'grp',
          lines: [_line(SeatType.singleSofa, SeatPosition.upper, 1)],
          assigned: [
            SeatAssignment(busId: 'busA', seatId: 'A_s1', locked: true)
          ]);
      final gB = _p('g_b',
          groupId: 'grp',
          lines: [_line(SeatType.singleSofa, SeatPosition.upper, 1)]);
      final plan = SeatingEngine.propose(buses: buses, passengers: [gA, gB]);

      final busesA = plan.forPassenger('g_a').map((x) => x.busId).toSet();
      final busesB = plan.forPassenger('g_b').map((x) => x.busId).toSet();
      expect(busesA, {'busA'});
      expect(busesB, {'busA'},
          reason: 'pending member must join the locked member\'s bus');
      expect(busesA, busesB);
    });

    test('reverse variant: locked on b1, pending member with b2 tighter', () {
      // b1 has the locked member + 3 free berths; b2 has 2 free berths
      // (tighter). The pending member must stay on b1 with the locked member.
      final buses = [
        _bus('b1', [
          _seat(0, 0, SeatType.seater, null, 'b1_ST1'),
          _seat(0, 1, SeatType.seater, null, 'b1_ST2'),
          _seat(0, 2, SeatType.seater, null, 'b1_ST3'),
          _seat(0, 3, SeatType.seater, null, 'b1_ST4'),
        ]),
        _bus('b2', [
          _seat(0, 0, SeatType.seater, null, 'b2_ST1'),
          _seat(0, 1, SeatType.seater, null, 'b2_ST2'),
        ]),
      ];
      final a = _p('a',
          groupId: 'g',
          lines: [_line(SeatType.seater, null, 1)],
          assigned: [
            SeatAssignment(busId: 'b1', seatId: 'b1_ST1', locked: true)
          ]);
      final b =
          _p('b', groupId: 'g', lines: [_line(SeatType.seater, null, 1)]);
      final plan = SeatingEngine.propose(buses: buses, passengers: [a, b]);

      expect(plan.forPassenger('a').single.busId, 'b1');
      expect(plan.forPassenger('b').single.busId, 'b1',
          reason: 'group must stay on the anchored bus b1, not split to b2');
    });
  });

  group('regression: group locked across two buses (finding 4)', () {
    test('members pre-locked on different buses raise a cohesion exception',
        () {
      final buses = [
        _bus('busA', [
          _seat(0, 0, SeatType.singleSofa, SeatPosition.upper, 'A_s1'),
        ]),
        _bus('busB', [
          _seat(0, 0, SeatType.singleSofa, SeatPosition.upper, 'B_s1'),
        ]),
      ];
      final gA = _p('g_a',
          groupId: 'grp',
          lines: [_line(SeatType.singleSofa, SeatPosition.upper, 1)],
          assigned: [
            SeatAssignment(busId: 'busA', seatId: 'A_s1', locked: true)
          ]);
      final gB = _p('g_b',
          groupId: 'grp',
          lines: [_line(SeatType.singleSofa, SeatPosition.upper, 1)],
          assigned: [
            SeatAssignment(busId: 'busB', seatId: 'B_s1', locked: true)
          ]);
      final plan = SeatingEngine.propose(buses: buses, passengers: [gA, gB]);

      // Locked seats are preserved, but the split group is surfaced.
      expect(
          plan.exceptions.any((e) =>
              e.type == SeatingExceptionType.brokenPair ||
              e.type == SeatingExceptionType.groupWontFit),
          isTrue,
          reason: 'a group locked across two buses must be flagged');
    });
  });

  group('regression: goal order — priority over group front (finding 5)', () {
    test('an approved-priority individual gets the front seat over a '
        'non-priority group', () {
      // Front rows 0,1; back rows 2,3. All single-upper sofas. A non-priority
      // group {g_a,g_b} and one approved-priority VIP. The VIP must get a
      // front seat; the group yields one front seat to a back row.
      final buses = [
        _bus('b1', [
          _seat(0, 0, SeatType.singleSofa, SeatPosition.upper, 'front_a'),
          _seat(1, 0, SeatType.singleSofa, SeatPosition.upper, 'front_b'),
          _seat(2, 0, SeatType.singleSofa, SeatPosition.upper, 'back_a'),
          _seat(3, 0, SeatType.singleSofa, SeatPosition.upper, 'back_b'),
        ]),
      ];
      final gA = _p('g_a',
          groupId: 'grp',
          lines: [_line(SeatType.singleSofa, null, 1)]);
      final gB = _p('g_b',
          groupId: 'grp',
          lines: [_line(SeatType.singleSofa, null, 1)]);
      final vip = _p('vip',
          priority: PriorityStatus.approved,
          lines: [_line(SeatType.singleSofa, null, 1)]);
      final plan =
          SeatingEngine.propose(buses: buses, passengers: [gA, gB, vip]);

      final vipSeat = plan.forPassenger('vip').single.seatId;
      expect(['front_a', 'front_b'].contains(vipSeat), isTrue,
          reason: 'approved priority (goal 1) outranks group adjacency (goal 2)');
      expect(plan.exceptions
          .any((e) => e.type == SeatingExceptionType.priorityNoFrontSeat),
          isFalse,
          reason: 'VIP actually got a front seat');
      // Group still together on the one bus.
      final groupBuses = {
        ...plan.forPassenger('g_a').map((a) => a.busId),
        ...plan.forPassenger('g_b').map((a) => a.busId),
      };
      expect(groupBuses.length, 1);
    });
  });

  group('regression: half-locked own-cell double completion (finding 7)', () {
    test('a doubleSofa requester holding ONE locked berth completes the SAME '
        'cell, no stranded berth, no over-allocation', () {
      // P2 scenario: two upper doubles. p1 requests one doubleSofa(upper) and
      // already holds ONE locked berth on DU1. The pair must be completed on
      // DU1 (2 entries on DU1), NOT by grabbing the whole DU2.
      final buses = [
        _bus('b1', [
          _seat(0, 0, SeatType.doubleSofa, SeatPosition.upper, 'DU1'),
          _seat(1, 0, SeatType.doubleSofa, SeatPosition.upper, 'DU2'),
        ]),
      ];
      final p = _p('p1',
          lines: [_line(SeatType.doubleSofa, SeatPosition.upper, 1)],
          assigned: [
            SeatAssignment(busId: 'b1', seatId: 'DU1', locked: true)
          ]);
      final plan = SeatingEngine.propose(buses: buses, passengers: [p]);

      expect(plan.exceptions, isEmpty);
      final seats = plan.forPassenger('p1');
      // Exactly two berths, BOTH on DU1 (the locked one + its partner).
      expect(seats.length, 2);
      expect(seats.every((a) => a.seatId == 'DU1'), isTrue,
          reason: 'pair completed on the OWN cell, not reallocated to DU2');
      // DU2 is left wholly free for someone else.
      expect(plan.allAssignments.any((a) => a.seatId == 'DU2'), isFalse);
    });

    test('only cell available: half-locked double completes from its own '
        'partner berth, no seatTypeUnavailable', () {
      // P1 scenario: DU1 is the only sofa. p1 holds one locked berth on DU1 and
      // requests one doubleSofa(upper). The partner berth of DU1 completes the
      // pair — no exception.
      final buses = [
        _bus('b1', [
          _seat(0, 0, SeatType.doubleSofa, SeatPosition.upper, 'DU1'),
        ]),
      ];
      final p = _p('p1',
          lines: [_line(SeatType.doubleSofa, SeatPosition.upper, 1)],
          assigned: [
            SeatAssignment(busId: 'b1', seatId: 'DU1', locked: true)
          ]);
      final plan = SeatingEngine.propose(buses: buses, passengers: [p]);

      expect(plan.exceptions, isEmpty,
          reason: 'the second berth of the own cell completes the pair');
      final seats = plan.forPassenger('p1');
      expect(seats.length, 2);
      expect(seats.every((a) => a.seatId == 'DU1'), isTrue);
    });
  });

  // ── CHANGE 1: leg-aware seat reuse (GO / RETURN slots) ────────────────────

  group('leg-aware seat reuse', () {
    test('outboundOnly + returnOnly share ONE seat — both placed, no overlap',
        () {
      // A single seater cell. One outbound-only and one return-only passenger
      // must BOTH land on it: disjoint legs reuse the same berth.
      final buses = [
        _bus('b1', [_seat(0, 0, SeatType.seater, null, 'ST1')]),
      ];
      final go = _p('go',
          tripType: TripType.outboundOnly,
          lines: [_line(SeatType.seater, null, 1)]);
      final ret = _p('ret',
          tripType: TripType.returnOnly,
          lines: [_line(SeatType.seater, null, 1)]);
      final plan = SeatingEngine.propose(buses: buses, passengers: [go, ret]);

      expect(plan.exceptions, isEmpty,
          reason: 'disjoint legs reuse the same physical berth');
      expect(plan.forPassenger('go').single.seatId, 'ST1');
      expect(plan.forPassenger('ret').single.seatId, 'ST1');
      // Two DIFFERENT passengers on the SAME seat — the desired reuse.
      final onST1 = plan.allAssignments.where((a) => a.seatId == 'ST1');
      expect(onST1.length, 2);

      // The leg-occupancy helper reports exactly one berth per leg, no overlap.
      final occ = plan.legOccupancy([go, ret])['b1:ST1']!;
      expect(occ.go, 1);
      expect(occ.ret, 1);
    });

    test('a returnOnly reuses the RETURN slot of a seat an outboundOnly holds, '
        'on a double sofa (each leg has 2 slots)', () {
      // One doubleSofa (2 berths × 2 legs). Place 2 outbound-only singles and 2
      // return-only singles — all four fit because GO and RETURN are disjoint.
      final buses = [
        _bus('b1', [
          _seat(0, 3, SeatType.doubleSofa, SeatPosition.upper, 'DU1'),
        ]),
      ];
      final g1 = _p('g1',
          tripType: TripType.outboundOnly,
          lines: [_line(SeatType.singleSofa, null, 1)]);
      final g2 = _p('g2',
          tripType: TripType.outboundOnly,
          lines: [_line(SeatType.singleSofa, null, 1)]);
      final r1 = _p('r1',
          tripType: TripType.returnOnly,
          lines: [_line(SeatType.singleSofa, null, 1)]);
      final r2 = _p('r2',
          tripType: TripType.returnOnly,
          lines: [_line(SeatType.singleSofa, null, 1)]);
      final plan = SeatingEngine.propose(
          buses: buses, passengers: [g1, g2, r1, r2]);

      expect(plan.exceptions, isEmpty,
          reason: '2 GO + 2 RETURN all fit the 2 berths via leg reuse');
      for (final id in ['g1', 'g2', 'r1', 'r2']) {
        expect(plan.forPassenger(id).single.seatId, 'DU1');
      }
      final occ = plan.legOccupancy([g1, g2, r1, r2])['b1:DU1']!;
      expect(occ.go, 2, reason: 'both GO berths used by the two outbound-only');
      expect(occ.ret, 2, reason: 'both RETURN berths used by the two return-only');
    });

    test('a roundTrip CANNOT share a berth with anyone (holds both legs)', () {
      // One seater. A round-trip passenger takes it; a second passenger of ANY
      // leg must overflow — the round-trip holds GO and RETURN.
      final buses = [
        _bus('b1', [_seat(0, 0, SeatType.seater, null, 'ST1')]),
      ];
      final rt = _p('a_rt', // sorts before the others
          tripType: TripType.roundTrip,
          lines: [_line(SeatType.seater, null, 1)]);
      final go = _p('b_go',
          tripType: TripType.outboundOnly,
          lines: [_line(SeatType.seater, null, 1)]);
      final ret = _p('c_ret',
          tripType: TripType.returnOnly,
          lines: [_line(SeatType.seater, null, 1)]);
      final plan =
          SeatingEngine.propose(buses: buses, passengers: [rt, go, ret]);

      // Round-trip got the only seat.
      expect(plan.forPassenger('a_rt').single.seatId, 'ST1');
      // Neither one-way passenger can reuse it — both unplaced.
      expect(plan.forPassenger('b_go'), isEmpty);
      expect(plan.forPassenger('c_ret'), isEmpty);
      // Seat holds exactly ONE berth (the round-trip), never overbooked.
      expect(plan.allAssignments.where((a) => a.seatId == 'ST1').length, 1);
      final occ = plan.legOccupancy([rt, go, ret])['b1:ST1']!;
      expect(occ.go, 1);
      expect(occ.ret, 1);
    });

    test('a returnOnly is REFUSED the RETURN slot of a seat whose GO slot is a '
        'roundTrip (the roundTrip holds BOTH legs)', () {
      // One seater. A round-trip takes it (consuming GO and RETURN). A
      // return-only passenger may NOT take the return slot — it is already gone.
      final buses = [
        _bus('b1', [_seat(0, 0, SeatType.seater, null, 'ST1')]),
      ];
      final rt = _p('a_rt',
          tripType: TripType.roundTrip,
          lines: [_line(SeatType.seater, null, 1)]);
      final ret = _p('b_ret',
          tripType: TripType.returnOnly,
          lines: [_line(SeatType.seater, null, 1)]);
      final plan = SeatingEngine.propose(buses: buses, passengers: [rt, ret]);

      expect(plan.forPassenger('a_rt').single.seatId, 'ST1');
      expect(plan.forPassenger('b_ret'), isEmpty,
          reason: 'the roundTrip already holds the RETURN leg of ST1');
      expect(
          plan.exceptions.any((e) =>
              e.type == SeatingExceptionType.overflowWaitlist ||
              e.type == SeatingExceptionType.seatTypeUnavailable),
          isTrue);
    });

    test('two roundTrips cannot share one berth (only one fits)', () {
      final buses = [
        _bus('b1', [_seat(0, 0, SeatType.seater, null, 'ST1')]),
      ];
      final a = _p('a',
          tripType: TripType.roundTrip,
          lines: [_line(SeatType.seater, null, 1)]);
      final b = _p('b',
          tripType: TripType.roundTrip,
          lines: [_line(SeatType.seater, null, 1)]);
      final plan = SeatingEngine.propose(buses: buses, passengers: [a, b]);

      expect(plan.forPassenger('a').single.seatId, 'ST1');
      expect(plan.forPassenger('b'), isEmpty);
      expect(plan.allAssignments.where((a) => a.seatId == 'ST1').length, 1);
    });

    test('roundTrip + outboundOnly cannot share — roundTrip needs RETURN too',
        () {
      // GO is free only if BOTH legs are free for the round-trip. Place an
      // outbound-only first (sorts first), then a round-trip wanting the SAME
      // single seat: the round-trip needs RETURN free too, GO is taken, so it
      // cannot reuse — it overflows.
      final buses = [
        _bus('b1', [_seat(0, 0, SeatType.seater, null, 'ST1')]),
      ];
      final go = _p('a_go',
          tripType: TripType.outboundOnly,
          lines: [_line(SeatType.seater, null, 1)]);
      final rt = _p('b_rt',
          tripType: TripType.roundTrip,
          lines: [_line(SeatType.seater, null, 1)]);
      final plan = SeatingEngine.propose(buses: buses, passengers: [go, rt]);

      expect(plan.forPassenger('a_go').single.seatId, 'ST1');
      expect(plan.forPassenger('b_rt'), isEmpty,
          reason: 'roundTrip needs the GO leg too, which is taken');
    });

    test('whole double held solo by a roundTrip blocks BOTH legs of BOTH berths',
        () {
      // A round-trip taking a whole double consumes go=2 and ret=2 → nothing
      // left for any leg. A separate return-only single must overflow.
      final buses = [
        _bus('b1', [
          _seat(0, 3, SeatType.doubleSofa, SeatPosition.upper, 'DU1'),
        ]),
      ];
      final rt = _p('a_rt',
          tripType: TripType.roundTrip,
          lines: [_line(SeatType.doubleSofa, SeatPosition.upper, 1)]);
      final ret = _p('b_ret',
          tripType: TripType.returnOnly,
          lines: [_line(SeatType.singleSofa, null, 1)]);
      final plan = SeatingEngine.propose(buses: buses, passengers: [rt, ret]);

      // Round-trip holds both berths (2 entries on DU1).
      expect(plan.forPassenger('a_rt').length, 2);
      expect(plan.forPassenger('a_rt').every((x) => x.seatId == 'DU1'), isTrue);
      // No leg free anywhere → return-only overflows.
      expect(plan.forPassenger('b_ret'), isEmpty);
    });

    test('a locked one-way berth still frees the OTHER leg for reuse', () {
      // p_go is LOCKED on ST1 as outbound-only. A fresh return-only passenger
      // re-uses ST1's RETURN slot (locked one-way berth does not block return).
      final buses = [
        _bus('b1', [_seat(0, 0, SeatType.seater, null, 'ST1')]),
      ];
      final goLocked = _p('go',
          tripType: TripType.outboundOnly,
          lines: [_line(SeatType.seater, null, 1)],
          assigned: [SeatAssignment(busId: 'b1', seatId: 'ST1', locked: true)]);
      final ret = _p('ret',
          tripType: TripType.returnOnly,
          lines: [_line(SeatType.seater, null, 1)]);
      final plan =
          SeatingEngine.propose(buses: buses, passengers: [goLocked, ret]);

      expect(plan.exceptions, isEmpty);
      // Locked GO berth preserved.
      final goSeats = plan.forPassenger('go');
      expect(goSeats.single.seatId, 'ST1');
      expect(goSeats.single.locked, isTrue);
      // Return-only reused the RETURN slot of the same seat.
      expect(plan.forPassenger('ret').single.seatId, 'ST1');
      final occ = plan.legOccupancy([goLocked, ret])['b1:ST1']!;
      expect(occ.go, 1);
      expect(occ.ret, 1);
    });
  });

  // ── CHANGE 2: fill — no compatible seat left empty while waitlisting ──────

  group('fill completeness', () {
    test('no passenger is waitlisted while a compatible berth-leg is free', () {
      // 20 buses, 1 seater each = 20 GO + 20 RETURN seater slots. Mix of trip
      // types whose total seater demand fits via leg reuse → ZERO overflow.
      final buses = [
        for (var i = 0; i < 20; i++)
          _bus('bus${i.toString().padLeft(2, '0')}',
              [_seat(0, 0, SeatType.seater, null, 'ST')]),
      ];
      // 20 round-trips fill every both-legs slot; then 0 free. Instead use a mix
      // that exercises reuse: 20 outbound-only + 20 return-only = 40 pax, all fit
      // by GO/RETURN reuse on the same 20 seats.
      final pax = <Passenger>[
        for (var i = 0; i < 20; i++)
          _p('g${i.toString().padLeft(2, '0')}',
              tripType: TripType.outboundOnly,
              lines: [_line(SeatType.seater, null, 1)]),
        for (var i = 0; i < 20; i++)
          _p('r${i.toString().padLeft(2, '0')}',
              tripType: TripType.returnOnly,
              lines: [_line(SeatType.seater, null, 1)]),
      ];
      final plan = SeatingEngine.propose(buses: buses, passengers: pax);

      expect(plan.exceptions, isEmpty,
          reason: '40 one-way pax fit 20 seats via leg reuse — none waitlisted');
      // Every passenger placed exactly once.
      for (final p in pax) {
        expect(plan.forPassenger(p.id).length, 1);
      }
      // No seat overbooked on a single leg: each seat is go<=1, ret<=1.
      final occ = plan.legOccupancy(pax);
      for (final o in occ.values) {
        expect(o.go, lessThanOrEqualTo(1));
        expect(o.ret, lessThanOrEqualTo(1));
      }
    });

    test('a passenger is NOT waitlisted while a compatible seat sits empty on '
        'another bus (balance heuristic must not strand fill)', () {
      // Two buses. The first is fuller (a locked occupant), the second has a
      // free compatible seater. A new passenger must land on bus2, never
      // waitlisted while bus2 holds a compatible empty seat.
      final buses = [
        _bus('b1', [_seat(0, 0, SeatType.seater, null, 'b1_ST1')]),
        _bus('b2', [_seat(0, 0, SeatType.seater, null, 'b2_ST1')]),
      ];
      final filler = _p('a_filler',
          lines: [_line(SeatType.seater, null, 1)],
          assigned: [
            SeatAssignment(busId: 'b1', seatId: 'b1_ST1', locked: true)
          ]);
      final p = _p('b_p', lines: [_line(SeatType.seater, null, 1)]);
      final plan = SeatingEngine.propose(buses: buses, passengers: [filler, p]);

      expect(plan.exceptions, isEmpty,
          reason: 'a compatible seat was free on b2 — must be filled');
      expect(plan.forPassenger('b_p').single.seatId, 'b2_ST1');
    });

    test('overflow fires ONLY when no compatible berth-leg remains anywhere',
        () {
      // One seater, two round-trips. The first fills both legs; the second has
      // genuinely no compatible berth-leg → overflowWaitlist (correct).
      final buses = [
        _bus('b1', [_seat(0, 0, SeatType.seater, null, 'ST1')]),
      ];
      final a = _p('a', lines: [_line(SeatType.seater, null, 1)]);
      final b = _p('b', lines: [_line(SeatType.seater, null, 1)]);
      final plan = SeatingEngine.propose(buses: buses, passengers: [a, b]);

      expect(plan.forPassenger('a').single.seatId, 'ST1');
      expect(plan.forPassenger('b'), isEmpty);
      expect(
          plan.exceptions
              .any((e) => e.type == SeatingExceptionType.overflowWaitlist),
          isTrue,
          reason: 'genuinely no compatible capacity → overflow is correct');
    });

    test('mixed types across many buses: leg reuse seats everyone, no empty '
        'compatible berth-leg while anyone waitlists', () {
      // 3 buses, each with 1 single-upper sofa = 3 GO + 3 RETURN slots. Demand:
      // 3 outbound-only + 3 return-only single-upper requests. Every GO slot
      // pairs with a RETURN slot on the SAME seat via leg reuse → all 6 placed,
      // zero overflow, no compatible berth-leg left empty.
      final buses = [
        for (var i = 0; i < 3; i++)
          _bus('b$i',
              [_seat(0, 0, SeatType.singleSofa, SeatPosition.upper, 'b${i}_S')]),
      ];
      final pax = <Passenger>[
        for (var i = 0; i < 3; i++)
          _p('go$i',
              tripType: TripType.outboundOnly,
              lines: [_line(SeatType.singleSofa, SeatPosition.upper, 1)]),
        for (var i = 0; i < 3; i++)
          _p('rt_ret$i',
              tripType: TripType.returnOnly,
              lines: [_line(SeatType.singleSofa, SeatPosition.upper, 1)]),
      ];
      final plan = SeatingEngine.propose(buses: buses, passengers: pax);

      expect(plan.exceptions, isEmpty,
          reason: 'leg reuse seats every one-way passenger');
      for (final p in pax) {
        expect(plan.forPassenger(p.id).length, 1);
      }
      // All 3 seats used; each holds exactly one GO and one RETURN berth.
      final occ = plan.legOccupancy(pax);
      expect(occ.length, 3);
      for (final o in occ.values) {
        expect(o.go, 1);
        expect(o.ret, 1);
      }
    });
  });

  group('leg-aware determinism', () {
    test('propose twice with mixed trip types yields identical output', () {
      List<Bus> mk() => [
            _bus('b1', [
              _seat(0, 0, SeatType.seater, null, 'b1_ST1'),
              _seat(0, 1, SeatType.singleSofa, SeatPosition.upper, 'b1_SU1'),
              _seat(1, 3, SeatType.doubleSofa, SeatPosition.lower, 'b1_DL1'),
            ]),
            _bus('b2', [
              _seat(0, 0, SeatType.seater, null, 'b2_ST1'),
              _seat(0, 1, SeatType.singleSofa, SeatPosition.upper, 'b2_SU1'),
            ]),
          ];
      List<Passenger> mkPax() => [
            _p('go1',
                tripType: TripType.outboundOnly,
                lines: [_line(SeatType.seater, null, 1)]),
            _p('ret1',
                tripType: TripType.returnOnly,
                lines: [_line(SeatType.seater, null, 1)]),
            _p('rt1',
                tripType: TripType.roundTrip,
                lines: [_line(SeatType.singleSofa, SeatPosition.upper, 1)]),
            _p('go2',
                tripType: TripType.outboundOnly,
                lines: [_line(SeatType.singleSofa, SeatPosition.upper, 1)]),
            _p('rt2',
                tripType: TripType.roundTrip,
                lines: [_line(SeatType.doubleSofa, SeatPosition.lower, 1)]),
          ];

      String repr(SeatingPlan p) {
        final keys = p.assignmentsByPassenger.keys.toList()..sort();
        final lines = [
          for (final k in keys)
            '$k=${(p.forPassenger(k).map((a) => '${a.busId}:${a.seatId}:${a.locked}').toList()..sort()).join(",")}'
        ];
        final exc = p.exceptions.map((e) => e.toString()).toList()..sort();
        return '${lines.join("|")}#${exc.join("|")}';
      }

      final plan1 = SeatingEngine.propose(buses: mk(), passengers: mkPax());
      final plan2 = SeatingEngine.propose(buses: mk(), passengers: mkPax());
      expect(repr(plan1), repr(plan2));
    });

    test('caller list order does not change leg-aware reuse outcome', () {
      final buses = [
        _bus('b1', [_seat(0, 0, SeatType.seater, null, 'ST1')]),
      ];
      final go = _p('go',
          tripType: TripType.outboundOnly,
          lines: [_line(SeatType.seater, null, 1)]);
      final ret = _p('ret',
          tripType: TripType.returnOnly,
          lines: [_line(SeatType.seater, null, 1)]);

      final p1 = SeatingEngine.propose(buses: buses, passengers: [go, ret]);
      final p2 = SeatingEngine.propose(buses: buses, passengers: [ret, go]);

      expect(_seatIds(p1, 'go'), _seatIds(p2, 'go'));
      expect(_seatIds(p1, 'ret'), _seatIds(p2, 'ret'));
      expect(p1.forPassenger('go').single.seatId, 'ST1');
      expect(p1.forPassenger('ret').single.seatId, 'ST1');
    });
  });
}
