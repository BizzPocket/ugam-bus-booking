import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/bus_details.dart';
import 'package:occubusbooking/models/passenger.dart';
import 'package:occubusbooking/models/priority_status.dart';
import 'package:occubusbooking/models/request_line.dart';
import 'package:occubusbooking/models/seat_assignment.dart';
import 'package:occubusbooking/models/seat_layout.dart';
import 'package:occubusbooking/models/seat_type.dart';
import 'package:occubusbooking/services/group_cascade.dart';
import 'package:occubusbooking/services/seating_engine.dart';

// ── Fixture helpers ─────────────────────────────────────────────────────────

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
  String name = '',
  PriorityStatus priority = PriorityStatus.none,
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
    );

RequestLine _line(SeatType t, SeatPosition? pos, int qty) =>
    RequestLine(seatType: t, position: pos, qty: qty);

SeatAssignment _a(String busId, String seatId) =>
    SeatAssignment(busId: busId, seatId: seatId);

void main() {
  group('member resolution', () {
    test('an ungrouped mover is a group of one', () {
      final bus = _bus('b1', [
        _seat(0, 0, SeatType.singleSofa, SeatPosition.upper, 'SU1'),
      ]);
      final mover = _p('m1', lines: [_line(SeatType.singleSofa, null, 1)]);

      final plan = GroupCascade.planMove(
        mover: mover,
        destinationBus: bus,
        passengers: [mover],
      );

      expect(plan.memberPassengerIds, ['m1']);
      expect(plan.destinationFits, isTrue);
      expect(plan.blockedReason, isNull);
    });

    test('all group siblings move together, including the mover', () {
      final bus = _bus('b1', [
        _seat(0, 0, SeatType.singleSofa, SeatPosition.upper, 'SU1'),
        _seat(0, 1, SeatType.singleSofa, SeatPosition.lower, 'SL1'),
        _seat(0, 2, SeatType.seater, null, 'ST1'),
      ]);
      final a = _p('g_a', groupId: 'Patel', lines: [_line(SeatType.singleSofa, null, 1)]);
      final b = _p('g_b', groupId: 'Patel', lines: [_line(SeatType.singleSofa, null, 1)]);
      final c = _p('g_c', groupId: 'Patel', lines: [_line(SeatType.seater, null, 1)]);
      final outsider = _p('x', lines: [_line(SeatType.seater, null, 1)]);

      final plan = GroupCascade.planMove(
        mover: b,
        destinationBus: bus,
        passengers: [a, b, c, outsider],
      );

      expect(plan.memberPassengerIds, ['g_a', 'g_b', 'g_c']);
      expect(plan.destinationFits, isTrue);
    });
  });

  group('destination fits', () {
    test('group fits when capacity + types are available', () {
      final bus = _bus('b1', [
        _seat(0, 3, SeatType.doubleSofa, SeatPosition.upper, 'DU1'),
        _seat(0, 4, SeatType.doubleSofa, SeatPosition.lower, 'DL1'),
        _seat(1, 0, SeatType.seater, null, 'ST1'),
      ]);
      final a = _p('g_a', groupId: 'Shah', lines: [_line(SeatType.doubleSofa, null, 1)]);
      final b = _p('g_b', groupId: 'Shah', lines: [_line(SeatType.seater, null, 1)]);

      final plan = GroupCascade.planMove(
        mover: a,
        destinationBus: bus,
        passengers: [a, b],
      );

      expect(plan.destinationFits, isTrue);
      expect(plan.blockedReason, isNull);
    });

    test('moving members vacate their own destination seats (counted free)',
        () {
      // Only one whole double on the bus, already held by the moving group.
      final bus = _bus('b1', [
        _seat(0, 4, SeatType.doubleSofa, SeatPosition.lower, 'DL1'),
      ]);
      // Group already sits on DL1 (whole double) but we are "re-moving" them
      // here; their berths must be counted as available to themselves.
      final a = _p('g_a',
          groupId: 'Mehta',
          lines: [_line(SeatType.doubleSofa, null, 1)],
          assigned: [_a('b1', 'DL1'), _a('b1', 'DL1')]);

      final plan = GroupCascade.planMove(
        mover: a,
        destinationBus: bus,
        passengers: [a],
      );

      expect(plan.destinationFits, isTrue);
    });
  });

  group('destination does NOT fit', () {
    test('reports a shortfall when not enough seats exist', () {
      final bus = _bus('b1', [
        _seat(0, 0, SeatType.singleSofa, SeatPosition.upper, 'SU1'),
      ]);
      final a = _p('g_a', groupId: 'Joshi', lines: [_line(SeatType.singleSofa, null, 1)]);
      final b = _p('g_b', groupId: 'Joshi', lines: [_line(SeatType.singleSofa, null, 1)]);

      final plan = GroupCascade.planMove(
        mover: a,
        destinationBus: bus,
        passengers: [a, b],
      );

      expect(plan.destinationFits, isFalse);
      expect(plan.blockedReason, contains('Group Joshi'));
      expect(plan.blockedReason, contains('Single Sofa'));
      expect(plan.memberPassengerIds, ['g_a', 'g_b']);
    });

    test('seats held by NON-members are not available to the group', () {
      final bus = _bus('b1', [
        _seat(0, 0, SeatType.singleSofa, SeatPosition.upper, 'SU1'),
        _seat(0, 1, SeatType.singleSofa, SeatPosition.lower, 'SL1'),
      ]);
      // SL1 is taken by an outsider, so only SU1 is free — one single short.
      final outsider = _p('x', assigned: [_a('b1', 'SL1')]);
      final a = _p('g_a', groupId: 'Rana', lines: [_line(SeatType.singleSofa, null, 1)]);
      final b = _p('g_b', groupId: 'Rana', lines: [_line(SeatType.singleSofa, null, 1)]);

      final plan = GroupCascade.planMove(
        mover: a,
        destinationBus: bus,
        passengers: [a, b, outsider],
      );

      expect(plan.destinationFits, isFalse);
      expect(plan.blockedReason, contains('1 Single Sofa'));
    });

    test('a reserved seat does not count toward capacity', () {
      final bus = _bus('b1', [
        _seat(0, 0, SeatType.seater, null, 'ST1', reserved: true),
        _seat(0, 1, SeatType.seater, null, 'ST2'),
      ]);
      final a = _p('g_a', groupId: 'Vyas', lines: [_line(SeatType.seater, null, 1)]);
      final b = _p('g_b', groupId: 'Vyas', lines: [_line(SeatType.seater, null, 1)]);

      final plan = GroupCascade.planMove(
        mover: a,
        destinationBus: bus,
        passengers: [a, b],
      );

      expect(plan.destinationFits, isFalse);
      expect(plan.blockedReason, contains('1 Seater'));
    });

    test('a bus with no layout cannot hold the group', () {
      final bus = Bus(id: 'b1', name: 'b1');
      final mover = _p('m1', lines: [_line(SeatType.seater, null, 1)]);

      final plan = GroupCascade.planMove(
        mover: mover,
        destinationBus: bus,
        passengers: [mover],
      );

      expect(plan.destinationFits, isFalse);
      expect(plan.blockedReason, contains('no seat layout'));
    });
  });

  group('cross-fill capacity', () {
    test('two free singles satisfy a group double need via cross-fill', () {
      final bus = _bus('b1', [
        _seat(0, 0, SeatType.singleSofa, SeatPosition.upper, 'SU1'),
        _seat(0, 1, SeatType.singleSofa, SeatPosition.lower, 'SL1'),
      ]);
      final a = _p('g_a', groupId: 'Soni', lines: [_line(SeatType.doubleSofa, null, 1)]);

      final plan = GroupCascade.planMove(
        mover: a,
        destinationBus: bus,
        passengers: [a],
      );

      // The seating engine's cross-fill rule satisfies one Double Sofa line with
      // TWO single berths (SeatingEngine._placeOneBerth). The cascade must
      // mirror that, so the group DOES fit (regression for finding 3).
      expect(plan.destinationFits, isTrue);
      expect(plan.blockedReason, isNull);
    });

    test('a single need can sit on one berth of a free double (single-on-double)',
        () {
      final bus = _bus('b1', [
        _seat(0, 4, SeatType.doubleSofa, SeatPosition.lower, 'DL1'),
      ]);
      final a = _p('g_a', groupId: 'Dave', lines: [_line(SeatType.singleSofa, null, 1)]);

      final plan = GroupCascade.planMove(
        mover: a,
        destinationBus: bus,
        passengers: [a],
      );

      expect(plan.destinationFits, isTrue);
    });
  });

  group('cross-fill / deck regression (findings 3 & 4)', () {
    test(
        'finding 3: a real 2-member group (each 1 doubleSofa) fits on a 4-single bus',
        () {
      // Only single sofas free, no whole double cell. The engine cross-fills
      // each Double Sofa line with two single berths, seating the whole group.
      final bus = _bus('b1', [
        _seat(0, 0, SeatType.singleSofa, SeatPosition.upper, 'SU1'),
        _seat(0, 1, SeatType.singleSofa, SeatPosition.lower, 'SL1'),
        _seat(1, 0, SeatType.singleSofa, SeatPosition.upper, 'SU2'),
        _seat(1, 1, SeatType.singleSofa, SeatPosition.lower, 'SL2'),
      ]);
      final a = _p('g_a', groupId: 'K', lines: [_line(SeatType.doubleSofa, null, 1)]);
      final b = _p('g_b', groupId: 'K', lines: [_line(SeatType.doubleSofa, null, 1)]);

      final plan = GroupCascade.planMove(
        mover: a,
        destinationBus: bus,
        passengers: [a, b],
      );

      expect(plan.destinationFits, isTrue);
      expect(plan.blockedReason, isNull);
    });

    test(
        'finding 3: a mixed group (a:1 doubleSofa, b:1 singleSofa) fits on a 4-single bus',
        () {
      final bus = _bus('b1', [
        _seat(0, 0, SeatType.singleSofa, SeatPosition.upper, 'SU1'),
        _seat(0, 1, SeatType.singleSofa, SeatPosition.lower, 'SL1'),
        _seat(1, 0, SeatType.singleSofa, SeatPosition.upper, 'SU2'),
        _seat(1, 1, SeatType.singleSofa, SeatPosition.lower, 'SL2'),
      ]);
      final a = _p('g_a', groupId: 'K', lines: [_line(SeatType.doubleSofa, null, 1)]);
      final b = _p('g_b', groupId: 'K', lines: [_line(SeatType.singleSofa, null, 1)]);

      final plan = GroupCascade.planMove(
        mover: a,
        destinationBus: bus,
        passengers: [a, b],
      );

      expect(plan.destinationFits, isTrue);
      expect(plan.blockedReason, isNull);
    });

    test(
        'finding 4: a doubleSofa UPPER need is satisfied by the only free whole double (LOWER)',
        () {
      // One whole double on the LOWER deck; the mover wants a double UPPER. The
      // engine's takeFreeCell fails the deck-exact whole take, then cross-fill
      // (position:null) claims both berths of DL1 — so it fits.
      final bus = _bus('b1', [
        _seat(0, 4, SeatType.doubleSofa, SeatPosition.lower, 'DL1'),
      ]);
      final a = _p('g_a',
          groupId: 'D',
          lines: [_line(SeatType.doubleSofa, SeatPosition.upper, 1)]);

      final plan = GroupCascade.planMove(
        mover: a,
        destinationBus: bus,
        passengers: [a],
      );

      expect(plan.destinationFits, isTrue);
      expect(plan.blockedReason, isNull);
    });

    test('still blocks when truly short: 1 single free, group needs 2 singles',
        () {
      final bus = _bus('b1', [
        _seat(0, 0, SeatType.singleSofa, SeatPosition.upper, 'SU1'),
      ]);
      final a = _p('g_a', groupId: 'Joshi', lines: [_line(SeatType.singleSofa, null, 1)]);
      final b = _p('g_b', groupId: 'Joshi', lines: [_line(SeatType.singleSofa, null, 1)]);

      final plan = GroupCascade.planMove(
        mover: a,
        destinationBus: bus,
        passengers: [a, b],
      );

      expect(plan.destinationFits, isFalse);
      expect(plan.blockedReason, contains('Group Joshi'));
    });

    test('a seated-but-not-front priority member still counts as a fit', () {
      // Only a NON-front sofa row exists (front rows are 0..frontRowCount-1).
      // A priority group member is seated there; the engine raises
      // priorityNoFrontSeat but the passenger IS placed, so the move fits.
      final frontRows = SeatingEngine.frontRowCount; // first non-front row index
      final bus = _bus('b1', [
        _seat(frontRows, 0, SeatType.singleSofa, SeatPosition.upper, 'SUx'),
      ]);
      final a = _p('g_a',
          groupId: 'VIP',
          priority: PriorityStatus.approved,
          lines: [_line(SeatType.singleSofa, null, 1)]);

      final plan = GroupCascade.planMove(
        mover: a,
        destinationBus: bus,
        passengers: [a],
      );

      expect(plan.destinationFits, isTrue);
      expect(plan.blockedReason, isNull);
    });
  });
}
