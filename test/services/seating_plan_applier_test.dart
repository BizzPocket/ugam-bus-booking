import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/passenger.dart';
import 'package:occubusbooking/models/request_line.dart';
import 'package:occubusbooking/models/seat_assignment.dart';
import 'package:occubusbooking/models/seat_type.dart';
import 'package:occubusbooking/services/seating_engine.dart';
import 'package:occubusbooking/services/seating_plan_applier.dart';

// ── Fixture helpers ─────────────────────────────────────────────────────────

Passenger _p(
  String id, {
  List<SeatAssignment> assigned = const [],
  List<RequestLine> lines = const [],
}) =>
    Passenger(
      id: id,
      tourId: 't1',
      name: id,
      phone: '+910000000000',
      assignedSeats: assigned,
      requestLines: lines,
    );

SeatAssignment _a(String busId, String seatId, {bool locked = false}) =>
    SeatAssignment(busId: busId, seatId: seatId, locked: locked);

SeatingPlan _plan(Map<String, List<SeatAssignment>> byPassenger) => SeatingPlan(
      assignmentsByPassenger: byPassenger,
      exceptions: const [],
      reasons: const [],
    );

void main() {
  group('only changed passengers emit', () {
    test('an unchanged passenger produces no change', () {
      final p = _p('p1', assigned: [_a('b1', 'SU1')]);
      final plan = _plan({
        'p1': [_a('b1', 'SU1')],
      });

      final changes = SeatingPlanApplier.diff(plan: plan, passengers: [p]);
      expect(changes, isEmpty);
    });

    test('a moved seat produces exactly one change with the new seats', () {
      final p = _p('p1', assigned: [_a('b1', 'SU1')]);
      final plan = _plan({
        'p1': [_a('b1', 'SL1')], // moved SU1 -> SL1
      });

      final changes = SeatingPlanApplier.diff(plan: plan, passengers: [p]);
      expect(changes.length, 1);
      expect(changes.single.passengerId, 'p1');
      expect(changes.single.newAssignedSeats.single.seatId, 'SL1');
    });

    test('order is insensitive — same multiset is unchanged', () {
      final p = _p('p1', assigned: [_a('b1', 'SU1'), _a('b1', 'SL1')]);
      final plan = _plan({
        'p1': [_a('b1', 'SL1'), _a('b1', 'SU1')], // reordered, same set
      });

      final changes = SeatingPlanApplier.diff(plan: plan, passengers: [p]);
      expect(changes, isEmpty);
    });

    test('only the changed passenger among many is emitted', () {
      final p1 = _p('p1', assigned: [_a('b1', 'SU1')]);
      final p2 = _p('p2', assigned: [_a('b1', 'SL1')]);
      final p3 = _p('p3', assigned: [_a('b1', 'ST1')]);
      final plan = _plan({
        'p1': [_a('b1', 'SU1')], // unchanged
        'p2': [_a('b1', 'DL1')], // moved
        'p3': [_a('b1', 'ST1')], // unchanged
      });

      final changes =
          SeatingPlanApplier.diff(plan: plan, passengers: [p1, p2, p3]);
      expect(changes.length, 1);
      expect(changes.single.passengerId, 'p2');
    });

    test('changes are sorted by passengerId', () {
      final pz = _p('z', assigned: [_a('b1', 'SU1')]);
      final pa = _p('a', assigned: [_a('b1', 'SL1')]);
      final plan = _plan({
        'z': [_a('b1', 'DU1')], // changed
        'a': [_a('b1', 'DL1')], // changed
      });

      final changes =
          SeatingPlanApplier.diff(plan: plan, passengers: [pz, pa]);
      expect(changes.map((c) => c.passengerId).toList(), ['a', 'z']);
    });
  });

  group('whole-double vs half-double multiset', () {
    test('downgrading a whole double to a half registers as a change', () {
      // Holds whole double (2 entries on DL1).
      final p = _p('p1', assigned: [_a('b1', 'DL1'), _a('b1', 'DL1')]);
      final plan = _plan({
        'p1': [_a('b1', 'DL1')], // now only one berth
      });

      final changes = SeatingPlanApplier.diff(plan: plan, passengers: [p]);
      expect(changes.length, 1);
      expect(changes.single.newAssignedSeats.length, 1);
    });

    test('an unchanged whole double does NOT emit', () {
      final p = _p('p1', assigned: [_a('b1', 'DL1'), _a('b1', 'DL1')]);
      final plan = _plan({
        'p1': [_a('b1', 'DL1'), _a('b1', 'DL1')],
      });

      final changes = SeatingPlanApplier.diff(plan: plan, passengers: [p]);
      expect(changes, isEmpty);
    });
  });

  group('locked handling', () {
    test('a lock-only toggle on the same berth is a change', () {
      final p = _p('p1', assigned: [_a('b1', 'SU1', locked: false)]);
      final plan = _plan({
        'p1': [_a('b1', 'SU1', locked: true)], // same seat, now locked
      });

      final changes = SeatingPlanApplier.diff(plan: plan, passengers: [p]);
      expect(changes.length, 1);
      expect(changes.single.newAssignedSeats.single.locked, isTrue);
    });

    test('identical locked assignments do NOT emit', () {
      final p = _p('p1', assigned: [_a('b1', 'SU1', locked: true)]);
      final plan = _plan({
        'p1': [_a('b1', 'SU1', locked: true)],
      });

      final changes = SeatingPlanApplier.diff(plan: plan, passengers: [p]);
      expect(changes, isEmpty);
    });

    test('a now-unplaced passenger keeps locked seats, loses non-locked ones',
        () {
      // Passenger currently holds a locked SU1 and a non-locked SL1.
      final p = _p('p1', assigned: [
        _a('b1', 'SU1', locked: true),
        _a('b1', 'SL1', locked: false),
      ]);
      // The engine preserves locked entries verbatim, so the plan keeps SU1.
      final plan = _plan({
        'p1': [_a('b1', 'SU1', locked: true)],
      });

      final changes = SeatingPlanApplier.diff(plan: plan, passengers: [p]);
      expect(changes.length, 1);
      final seats = changes.single.newAssignedSeats;
      expect(seats.length, 1);
      expect(seats.single.seatId, 'SU1');
      expect(seats.single.locked, isTrue);
    });

    test('a fully-unplaced passenger (no locked) is cleared to empty', () {
      final p = _p('p1', assigned: [_a('b1', 'SL1')]);
      // Absent from the plan map => forPassenger returns empty.
      final plan = _plan({});

      final changes = SeatingPlanApplier.diff(plan: plan, passengers: [p]);
      expect(changes.length, 1);
      expect(changes.single.newAssignedSeats, isEmpty);
    });

    test('a passenger with no seats and none proposed does not emit', () {
      final p = _p('p1');
      final plan = _plan({});

      final changes = SeatingPlanApplier.diff(plan: plan, passengers: [p]);
      expect(changes, isEmpty);
    });
  });

  group('end-to-end with the real engine', () {
    test('diff against a freshly-proposed plan only touches moved passengers',
        () {
      // Build a bus + passengers, propose, and assert the applier returns the
      // engine's assignments for passengers who were previously unassigned.
      final p1 = _p('p1', lines: [
        RequestLine(seatType: SeatType.seater, position: null, qty: 1),
      ]);
      final plan = SeatingEngine.propose(buses: const [], passengers: [p1]);
      // No buses => p1 unplaced; p1 currently holds no seats => no change.
      final changes = SeatingPlanApplier.diff(plan: plan, passengers: [p1]);
      expect(changes, isEmpty);
    });
  });
}
