import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/bus_type.dart';
import 'package:occubusbooking/models/seat_layout.dart';
import 'package:occubusbooking/utils/bus_layout_recovery.dart';

/// The repair half of the seat-layout data loss.
///
/// Two live buses lost their `layout` jsonb to a whole-row write, but kept
/// `total_seats` and every passenger's `assigned_seats`. Those surviving
/// assignments still name real seat ids, and [BusLayout.generate] is
/// deterministic — seat ids are `prefix + row-major index` — so regenerating
/// with the ORIGINAL inputs reproduces the original ids exactly and every
/// assignment re-attaches on its own.
///
/// The inputs are not recorded anywhere, so they have to be inferred from the
/// surviving ids. These tests pin both halves of that: it recovers when the
/// evidence is sufficient, and it REFUSES rather than guessing when it is not.
/// A wrong guess would silently re-seat real passengers.
void main() {
  /// Every seat id a generated layout would contain.
  Set<String> idsOf(BusLayout l) => l.allSeatIds.toSet();

  BusLayout original({
    int totalSeats = 37,
    int singleSofaCount = 13,
    bool allDoubleBackRow = false,
  }) =>
      BusLayout.generate(
        busType: BusType.sleeper,
        totalSeats: totalSeats,
        singleSofaCount: singleSofaCount,
        allDoubleBackRow: allDoubleBackRow,
      );

  group('recoverBusLayout — round trip', () {
    test('rebuilds a 37-berth sleeper from its surviving seat ids', () {
      // The live shape. Note berths != tiles: 37 berths is 13 single sofas plus
      // 12 doubles = 25 physical seat ids. With 36 of 37 berths assigned every
      // tile is occupied, so the surviving evidence is the whole id set.
      final lost = original();
      expect(lost.totalSeats, 37);
      expect(idsOf(lost).length, 25, reason: 'a double sofa is ONE tile');

      final result = recoverBusLayout(
        totalSeats: 37,
        busType: BusType.sleeper,
        assignedSeatIds: idsOf(lost),
      );

      expect(result.recovered, isTrue, reason: result.reason);
      expect(idsOf(result.layout!), idsOf(lost),
          reason: 'every surviving assignment must re-attach untouched');
      expect(result.layout!.totalSeats, 37);
    });

    test('an unoccupied tile leaves an ambiguity it will not guess through',
        () {
      // Withhold one tile: two layouts then fit, differing only in whether the
      // 25th seat is the upper or the lower berth. Both re-seat all the known
      // riders identically, so both are offered rather than one being invented.
      final lost = original();
      final survivors = idsOf(lost).toList()..sort();
      final evidence = survivors.take(survivors.length - 1).toSet();

      final result = recoverBusLayout(
        totalSeats: 37,
        busType: BusType.sleeper,
        assignedSeatIds: evidence,
      );

      expect(result.recovered, isFalse);
      expect(result.candidateCount, 2);
      for (final candidate in result.candidates) {
        expect(idsOf(candidate).containsAll(evidence), isTrue,
            reason: 'every candidate must still seat every known rider');
      }
    });

    test('recovers the all-double-back-row variant distinctly', () {
      final lost = original(allDoubleBackRow: true);
      final result = recoverBusLayout(
        totalSeats: 37,
        busType: BusType.sleeper,
        assignedSeatIds: idsOf(lost),
      );

      expect(result.recovered, isTrue, reason: result.reason);
      expect(idsOf(result.layout!), idsOf(lost));
    });

    test('recovers an all-double bus (no single sofas at all)', () {
      final lost = original(totalSeats: 40, singleSofaCount: 0);
      final result = recoverBusLayout(
        totalSeats: 40,
        busType: BusType.sleeper,
        assignedSeatIds: idsOf(lost),
      );

      expect(result.recovered, isTrue, reason: result.reason);
      expect(idsOf(result.layout!), idsOf(lost));
    });
  });

  group('recoverBusLayout — refuses to guess', () {
    test('no evidence at all is not recoverable', () {
      final result = recoverBusLayout(
        totalSeats: 37,
        busType: BusType.sleeper,
        assignedSeatIds: const {},
      );

      expect(result.recovered, isFalse);
      expect(result.reason, contains('no surviving'));
    });

    test('evidence too thin to separate candidates is not recoverable', () {
      // A single low-numbered single-sofa id is consistent with almost every
      // composition of the bus, so nothing can be concluded from it.
      final result = recoverBusLayout(
        totalSeats: 37,
        busType: BusType.sleeper,
        assignedSeatIds: const {'SL1'},
      );

      expect(result.recovered, isFalse);
      expect(result.reason, contains('ambiguous'));
      expect(result.candidateCount, greaterThan(2));
    });

    test('ids that no valid layout can host are reported, not ignored', () {
      final result = recoverBusLayout(
        totalSeats: 37,
        busType: BusType.sleeper,
        // 400 single-sofa berths cannot exist on a 37-berth bus.
        assignedSeatIds: const {'SL1', 'SL400'},
      );

      expect(result.recovered, isFalse);
      expect(result.reason, contains('no candidate'));
      expect(result.unmatched, contains('SL400'));
    });

    test('a zero-seat bus is not recoverable', () {
      final result = recoverBusLayout(
        totalSeats: 0,
        busType: BusType.sleeper,
        assignedSeatIds: const {'SL1'},
      );

      expect(result.recovered, isFalse);
    });
  });
}
