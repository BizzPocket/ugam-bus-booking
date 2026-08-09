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
      // The leg now lives PER REQUEST LINE. These tests express a passenger's
      // travel leg via [tripType]; relocate it onto each line that did not set
      // its own leg, so the per-line engine sees the same intent.
      requestLines: [
        for (final l in lines)
          l.leg == TripType.roundTrip && tripType != TripType.roundTrip
              ? l.copyWith(leg: tripType)
              : l,
      ],
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

  group('shared double sofa — stranger-share rule', () {
    test('two UNRELATED singles + only a double free → first takes a berth, '
        'second is NOT auto-paired but raises sharedDoubleNeedsReview', () {
      // The only sofa seating is ONE double cell (2 berths). Two UNRELATED
      // passengers each request a single sofa. The first takes an EMPTY berth
      // (no pairing created). The second can ONLY be seated by sharing with a
      // stranger — the engine refuses and raises sharedDoubleNeedsReview.
      final buses = [
        _bus('b1', [
          _seat(0, 3, SeatType.doubleSofa, SeatPosition.upper, 'DU1'),
        ]),
      ];
      final a = _p('a', lines: [_line(SeatType.singleSofa, null, 1)]);
      final b = _p('b', lines: [_line(SeatType.singleSofa, null, 1)]);
      final plan = SeatingEngine.propose(buses: buses, passengers: [a, b]);

      // 'a' (sorts first) takes one berth of the empty double — allowed.
      expect(plan.forPassenger('a').single.seatId, 'DU1');
      // 'b' is NOT auto-paired onto the stranger's sofa.
      expect(plan.forPassenger('b'), isEmpty);
      // Only ONE berth is occupied on DU1 — no silent stranger pairing.
      expect(plan.allAssignments.where((x) => x.seatId == 'DU1').length, 1);
      // The agent must broker the pairing.
      final ex = plan.exceptions
          .where((e) => e.type == SeatingExceptionType.sharedDoubleNeedsReview)
          .toList();
      expect(ex.length, 1);
      expect(ex.single.passengerId, 'b');
      expect(ex.single.message.toLowerCase().contains('double sofa'), isTrue);
    });

    test('two SAME-GROUP singles + a double → they DO auto-share, no exception',
        () {
      // Same scenario but both passengers share a non-null groupId. A group is
      // agent-tagged related, so they may auto-share the double sofa.
      final buses = [
        _bus('b1', [
          _seat(0, 3, SeatType.doubleSofa, SeatPosition.upper, 'DU1'),
        ]),
      ];
      final a =
          _p('a', groupId: 'fam', lines: [_line(SeatType.singleSofa, null, 1)]);
      final b =
          _p('b', groupId: 'fam', lines: [_line(SeatType.singleSofa, null, 1)]);
      final plan = SeatingEngine.propose(buses: buses, passengers: [a, b]);

      expect(plan.exceptions, isEmpty,
          reason: 'same-group members are known-related — auto-share allowed');
      expect(plan.forPassenger('a').single.seatId, 'DU1');
      expect(plan.forPassenger('b').single.seatId, 'DU1');
      // Two berths of the SAME cell held by two SAME-GROUP passengers.
      expect(plan.allAssignments.where((x) => x.seatId == 'DU1').length, 2);
    });

    test('a single on an EMPTY double berth is allowed (no pairing, no exception)',
        () {
      // One passenger, one double cell. Taking one berth of an empty double
      // creates no pairing → no review needed.
      final buses = [
        _bus('b1', [
          _seat(0, 3, SeatType.doubleSofa, SeatPosition.upper, 'DU1'),
        ]),
      ];
      final a = _p('a', lines: [_line(SeatType.singleSofa, null, 1)]);
      final plan = SeatingEngine.propose(buses: buses, passengers: [a]);

      expect(plan.exceptions, isEmpty);
      expect(plan.forPassenger('a').single.seatId, 'DU1');
      expect(plan.allAssignments.where((x) => x.seatId == 'DU1').length, 1);
    });

    test('an EMPTY single sofa is preferred over sharing a stranger\'s double',
        () {
      // A free single sofa AND a double whose other berth is held by a stranger.
      // The new single must land on the free single, never share the double.
      final buses = [
        _bus('b1', [
          _seat(0, 0, SeatType.singleSofa, SeatPosition.upper, 'S1'),
          _seat(0, 3, SeatType.doubleSofa, SeatPosition.upper, 'DU1'),
        ]),
      ];
      // 'a' is locked onto one berth of DU1 (an existing stranger occupant).
      final a = _p('a',
          lines: [_line(SeatType.singleSofa, null, 1)],
          assigned: [SeatAssignment(busId: 'b1', seatId: 'DU1', locked: true)]);
      final b = _p('b', lines: [_line(SeatType.singleSofa, null, 1)]);
      final plan = SeatingEngine.propose(buses: buses, passengers: [a, b]);

      expect(plan.exceptions, isEmpty);
      expect(plan.forPassenger('b').single.seatId, 'S1',
          reason: 'an empty single beats sharing a stranger double');
      // DU1 still holds only the locked stranger berth.
      expect(plan.allAssignments.where((x) => x.seatId == 'DU1').length, 1);
    });

    test('cross-fill is refused when the only second berth would be a stranger '
        'double → sharedDoubleNeedsReview', () {
      // One free single 'S1' plus a double 'DU1' whose other berth a stranger
      // holds. A doubleSofa requester would need S1 + a DU1 berth via cross-fill,
      // but the DU1 berth would pair strangers → review, no silent placement.
      final buses = [
        _bus('b1', [
          _seat(0, 0, SeatType.singleSofa, SeatPosition.upper, 'S1'),
          _seat(0, 3, SeatType.doubleSofa, SeatPosition.upper, 'DU1'),
        ]),
      ];
      final stranger = _p('stranger',
          lines: [_line(SeatType.singleSofa, null, 1)],
          assigned: [SeatAssignment(busId: 'b1', seatId: 'DU1', locked: true)]);
      final dbl =
          _p('z_dbl', lines: [_line(SeatType.doubleSofa, null, 1)]);
      final plan =
          SeatingEngine.propose(buses: buses, passengers: [stranger, dbl]);

      // The double requester is not seated by stranger-pairing.
      expect(
          plan.exceptions.any(
              (e) => e.type == SeatingExceptionType.sharedDoubleNeedsReview),
          isTrue);
      // DU1 still holds only the stranger's one berth.
      expect(plan.allAssignments.where((x) => x.seatId == 'DU1').length, 1);
    });

    test('determinism: the stranger-share outcome is reproducible', () {
      List<Bus> mk() => [
            _bus('b1', [
              _seat(0, 3, SeatType.doubleSofa, SeatPosition.upper, 'DU1'),
              _seat(1, 3, SeatType.doubleSofa, SeatPosition.lower, 'DL1'),
            ]),
          ];
      List<Passenger> mkPax() => [
            _p('a', lines: [_line(SeatType.singleSofa, null, 1)]),
            _p('b', lines: [_line(SeatType.singleSofa, null, 1)]),
            _p('c', lines: [_line(SeatType.singleSofa, null, 1)]),
          ];

      String repr(SeatingPlan p) {
        final keys = p.assignmentsByPassenger.keys.toList()..sort();
        final lines = [
          for (final k in keys)
            '$k=${(p.forPassenger(k).map((a) => '${a.busId}:${a.seatId}').toList()..sort()).join(",")}'
        ];
        final exc = p.exceptions.map((e) => e.toString()).toList()..sort();
        return '${lines.join("|")}#${exc.join("|")}';
      }

      final plan1 = SeatingEngine.propose(buses: mk(), passengers: mkPax());
      final plan2 = SeatingEngine.propose(buses: mk(), passengers: mkPax());
      expect(repr(plan1), repr(plan2));

      // With two empty doubles, a + b each get an EMPTY berth (different cells);
      // c then would have to stranger-share → review.
      expect(plan1.forPassenger('a').single.seatId, 'DU1');
      expect(plan1.forPassenger('b').single.seatId, 'DL1');
      expect(plan1.forPassenger('c'), isEmpty);
      expect(
          plan1.exceptions
              .any((e) => e.type == SeatingExceptionType.sharedDoubleNeedsReview),
          isTrue,
          reason: 'third single must stranger-share one of the two doubles');
    });
  });

  group('shared double sofa — stranger-share rule for GROUPED members', () {
    // Parity with the UNGROUPED stranger-share rule above: a grouped member
    // whose ONLY possible seat is a stranger-shared double must surface as
    // sharedDoubleNeedsReview (so the agent brokers the pairing), NOT a
    // misleading groupWontFit that hides the brokerable berth. Mirrors PROBE
    // AB/AD/AE. Safety in every case: the stranger double keeps exactly its one
    // existing berth — no auto-pairing.

    test(
        'a 1-member group whose only seat is a stranger double → '
        'sharedDoubleNeedsReview (not groupWontFit), no auto-pairing', () {
      // DU1 is locked by a famA member. z_req is in a DIFFERENT group famB, so
      // it is processed as a group-of-one. Its only seat is the free berth of
      // DU1 — but pairing famB with famA is a stranger-share → review.
      final buses = [
        _bus('b1', [
          _seat(0, 3, SeatType.doubleSofa, SeatPosition.upper, 'DU1'),
        ]),
      ];
      final a = _p('a',
          groupId: 'famA',
          assigned: [SeatAssignment(busId: 'b1', seatId: 'DU1', locked: true)]);
      final zReq = _p('z_req',
          groupId: 'famB', lines: [_line(SeatType.singleSofa, null, 1)]);
      final plan = SeatingEngine.propose(buses: buses, passengers: [a, zReq]);

      // The brokerable berth is surfaced as a review, not hidden as groupWontFit.
      final review = plan.exceptions
          .where((e) => e.type == SeatingExceptionType.sharedDoubleNeedsReview)
          .toList();
      expect(review.length, 1);
      expect(review.single.passengerId, 'z_req');
      expect(review.single.groupId, 'famB');
      expect(
          plan.exceptions
              .any((e) => e.type == SeatingExceptionType.groupWontFit),
          isFalse,
          reason: 'the bus HAS a berth — this is a brokerable pairing, not a '
              'capacity shortage');
      // z_req is NOT seated; DU1 still holds exactly the one famA berth.
      expect(plan.forPassenger('z_req'), isEmpty);
      expect(plan.allAssignments.where((x) => x.seatId == 'DU1').length, 1);
    });

    test(
        'GROUPED vs UNGROUPED parity: the SAME passenger made ungrouped also '
        'yields sharedDoubleNeedsReview', () {
      // Identical fixture, z_req with NO group → already-correct ungrouped path.
      // The grouped test above must reach the same exception type.
      final buses = [
        _bus('b1', [
          _seat(0, 3, SeatType.doubleSofa, SeatPosition.upper, 'DU1'),
        ]),
      ];
      final a = _p('a',
          assigned: [SeatAssignment(busId: 'b1', seatId: 'DU1', locked: true)]);
      final zReq = _p('z_req', lines: [_line(SeatType.singleSofa, null, 1)]);
      final plan = SeatingEngine.propose(buses: buses, passengers: [a, zReq]);

      expect(
          plan.exceptions.any(
              (e) => e.type == SeatingExceptionType.sharedDoubleNeedsReview),
          isTrue);
      expect(plan.allAssignments.where((x) => x.seatId == 'DU1').length, 1);
    });

    test(
        'a 2-member famB group against two famA-locked doubles (one free berth '
        'each) → sharedDoubleNeedsReview per blocked member, not groupWontFit',
        () {
      // DU1 + DU2 each have one berth locked by a famA member. A famB group of
      // two single-sofa requesters can ONLY be seated by stranger-sharing one
      // of those doubles each → review for the famB members, no auto-pairing.
      final buses = [
        _bus('b1', [
          _seat(0, 3, SeatType.doubleSofa, SeatPosition.upper, 'DU1'),
          _seat(1, 3, SeatType.doubleSofa, SeatPosition.lower, 'DU2'),
        ]),
      ];
      final a1 = _p('a1',
          groupId: 'famA',
          assigned: [SeatAssignment(busId: 'b1', seatId: 'DU1', locked: true)]);
      final a2 = _p('a2',
          groupId: 'famA',
          assigned: [SeatAssignment(busId: 'b1', seatId: 'DU2', locked: true)]);
      final b1 = _p('z_b1',
          groupId: 'famB', lines: [_line(SeatType.singleSofa, null, 1)]);
      final b2 = _p('z_b2',
          groupId: 'famB', lines: [_line(SeatType.singleSofa, null, 1)]);
      final plan =
          SeatingEngine.propose(buses: buses, passengers: [a1, a2, b1, b2]);

      final review = plan.exceptions
          .where((e) => e.type == SeatingExceptionType.sharedDoubleNeedsReview)
          .toList();
      // Both famB members are blocked by a stranger-double → both surfaced.
      expect(review.map((e) => e.passengerId).toSet(), {'z_b1', 'z_b2'});
      expect(review.every((e) => e.groupId == 'famB'), isTrue);
      expect(
          plan.exceptions
              .any((e) => e.type == SeatingExceptionType.groupWontFit),
          isFalse);
      // Neither famB member is seated; each double keeps exactly its famA berth.
      expect(plan.forPassenger('z_b1'), isEmpty);
      expect(plan.forPassenger('z_b2'), isEmpty);
      expect(plan.allAssignments.where((x) => x.seatId == 'DU1').length, 1);
      expect(plan.allAssignments.where((x) => x.seatId == 'DU2').length, 1);
    });

    test(
        'same-group members STILL auto-share a partly-locked double — no review',
        () {
      // The fix must not over-fire: a famB requester whose only seat is a double
      // whose other berth is held by ITS OWN group is known-related → it auto-
      // shares, no exception.
      final buses = [
        _bus('b1', [
          _seat(0, 3, SeatType.doubleSofa, SeatPosition.upper, 'DU1'),
        ]),
      ];
      final a = _p('a',
          groupId: 'famB',
          assigned: [SeatAssignment(busId: 'b1', seatId: 'DU1', locked: true)]);
      final zReq = _p('z_req',
          groupId: 'famB', lines: [_line(SeatType.singleSofa, null, 1)]);
      final plan = SeatingEngine.propose(buses: buses, passengers: [a, zReq]);

      expect(plan.exceptions, isEmpty,
          reason: 'same-group members are known-related — auto-share allowed');
      expect(plan.forPassenger('z_req').single.seatId, 'DU1');
      expect(plan.allAssignments.where((x) => x.seatId == 'DU1').length, 2);
    });

    test(
        'a genuine capacity shortage for a group still raises groupWontFit '
        '(no false stranger-share review)', () {
      // No stranger double anywhere; the group simply needs more seaters than
      // any one bus has. Must remain groupWontFit, never sharedDoubleNeedsReview.
      final buses = [
        _bus('b1', [_seat(0, 0, SeatType.seater, null, 'ST1')]),
        _bus('b2', [_seat(0, 0, SeatType.seater, null, 'ST1')]),
      ];
      final a = _p('a', groupId: 'g1', lines: [_line(SeatType.seater, null, 1)]);
      final b = _p('b', groupId: 'g1', lines: [_line(SeatType.seater, null, 1)]);
      final plan = SeatingEngine.propose(buses: buses, passengers: [a, b]);

      expect(
          plan.exceptions
              .any((e) => e.type == SeatingExceptionType.groupWontFit),
          isTrue);
      expect(
          plan.exceptions.any(
              (e) => e.type == SeatingExceptionType.sharedDoubleNeedsReview),
          isFalse);
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
    test('approved priority is seated on a LOWER berth', () {
      // One row carries an upper + a lower single sofa; a back row has another
      // upper. The VIP (no position preference) must take the LOWER berth.
      final buses = [
        _bus('b1', [
          _seat(0, 0, SeatType.singleSofa, SeatPosition.upper, 'SU_upper'),
          _seat(0, 1, SeatType.singleSofa, SeatPosition.lower, 'SL_lower'),
          _seat(1, 0, SeatType.singleSofa, SeatPosition.upper, 'SU_back'),
        ]),
      ];
      final vip = _p('vip',
          priority: PriorityStatus.approved,
          lines: [_line(SeatType.singleSofa, null, 1)]);
      final plan = SeatingEngine.propose(buses: buses, passengers: [vip]);

      expect(plan.exceptions, isEmpty);
      expect(plan.forPassenger('vip').single.seatId, 'SL_lower',
          reason: 'approved priority should take the lower berth');
    });

    test('priority seated but no lower berth → priorityNoLowerBerth exception',
        () {
      // The only sofa is an UPPER berth.
      final buses = [
        _bus('b1', [
          _seat(0, 0, SeatType.singleSofa, SeatPosition.upper, 'SU_upper'),
        ]),
      ];
      final vip = _p('vip',
          priority: PriorityStatus.approved,
          lines: [_line(SeatType.singleSofa, null, 1)]);
      final plan = SeatingEngine.propose(buses: buses, passengers: [vip]);

      // They DID get a seat (no overflow), but it isn't a lower berth.
      expect(plan.forPassenger('vip').single.seatId, 'SU_upper');
      expect(
          plan.exceptions.any(
              (e) => e.type == SeatingExceptionType.priorityNoLowerBerth),
          isTrue);
    });

    test('priority is spread across buses, not stacked on one', () {
      // Two buses, each with exactly one LOWER berth. Two approved-priority
      // passengers must land on different buses (each on the lower berth).
      final buses = [
        _bus('b1', [
          _seat(0, 0, SeatType.singleSofa, SeatPosition.upper, 'b1_upper'),
          _seat(0, 1, SeatType.singleSofa, SeatPosition.lower, 'b1_lower'),
        ]),
        _bus('b2', [
          _seat(0, 0, SeatType.singleSofa, SeatPosition.upper, 'b2_upper'),
          _seat(0, 1, SeatType.singleSofa, SeatPosition.lower, 'b2_lower'),
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
      // And each got the LOWER berth of its bus.
      expect(b1.seatId.endsWith('lower'), isTrue);
      expect(b2.seatId.endsWith('lower'), isTrue);
    });
  });

  group('lower-berth priority preference', () {
    test('a lower berth on a back row wins over an upper berth on the front row',
        () {
      // Row 0 carries only an UPPER berth; the LOWER berth sits on row 3.
      // Approved priority ignores the row index entirely and takes the lower
      // berth — proving the rule is "lower berth", not "forward row".
      final buses = [
        _bus('b1', [
          _seat(0, 0, SeatType.singleSofa, SeatPosition.upper, 'row0_upper'),
          _seat(3, 1, SeatType.singleSofa, SeatPosition.lower, 'row3_lower'),
        ]),
      ];
      final vip = _p('vip',
          priority: PriorityStatus.approved,
          lines: [_line(SeatType.singleSofa, null, 1)]);
      final plan = SeatingEngine.propose(buses: buses, passengers: [vip]);

      expect(plan.exceptions, isEmpty);
      expect(plan.forPassenger('vip').single.seatId, 'row3_lower',
          reason: 'priority follows the lower berth, not the row index');
      // The placement reason names it the lower berth.
      final r = plan.reasons.singleWhere((r) => r.seatId == 'row3_lower');
      expect(r.reason.contains('lower berth'), isTrue);
    });

    test('a non-priority passenger is kept off the lower berth for the '
        'priority one', () {
      // One lower, one upper. A normal passenger sorts first but must yield the
      // lower berth to the approved VIP and take the upper.
      final buses = [
        _bus('b1', [
          _seat(0, 0, SeatType.singleSofa, SeatPosition.upper, 'upper'),
          _seat(0, 1, SeatType.singleSofa, SeatPosition.lower, 'lower'),
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
      expect(plan.forPassenger('vip').single.seatId, 'lower');
      expect(plan.forPassenger('normal').single.seatId, 'upper');
    });

    test('priority with only an UPPER berth free still raises '
        'priorityNoLowerBerth', () {
      // A lower berth exists but is RESERVED, so the only seat the VIP can take
      // is an upper berth → priorityNoLowerBerth.
      final buses = [
        _bus('b1', [
          _seat(0, 0, SeatType.singleSofa, SeatPosition.upper, 'upper'),
          _seat(0, 1, SeatType.singleSofa, SeatPosition.lower, 'lower_reserved',
              reserved: true),
        ]),
      ];
      final vip = _p('vip',
          priority: PriorityStatus.approved,
          lines: [_line(SeatType.singleSofa, null, 1)]);
      final plan = SeatingEngine.propose(buses: buses, passengers: [vip]);

      // The VIP gets the only free seat (the upper one)...
      expect(plan.forPassenger('vip').single.seatId, 'upper');
      // ...but a lower berth was never available → exception fires.
      expect(
          plan.exceptions
              .any((e) => e.type == SeatingExceptionType.priorityNoLowerBerth),
          isTrue);
    });

    test('a reserved lower berth is never filled (reserved wins)', () {
      // The lower berth is reserved; it must stay empty, and the VIP takes the
      // only other (upper) seat instead.
      final buses = [
        _bus('b1', [
          _seat(0, 0, SeatType.singleSofa, SeatPosition.upper, 'open_upper'),
          _seat(0, 1, SeatType.singleSofa, SeatPosition.lower, 'lower_reserved',
              reserved: true),
        ]),
      ];
      final vip = _p('vip',
          priority: PriorityStatus.approved,
          lines: [_line(SeatType.singleSofa, null, 1)]);
      final plan = SeatingEngine.propose(buses: buses, passengers: [vip]);

      // The reserved lower berth is never auto-filled by anyone.
      expect(plan.allAssignments.any((a) => a.seatId == 'lower_reserved'),
          isFalse);
      expect(plan.forPassenger('vip').single.seatId, 'open_upper');
    });

    test('priority single line takes a LOWER double over an UPPER single '
        '(lower preference spans the type-substitution fallback)', () {
      // b1 has an UPPER single sofa 'upperS' and a LOWER double sofa 'lowerD'. A
      // single approved-priority individual requests one singleSofa. The VIP must
      // land on a berth of the lower double, NOT on the upper single — and no
      // priorityNoLowerBerth may fire.
      final buses = [
        _bus('b1', [
          _seat(0, 0, SeatType.singleSofa, SeatPosition.upper, 'upperS'),
          _seat(1, 4, SeatType.doubleSofa, SeatPosition.lower, 'lowerD'),
        ]),
      ];
      final vip = _p('vip',
          priority: PriorityStatus.approved,
          lines: [_line(SeatType.singleSofa, null, 1)]);
      final plan = SeatingEngine.propose(buses: buses, passengers: [vip]);

      expect(plan.forPassenger('vip').single.seatId, 'lowerD',
          reason: 'lower preference must reach the half-double substitute');
      expect(
          plan.exceptions
              .any((e) => e.type == SeatingExceptionType.priorityNoLowerBerth),
          isFalse,
          reason: 'a lower berth WAS available via type substitution');
      // 'upperS' must be left free.
      expect(plan.allAssignments.any((a) => a.seatId == 'upperS'), isFalse);
    });

    test('priority double line cross-fills two LOWER singles over an UPPER '
        'whole double', () {
      // b1 has an UPPER whole double 'upperD' and TWO LOWER singles
      // 'lowerS1'/'lowerS2'. VIP requests one doubleSofa. The VIP must cross-fill
      // the two lower singles, NOT grab the upper double.
      final buses = [
        _bus('b1', [
          _seat(0, 3, SeatType.doubleSofa, SeatPosition.upper, 'upperD'),
          _seat(1, 0, SeatType.singleSofa, SeatPosition.lower, 'lowerS1'),
          _seat(1, 1, SeatType.singleSofa, SeatPosition.lower, 'lowerS2'),
        ]),
      ];
      final vip = _p('vip',
          priority: PriorityStatus.approved,
          lines: [_line(SeatType.doubleSofa, null, 1)]);
      final plan = SeatingEngine.propose(buses: buses, passengers: [vip]);

      expect(_seatIds(plan, 'vip'), ['lowerS1', 'lowerS2'],
          reason: 'lower cross-fill singles win over an upper double');
      expect(
          plan.exceptions
              .any((e) => e.type == SeatingExceptionType.priorityNoLowerBerth),
          isFalse);
      // 'upperD' must be left wholly free.
      expect(plan.allAssignments.any((a) => a.seatId == 'upperD'), isFalse);
    });

    test('determinism: identical input with lower berths is reproducible', () {
      List<Bus> mkBuses() => [
            _bus('b1', [
              _seat(0, 0, SeatType.singleSofa, SeatPosition.upper, 'b1_u'),
              _seat(1, 0, SeatType.singleSofa, SeatPosition.lower, 'b1_l1'),
              _seat(1, 1, SeatType.singleSofa, SeatPosition.lower, 'b1_l2'),
            ]),
            _bus('b2', [
              _seat(2, 4, SeatType.doubleSofa, SeatPosition.lower, 'b2_l'),
              _seat(0, 0, SeatType.singleSofa, SeatPosition.upper, 'b2_u'),
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
      // gets the lower berth over an approved one.
      final buses = [
        _bus('b1', [
          _seat(0, 0, SeatType.singleSofa, SeatPosition.upper, 'upper'),
          _seat(0, 1, SeatType.singleSofa, SeatPosition.lower, 'lower'),
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
      // VIP (approved) must get the lower berth even though 'normal' sorts first.
      expect(plan.forPassenger('vip').single.seatId, 'lower');
      expect(plan.forPassenger('normal').single.seatId, 'upper');
    });

    test('requested-but-not-approved priority gets NO lower-berth preference',
        () {
      final buses = [
        _bus('b1', [
          _seat(0, 0, SeatType.singleSofa, SeatPosition.upper, 'upper'),
          _seat(0, 1, SeatType.singleSofa, SeatPosition.lower, 'lower'),
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

      expect(plan.forPassenger('b').single.seatId, 'lower');
      expect(plan.forPassenger('a').single.seatId, 'upper');
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

    test('a doubleSofa(lower) line cross-fills two UPPER half-doubles '
        '(SAME-GROUP fillers — known-related so the share is allowed)', () {
      // Two separate double cells, both upper, each contributing one berth.
      // Single berths from doubles must satisfy a positioned double line. The
      // half-double partners (f1, f2) and p1 share one group, so completing
      // each cell pairs known-related passengers — no stranger-share review.
      final buses = [
        _bus('b1', [
          _seat(0, 0, SeatType.doubleSofa, SeatPosition.upper, 'DU1'),
          _seat(0, 2, SeatType.doubleSofa, SeatPosition.upper, 'DU2'),
        ]),
      ];
      // Pre-occupy one berth of each double so neither is a WHOLE double, only
      // a half-double each is free → cross-fill must pair them.
      final filler1 = _p('f1',
          groupId: 'grp',
          lines: [_line(SeatType.singleSofa, null, 1)],
          assigned: [SeatAssignment(busId: 'b1', seatId: 'DU1', locked: true)]);
      final filler2 = _p('f2',
          groupId: 'grp',
          lines: [_line(SeatType.singleSofa, null, 1)],
          assigned: [SeatAssignment(busId: 'b1', seatId: 'DU2', locked: true)]);
      final p = _p('p1',
          groupId: 'grp',
          lines: [_line(SeatType.doubleSofa, SeatPosition.lower, 1)]);
      final plan = SeatingEngine.propose(
          buses: buses, passengers: [filler1, filler2, p]);

      expect(plan.exceptions, isEmpty);
      // p1 gets one berth on each remaining half-double (cross-fill).
      expect(_seatIds(plan, 'p1'), ['DU1', 'DU2']);
    });

    test('cross-filling two STRANGER half-doubles is refused → '
        'sharedDoubleNeedsReview', () {
      // Same layout but the half-double partners are UNRELATED to p1. Completing
      // either cell would seat strangers side by side → the engine refuses to
      // auto-pair and raises sharedDoubleNeedsReview instead.
      final buses = [
        _bus('b1', [
          _seat(0, 0, SeatType.doubleSofa, SeatPosition.upper, 'DU1'),
          _seat(0, 2, SeatType.doubleSofa, SeatPosition.upper, 'DU2'),
        ]),
      ];
      final filler1 = _p('f1',
          lines: [_line(SeatType.singleSofa, null, 1)],
          assigned: [SeatAssignment(busId: 'b1', seatId: 'DU1', locked: true)]);
      final filler2 = _p('f2',
          lines: [_line(SeatType.singleSofa, null, 1)],
          assigned: [SeatAssignment(busId: 'b1', seatId: 'DU2', locked: true)]);
      final p =
          _p('z_p1', lines: [_line(SeatType.doubleSofa, SeatPosition.lower, 1)]);
      final plan = SeatingEngine.propose(
          buses: buses, passengers: [filler1, filler2, p]);

      expect(plan.forPassenger('z_p1'), isEmpty);
      expect(
          plan.exceptions.any(
              (e) => e.type == SeatingExceptionType.sharedDoubleNeedsReview),
          isTrue);
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

  group('regression: goal order — priority over group lower berth (finding 5)',
      () {
    test('an approved-priority individual gets a lower berth over a '
        'non-priority group', () {
      // Two LOWER berths (scanned first) + two UPPER berths. A non-priority
      // group {g_a,g_b} is placed BEFORE the priority VIP, and left ungated the
      // group's greedy fill would grab both lowers. The lower-berth reserve must
      // hold one lower back so the VIP still lands on a lower berth; the group
      // yields one lower to an upper.
      final buses = [
        _bus('b1', [
          _seat(0, 0, SeatType.singleSofa, SeatPosition.lower, 'lower_a'),
          _seat(0, 1, SeatType.singleSofa, SeatPosition.lower, 'lower_b'),
          _seat(1, 0, SeatType.singleSofa, SeatPosition.upper, 'upper_a'),
          _seat(1, 1, SeatType.singleSofa, SeatPosition.upper, 'upper_b'),
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
      expect(['lower_a', 'lower_b'].contains(vipSeat), isTrue,
          reason: 'approved priority (goal 1) outranks group adjacency (goal 2)');
      expect(plan.exceptions
          .any((e) => e.type == SeatingExceptionType.priorityNoLowerBerth),
          isFalse,
          reason: 'VIP actually got a lower berth');
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

    test('SAME-GROUP outbound + return singles reuse a double across legs — all '
        'four fit (each leg has 2 slots; same group may co-seat)', () {
      // One doubleSofa (2 berths × 2 legs). Place 2 outbound-only + 2 return-only
      // singles. Filling BOTH berths of one leg means two passengers SIT
      // TOGETHER on that leg, so they must be agent-tagged related — here all
      // four share one group. Disjoint-leg reuse (a GO berth and a RETURN berth
      // on the same physical seat) needs no relation, but same-leg co-seating
      // does, and same-group satisfies it → all four fit, no review.
      final buses = [
        _bus('b1', [
          _seat(0, 3, SeatType.doubleSofa, SeatPosition.upper, 'DU1'),
        ]),
      ];
      final g1 = _p('g1',
          groupId: 'fam',
          tripType: TripType.outboundOnly,
          lines: [_line(SeatType.singleSofa, null, 1)]);
      final g2 = _p('g2',
          groupId: 'fam',
          tripType: TripType.outboundOnly,
          lines: [_line(SeatType.singleSofa, null, 1)]);
      final r1 = _p('r1',
          groupId: 'fam',
          tripType: TripType.returnOnly,
          lines: [_line(SeatType.singleSofa, null, 1)]);
      final r2 = _p('r2',
          groupId: 'fam',
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

    test('a returnOnly reuses the RETURN slot of a double an UNRELATED '
        'outboundOnly holds — disjoint legs never co-seat, so no review', () {
      // The narrow disjoint-leg case: one outbound-only and one return-only,
      // UNRELATED, on the SAME berth of a double. They never share the bus at
      // once, so the stranger-share rule does NOT apply — both placed cleanly.
      final buses = [
        _bus('b1', [
          _seat(0, 3, SeatType.doubleSofa, SeatPosition.upper, 'DU1'),
        ]),
      ];
      final go = _p('go',
          tripType: TripType.outboundOnly,
          lines: [_line(SeatType.singleSofa, null, 1)]);
      final ret = _p('ret',
          tripType: TripType.returnOnly,
          lines: [_line(SeatType.singleSofa, null, 1)]);
      final plan = SeatingEngine.propose(buses: buses, passengers: [go, ret]);

      expect(plan.exceptions, isEmpty,
          reason: 'disjoint-leg reuse never co-seats strangers');
      expect(plan.forPassenger('go').single.seatId, 'DU1');
      expect(plan.forPassenger('ret').single.seatId, 'DU1');
      final occ = plan.legOccupancy([go, ret])['b1:DU1']!;
      expect(occ.go, 1);
      expect(occ.ret, 1);
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

  // ── Mixed double permutations (operator audit L2 / L8) ───────────────────

  group('mixed double sofa permutations', () {
    test('same-group: one RT berth + GO + RET on the other berth — all three fit',
        () {
      // Operator mix: passenger A holds ONE berth of DU1 for the full trip;
      // B takes the other berth GO-only; C takes the other berth RET-only.
      // Same group → overlapping-leg co-seat on GO (A+B) is allowed.
      final buses = [
        _bus('b1', [
          _seat(0, 3, SeatType.doubleSofa, SeatPosition.upper, 'DU1'),
        ]),
      ];
      final a = _p('a_rt',
          groupId: 'fam',
          tripType: TripType.roundTrip,
          lines: [_line(SeatType.singleSofa, null, 1)]);
      final b = _p('b_go',
          groupId: 'fam',
          tripType: TripType.outboundOnly,
          lines: [_line(SeatType.singleSofa, null, 1)]);
      final c = _p('c_ret',
          groupId: 'fam',
          tripType: TripType.returnOnly,
          lines: [_line(SeatType.singleSofa, null, 1)]);
      final plan =
          SeatingEngine.propose(buses: buses, passengers: [a, b, c]);

      expect(plan.exceptions, isEmpty,
          reason: 'mixed RT-berth + GO/RET remainder must fit one double');
      for (final id in ['a_rt', 'b_go', 'c_ret']) {
        expect(plan.forPassenger(id).single.seatId, 'DU1');
      }
      final occ = plan.legOccupancy([a, b, c])['b1:DU1']!;
      expect(occ.go, 2, reason: 'A RT + B GO occupy both GO berths');
      expect(occ.ret, 2, reason: 'A RT + C RET occupy both RETURN berths');
    });

    test('two unrelated outboundOnly singles on one double → '
        'sharedDoubleNeedsReview (not auto-paired)', () {
      final buses = [
        _bus('b1', [
          _seat(0, 3, SeatType.doubleSofa, SeatPosition.upper, 'DU1'),
        ]),
      ];
      final a = _p('a_go',
          tripType: TripType.outboundOnly,
          lines: [_line(SeatType.singleSofa, null, 1)]);
      final b = _p('b_go',
          tripType: TripType.outboundOnly,
          lines: [_line(SeatType.singleSofa, null, 1)]);
      final plan = SeatingEngine.propose(buses: buses, passengers: [a, b]);

      // First GO can take a berth; second same-leg stranger must not auto-pair.
      final placed = plan.forPassenger('a_go').length +
          plan.forPassenger('b_go').length;
      expect(placed, lessThanOrEqualTo(1),
          reason: 'at most one stranger auto-placed on the double');
      expect(
        plan.exceptions.any(
          (e) => e.type == SeatingExceptionType.sharedDoubleNeedsReview,
        ),
        isTrue,
        reason: 'second GO stranger must surface for agent confirm',
      );
    });

    test('unrelated mix: RT berth + stranger GO on other berth → review', () {
      final buses = [
        _bus('b1', [
          _seat(0, 3, SeatType.doubleSofa, SeatPosition.upper, 'DU1'),
        ]),
      ];
      final a = _p('a_rt',
          tripType: TripType.roundTrip,
          lines: [_line(SeatType.singleSofa, null, 1)]);
      final b = _p('b_go',
          tripType: TripType.outboundOnly,
          lines: [_line(SeatType.singleSofa, null, 1)]);
      final plan = SeatingEngine.propose(buses: buses, passengers: [a, b]);

      final bothOnDu1 = plan.forPassenger('a_rt').isNotEmpty &&
          plan.forPassenger('b_go').isNotEmpty &&
          plan.forPassenger('a_rt').every((x) => x.seatId == 'DU1') &&
          plan.forPassenger('b_go').every((x) => x.seatId == 'DU1');
      if (bothOnDu1) {
        fail('strangers must not auto-share overlapping legs on a double');
      }
      expect(
        plan.exceptions.any(
          (e) => e.type == SeatingExceptionType.sharedDoubleNeedsReview,
        ) ||
            plan.forPassenger('b_go').isEmpty ||
            plan.forPassenger('a_rt').isEmpty,
        isTrue,
        reason: 'engine refuses stranger overlapping-leg share or reviews it',
      );
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

  // Regression for the latent _buildPendingLines over-satisfaction bug: when a
  // passenger holds ONE locked berth of a double they requested whole, but the
  // partner berth is taken (so they can't complete it), the old code decremented
  // the doubleSofa line via `_drainDoubleCrossFill` and — because of `&&`
  // short-circuit — never restored it on partner refusal, silently marking the
  // passenger satisfied while holding only half their berths. They then vanished
  // with NO exception. The fix only consumes the line when the partner is
  // actually claimable.
  group('own-cell double completion never silently over-satisfies', () {
    test('half-held double whose partner is taken surfaces an exception '
        'instead of vanishing', () {
      final buses = [
        _bus('b1', [
          _seat(0, 4, SeatType.doubleSofa, SeatPosition.lower, 'DL1'),
        ]),
      ];
      // P wants a WHOLE double (2 berths) but holds only one LOCKED berth of
      // DL1; Q locks the other berth on the same legs, so P can never complete
      // DL1 and there is no other double free.
      final p = _p('P',
          lines: [_line(SeatType.doubleSofa, null, 1)],
          assigned: const [
            SeatAssignment(busId: 'b1', seatId: 'DL1', locked: true),
          ]);
      final q = _p('Q',
          lines: [_line(SeatType.singleSofa, null, 1)],
          assigned: const [
            SeatAssignment(busId: 'b1', seatId: 'DL1', locked: true),
          ]);

      final plan = SeatingEngine.propose(buses: buses, passengers: [p, q]);

      // P holds only 1 of the 2 berths they need — that shortfall MUST surface,
      // not be silently swallowed.
      expect(plan.forPassenger('P').length, 1);
      expect(plan.exceptions.where((e) => e.passengerId == 'P'), isNotEmpty,
          reason: 'a passenger left half-seated must raise an exception');
    });
  });
}
