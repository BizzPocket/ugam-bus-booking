import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/passenger.dart';
import 'package:occubusbooking/models/request_line.dart';
import 'package:occubusbooking/models/seat_assignment.dart';
import 'package:occubusbooking/models/seat_type.dart';

// isFullyAssigned must compare like with like: a whole Double Sofa occupies TWO
// physical berths (it is stored as two SeatAssignment entries), so completeness
// has to be measured in berths — not in request "units" where a double counts
// as one. Mixing the two made a passenger with multiple doubles look fully
// assigned after freeing only some of their sofas, so they never returned to
// the pending dock until EVERY sofa was freed.

Passenger _p(List<RequestLine> lines, List<SeatAssignment> assigned) =>
    Passenger(
      id: 'p',
      tourId: 't',
      name: 'n',
      phone: '+910000000000',
      requestLines: lines,
      assignedSeats: assigned,
    );

RequestLine _single({int qty = 1}) =>
    RequestLine(seatType: SeatType.singleSofa, position: null, qty: qty);
RequestLine _double({int qty = 1}) =>
    RequestLine(seatType: SeatType.doubleSofa, position: null, qty: qty);

// A whole double is two berths on the same physical cell.
List<SeatAssignment> _wholeDouble(String seatId) => [
      SeatAssignment(busId: 'b1', seatId: seatId),
      SeatAssignment(busId: 'b1', seatId: seatId),
    ];

void main() {
  group('isFullyAssigned (berth-accurate completeness)', () {
    test('single sofa: assigned when its one berth is placed', () {
      final p = _p([_single()], [const SeatAssignment(busId: 'b1', seatId: 'A1')]);
      expect(p.isFullyAssigned, isTrue);
    });

    test('single sofa: not assigned when no berth placed', () {
      final p = _p([_single()], const []);
      expect(p.isFullyAssigned, isFalse);
    });

    test('one whole double: assigned only with BOTH berths', () {
      expect(_p([_double()], _wholeDouble('DL1')).isFullyAssigned, isTrue);
      expect(
        _p([_double()], [const SeatAssignment(busId: 'b1', seatId: 'DL1')])
            .isFullyAssigned,
        isFalse,
      );
    });

    test('TWO doubles: fully assigned only with all four berths', () {
      final both = _p([_double(qty: 2)], [
        ..._wholeDouble('DL1'),
        ..._wholeDouble('DL2'),
      ]);
      expect(both.isFullyAssigned, isTrue);
    });

    test('TWO doubles: freeing ONE double drops back to pending (the bug)', () {
      // Was: assignedSeats.length(2) >= totalSeatsRequested(2) => true.
      // Now: berths assigned(2) >= seatBerths(4) => false.
      final oneFreed = _p([_double(qty: 2)], _wholeDouble('DL1'));
      expect(oneFreed.isFullyAssigned, isFalse);
      expect(oneFreed.isPartiallyAssigned, isTrue);
    });

    test('mixed: 1 single + 1 double needs all three berths', () {
      final full = _p([_single(), _double()], [
        const SeatAssignment(busId: 'b1', seatId: 'A1'),
        ..._wholeDouble('DL1'),
      ]);
      expect(full.isFullyAssigned, isTrue);

      final missingHalf = _p([_single(), _double()], [
        const SeatAssignment(busId: 'b1', seatId: 'A1'),
        const SeatAssignment(busId: 'b1', seatId: 'DL1'),
      ]);
      expect(missingHalf.isFullyAssigned, isFalse);
    });

    test('no request lines: vacuously fully assigned', () {
      expect(_p(const [], const []).isFullyAssigned, isTrue);
    });
  });

  group('progressLabel (berth-accurate, in lock-step with isFullyAssigned)', () {
    test('two doubles fully seated reads ✓ 4/4', () {
      final full = _p([_double(qty: 2)], [
        ..._wholeDouble('DL1'),
        ..._wholeDouble('DL2'),
      ]);
      expect(full.progressLabel, '✓ 4/4');
    });

    test('two doubles with one freed reads 2/4 (no false ✓)', () {
      final oneFreed = _p([_double(qty: 2)], _wholeDouble('DL1'));
      expect(oneFreed.progressLabel, '2/4');
    });

    test('single sofa seated reads ✓ 1/1', () {
      final p =
          _p([_single()], [const SeatAssignment(busId: 'b1', seatId: 'A1')]);
      expect(p.progressLabel, '✓ 1/1');
    });
  });
}
