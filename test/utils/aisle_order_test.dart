import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/bus_type.dart';
import 'package:occubusbooking/models/seat_layout.dart';
import 'package:occubusbooking/models/seat_type.dart';
import 'package:occubusbooking/utils/aisle_order.dart';

/// Aisle order is the Board's "next outstanding" backbone (interaction spec §4):
/// the handler is walked down the bus in PHYSICAL order, not down a list sorted
/// by seat code. Everything the advance promises — "22 taps, nobody missed" —
/// rests on this ordering being right, stable, and matching what is drawn, so it
/// is pinned down here before any widget leans on it.
void main() {
  SeatCell berth(
    int row,
    int col,
    String id, {
    SeatType type = SeatType.singleSofa,
    SeatPosition? pos,
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

  SeatCell singleUpper(int row, String id, {bool reserved = false}) =>
      berth(row, SeatGridCols.singleUpper, id,
          pos: SeatPosition.upper, reserved: reserved);
  SeatCell singleLower(int row, String id) =>
      berth(row, SeatGridCols.singleLower, id, pos: SeatPosition.lower);
  SeatCell doubleUpper(int row, String id) => berth(
      row, SeatGridCols.doubleUpper, id,
      type: SeatType.doubleSofa, pos: SeatPosition.upper);
  SeatCell doubleLower(int row, String id) => berth(
      row, SeatGridCols.doubleLower, id,
      type: SeatType.doubleSofa, pos: SeatPosition.lower);

  // ── The reference coach ────────────────────────────────────────────────────
  // Two ordinary body rows plus a back bench whose centre-aisle column carries
  // an upper + lower pair. Small enough to write the expected walk out by hand,
  // and it exercises every slot the 5-column grid has.
  //
  //   row 0   SU1 SL1  ·   DU1 DL1
  //   row 1   SU2 SL2  ·   DU2 DL2
  //   row 2   SU3 SL3 SU4/SL4 DU3 DL3     ← back bench, berths in the aisle
  final coach = BusLayout(
    rows: 3,
    cols: SeatGridCols.count,
    grid: [
      singleUpper(0, 'SU1'), singleLower(0, 'SL1'),
      doubleUpper(0, 'DU1'), doubleLower(0, 'DL1'),
      singleUpper(1, 'SU2'), singleLower(1, 'SL2'),
      doubleUpper(1, 'DU2'), doubleLower(1, 'DL2'),
      singleUpper(2, 'SU3'), singleLower(2, 'SL3'),
      berth(2, SeatGridCols.aisle, 'SU4', pos: SeatPosition.upper),
      berth(2, SeatGridCols.aisle, 'SL4', pos: SeatPosition.lower),
      doubleUpper(2, 'DU3'), doubleLower(2, 'DL3'),
    ],
    hasBalcony: true,
  );

  /// The whole coach, front to back. Note DL before DU inside each row: the
  /// chart draws doubles lower-then-upper so both lowers sit toward the centre
  /// aisle (`CombinedSeatGrid._row`), and the walk follows what is drawn.
  const coachWalk = [
    'SU1', 'SL1', 'DL1', 'DU1', //           row 0
    'SU2', 'SL2', 'DL2', 'DU2', //           row 1
    'SU3', 'SL3', 'SU4', 'SL4', 'DL3', 'DU3', // back bench
  ];

  List<String> idsOf(Iterable<SeatCell> cells) =>
      [for (final c in cells) c.seatId!];

  BerthPredicate anyOf(Set<String> ids) => (c) => ids.contains(c.seatId);

  group('aisleOrder — the shape of the walk', () {
    test('walks row by row, left wall across to right wall', () {
      expect(idsOf(aisleOrder(coach)), coachWalk);
    });

    test('is NOT the seat-code order the rest of the app uses', () {
      // This is the whole point of the file. Alphabetical order walks the left
      // lane to the back, returns to the front for the right lane, and does it
      // again for every prefix.
      final alphabetical = [...coachWalk]..sort();
      expect(idsOf(aisleOrder(coach)), isNot(alphabetical));
      expect(alphabetical.first, 'DL1'); // a rear-right berth, walked 3rd
      expect(idsOf(aisleOrder(coach)).first, 'SU1');
    });

    test('within a bunk pair the outer berth comes before the inner one', () {
      final walk = idsOf(aisleOrder(coach));
      // Left lane: col 0 (wall) then col 1 (aisle side).
      expect(walk.indexOf('SU1'), lessThan(walk.indexOf('SL1')));
      // Right lane mirrors it: col 4 (aisle side) then col 3 (wall).
      expect(walk.indexOf('DL1'), lessThan(walk.indexOf('DU1')));
    });

    test('the back-bench aisle pair sits between the left and right lanes', () {
      final walk = idsOf(aisleOrder(coach));
      expect(walk.indexOf('SL3'), lessThan(walk.indexOf('SU4')));
      expect(walk.indexOf('SU4'), lessThan(walk.indexOf('SL4'))); // upper first
      expect(walk.indexOf('SL4'), lessThan(walk.indexOf('DL3')));
    });

    test('every row is finished before the next one starts', () {
      final rows = [for (final c in aisleOrder(coach)) c.row];
      for (var i = 1; i < rows.length; i++) {
        expect(rows[i], greaterThanOrEqualTo(rows[i - 1]));
      }
      expect(rows.first, 0);
      expect(rows.last, 2);
    });

    test('a double sofa is ONE stop on the walk, not two berths', () {
      // The coach seats 20 people across 14 tiles: the handler stops 14 times.
      expect(coach.totalSeats, 20); // 8 single berths + 6 double cells × 2
      expect(aisleOrder(coach).length, coach.totalCells);
      expect(aisleOrder(coach).length, 14);
      expect(idsOf(aisleOrder(coach)).toSet().length, 14);
    });

    test('is deterministic regardless of the order cells sit in the JSON', () {
      final shuffled = BusLayout(
        rows: coach.rows,
        cols: coach.cols,
        grid: coach.grid.reversed.toList(),
        hasBalcony: true,
      );
      expect(idsOf(aisleOrder(shuffled)), coachWalk);

      // And a rotation, so "reversed" is not accidentally the only case tested.
      final rotated = BusLayout(
        rows: coach.rows,
        cols: coach.cols,
        grid: [...coach.grid.skip(5), ...coach.grid.take(5)],
        hasBalcony: true,
      );
      expect(idsOf(aisleOrder(rotated)), coachWalk);
    });

    test('hands back an unmodifiable list — the walk is shared state', () {
      expect(
        () => aisleOrder(coach).add(singleUpper(9, 'SU9')),
        throwsUnsupportedError,
      );
    });

    test('compareAisleOrder can sort any loose list into the same walk', () {
      final loose = coach.grid.reversed.toList()..sort(compareAisleOrder);
      expect(idsOf(loose), coachWalk);
    });
  });

  group('aisleOrder — layouts that are not a tidy rectangle', () {
    test('a bus with no seat plan yet walks nowhere', () {
      expect(aisleOrder(null), isEmpty);
      expect(aisleOrder(BusLayout.empty(6)), isEmpty);
      expect(AisleWalk.of(null).isEmpty, isTrue);
      expect(AisleWalk.of(null).length, 0);
      expect(AisleWalk.of(BusLayout.empty(6)).seatIds, isEmpty);
    });

    test('gaps and ragged lanes are simply skipped', () {
      // The left lane runs out after row 0 and the right lane loses its upper
      // berth in row 2 — both happen in real generated layouts.
      final ragged = BusLayout(
        rows: 3,
        cols: SeatGridCols.count,
        grid: [
          singleUpper(0, 'SU1'), singleLower(0, 'SL1'),
          doubleUpper(0, 'DU1'), doubleLower(0, 'DL1'),
          doubleUpper(1, 'DU2'), doubleLower(1, 'DL2'),
          doubleLower(2, 'DL3'),
        ],
      );
      expect(idsOf(aisleOrder(ragged)),
          ['SU1', 'SL1', 'DL1', 'DU1', 'DL2', 'DU2', 'DL3']);
    });

    test('an empty row in the middle does not break the front-to-back run', () {
      final holed = BusLayout(
        rows: 4,
        cols: SeatGridCols.count,
        grid: [
          singleUpper(0, 'SU1'),
          // row 1 has nothing at all
          singleUpper(2, 'SU2'), doubleLower(2, 'DL1'),
          singleUpper(3, 'SU3'),
        ],
      );
      expect(idsOf(aisleOrder(holed)), ['SU1', 'SU2', 'DL1', 'SU3']);
    });

    test('blocked (reserved) berths stay in the walk — the lens skips them', () {
      final withHold = BusLayout(
        rows: 1,
        cols: SeatGridCols.count,
        grid: [
          singleUpper(0, 'SU1', reserved: true),
          singleLower(0, 'SL1'),
          doubleLower(0, 'DL1'),
        ],
      );
      // Geometry keeps it: the tile is drawn, so the walk knows about it.
      expect(idsOf(aisleOrder(withHold)), ['SU1', 'SL1', 'DL1']);

      // A lens that refuses to stop at a hold simply says so in its predicate.
      final walk = AisleWalk.of(withHold);
      expect(walk.next(matches: (c) => !c.reserved)?.seatId, 'SL1');
      expect(walk.count((c) => !c.reserved), 2);
    });

    test('cells with no seat id are still walked but never indexed', () {
      final unnamed = BusLayout(
        rows: 1,
        cols: SeatGridCols.count,
        grid: [
          singleUpper(0, 'SU1'),
          const SeatCell(
            row: 0,
            col: SeatGridCols.singleLower,
            seatType: SeatType.singleSofa,
            position: SeatPosition.lower,
          ),
        ],
      );
      final walk = AisleWalk.of(unnamed);
      expect(walk.length, 2);
      expect(walk.seatIds, ['SU1']); // no money or boarding can key to a blank
      expect(walk.indexOf(null), isNull);
      expect(walk.berthFor('SL1'), isNull);
    });

    test('cells with no seat type are not berths at all', () {
      final padded = BusLayout(
        rows: 1,
        cols: SeatGridCols.count,
        grid: [
          singleUpper(0, 'SU1'),
          const SeatCell(row: 0, col: SeatGridCols.aisle),
        ],
      );
      expect(idsOf(aisleOrder(padded)), ['SU1']);
    });
  });

  group('AisleWalk — locating yourself on the walk', () {
    final walk = AisleWalk.of(coach);

    test('seatIds is the walk, and indexOf is "you are here"', () {
      expect(walk.seatIds, coachWalk);
      expect(walk.indexOf('SU1'), 0);
      expect(walk.indexOf('DU1'), 3);
      expect(walk.indexOf('DU3'), 13);
      expect(walk.indexOf('nope'), isNull);
      expect(walk.indexOf(null), isNull);
    });

    test('berthFor returns the cell, with its geometry intact', () {
      final cell = walk.berthFor('DL3')!;
      expect(cell.row, 2);
      expect(cell.col, SeatGridCols.doubleLower);
      expect(cell.seatType, SeatType.doubleSofa);
      expect(cell.position, SeatPosition.lower);
    });

    test('where / count / firstMatching all read in walk order', () {
      final due = anyOf({'DU2', 'SL1', 'SU4'});
      expect(idsOf(walk.where(due)), ['SL1', 'DU2', 'SU4']);
      expect(walk.count(due), 3);
      expect(walk.firstMatching(due)?.seatId, 'SL1');
      expect(walk.firstMatching(anyOf({})), isNull);
    });
  });

  group('AisleWalk.next — the advance', () {
    final walk = AisleWalk.of(coach);
    // Three outstanding berths, deliberately scattered so an alphabetical or
    // insertion-order advance would visit them in a different sequence.
    final due = anyOf({'DU2', 'SL1', 'SU4'});

    test('with no current berth it starts the round at the front', () {
      expect(walk.next(matches: due)?.seatId, 'SL1');
      expect(walk.next(from: null, matches: due)?.seatId, 'SL1');
    });

    test('advances in walking order, skipping everything settled', () {
      expect(walk.next(from: 'SL1', matches: due)?.seatId, 'DU2');
      expect(walk.next(from: 'DU2', matches: due)?.seatId, 'SU4');
    });

    test('starting mid-bus wraps so the berths in front are not missed', () {
      // The handler was flagged down at DU2, dealt with SU4, and reached the
      // back. SL1 is still outstanding, up at row 0 — §4 promises it is found.
      expect(walk.next(from: 'SU4', matches: due)?.seatId, 'SL1');
    });

    test('wrap: false stops dead at the back of the bus', () {
      expect(walk.next(from: 'SU4', matches: due, wrap: false), isNull);
      // ...but still advances normally before the end.
      expect(walk.next(from: 'SL1', matches: due, wrap: false)?.seatId, 'DU2');
    });

    test('never hands back the berth you are standing at', () {
      final only = anyOf({'DL2'});
      expect(walk.next(from: 'DL2', matches: only), isNull);
      expect(walk.next(from: 'DL2', matches: only, wrap: false), isNull);
      // Even though that berth is genuinely still outstanding.
      expect(walk.count(only), 1);
    });

    test('the round empties as each berth is settled', () {
      final outstanding = {'SU1', 'SL2', 'DL3'};
      final visited = <String>[];
      String? at;
      // Completing an action clears the match, which is what terminates the
      // wrap instead of letting it spin forever.
      while (true) {
        final nxt = walk.next(from: at, matches: (c) => outstanding.contains(c.seatId));
        if (nxt == null) break;
        at = nxt.seatId;
        visited.add(at!);
        outstanding.remove(at);
      }
      expect(visited, ['SU1', 'SL2', 'DL3']);
      expect(outstanding, isEmpty);
    });

    test('a berth code from another bus is treated as "no current berth"', () {
      expect(walk.next(from: 'ZZ9', matches: due)?.seatId, 'SL1');
      expect(walk.next(from: '', matches: due)?.seatId, 'SL1');
    });

    test('nothing matches, or nothing exists, yields null', () {
      expect(walk.next(matches: anyOf({})), isNull);
      expect(AisleWalk.of(null).next(matches: (_) => true), isNull);
      expect(AisleWalk.of(null).previous(matches: (_) => true), isNull);
    });

    test('a bus with a single berth cannot advance off itself', () {
      final solo = AisleWalk.of(BusLayout(
        rows: 1,
        cols: SeatGridCols.count,
        grid: [singleUpper(0, 'SU1')],
      ));
      expect(solo.next(matches: (_) => true)?.seatId, 'SU1');
      expect(solo.next(from: 'SU1', matches: (_) => true), isNull);
      expect(solo.previous(from: 'SU1', matches: (_) => true), isNull);
    });
  });

  group('AisleWalk.previous — going back one', () {
    final walk = AisleWalk.of(coach);
    final due = anyOf({'DU2', 'SL1', 'SU4'});

    test('with no current berth it starts from the back', () {
      expect(walk.previous(matches: due)?.seatId, 'SU4');
    });

    test('steps toward the front', () {
      expect(walk.previous(from: 'SU4', matches: due)?.seatId, 'DU2');
      expect(walk.previous(from: 'DU2', matches: due)?.seatId, 'SL1');
    });

    test('wraps to the back, or stops at the front when told not to', () {
      expect(walk.previous(from: 'SL1', matches: due)?.seatId, 'SU4');
      expect(walk.previous(from: 'SL1', matches: due, wrap: false), isNull);
    });

    test('next and previous are inverses across the middle of the walk', () {
      expect(walk.next(from: 'SL1', matches: due)?.seatId, 'DU2');
      expect(walk.previous(from: 'DU2', matches: due)?.seatId, 'SL1');
    });
  });

  group('nextInAisleOrder — the one-shot helper', () {
    test('matches what an AisleWalk would say', () {
      final due = anyOf({'DU2', 'SL1'});
      expect(
        nextInAisleOrder(layout: coach, matches: due, from: 'SL1')?.seatId,
        'DU2',
      );
      expect(
        nextInAisleOrder(layout: coach, matches: due, from: 'DU2')?.seatId,
        'SL1', // wrapped
      );
      expect(
        nextInAisleOrder(
          layout: coach,
          matches: due,
          from: 'DU2',
          wrap: false,
        ),
        isNull,
      );
      expect(nextInAisleOrder(layout: null, matches: (_) => true), isNull);
    });
  });

  group('real generated layouts', () {
    /// The invariants that must hold for ANY bus the app can produce, checked
    /// against the actual generator rather than a hand-built grid.
    void assertWalkIsSane(BusLayout layout) {
      final walk = aisleOrder(layout);

      // 1. Every drawable tile is visited exactly once.
      expect(walk.length, layout.totalCells);
      expect(idsOf(walk).toSet().length, layout.totalCells);
      expect(idsOf(walk).toSet(), layout.allSeatIds.toSet());

      // 2. Rows only ever move toward the back.
      for (var i = 1; i < walk.length; i++) {
        expect(walk[i].row, greaterThanOrEqualTo(walk[i - 1].row));
      }

      // 3. Inside a row the sweep never doubles back — this is what stops the
      //    highlight jumping leftward across the screen on an auto-advance.
      const sweep = {
        SeatGridCols.singleUpper: 0,
        SeatGridCols.singleLower: 1,
        SeatGridCols.aisle: 2,
        SeatGridCols.doubleLower: 3,
        SeatGridCols.doubleUpper: 4,
      };
      for (var i = 1; i < walk.length; i++) {
        if (walk[i].row != walk[i - 1].row) continue;
        final a = sweep[walk[i - 1].col]!;
        final b = sweep[walk[i].col]!;
        if (a == b) {
          // Only the aisle repeats a column, and it goes upper then lower.
          expect(walk[i - 1].col, SeatGridCols.aisle);
          expect(walk[i - 1].position, SeatPosition.upper);
          expect(walk[i].position, SeatPosition.lower);
        } else {
          expect(b, greaterThan(a));
        }
      }
    }

    test('a 40-berth sleeper with singles and a designed back bench', () {
      final layout = BusLayout.generate(
        busType: BusType.sleeper,
        totalSeats: 40,
        singleSofaCount: 12,
      );
      assertWalkIsSane(layout);
      expect(aisleOrder(layout).first.row, 0);
    });

    test('an all-double back row parks a double pair in the aisle', () {
      final layout = BusLayout.generate(
        busType: BusType.sleeper,
        totalSeats: 44,
        allDoubleBackRow: true,
      );
      assertWalkIsSane(layout);
      final aisleBerths =
          aisleOrder(layout).where((c) => c.col == SeatGridCols.aisle).toList();
      expect(aisleBerths, isNotEmpty);
      // The bench is the LAST thing walked, as it is the back of the bus.
      expect(aisleBerths.first.row, layout.rows - 1);
    });

    test('a 74-berth coach — the big end of the range in the spec', () {
      assertWalkIsSane(BusLayout.generate(
        busType: BusType.sleeper,
        totalSeats: 74,
        singleSofaCount: 20,
      ));
    });

    test('a seater bus sweeps window → aisle → aisle → window', () {
      final layout =
          BusLayout.generate(busType: BusType.seater, totalSeats: 8);
      assertWalkIsSane(layout);
      // Codes are numbered col-ascending (ST3 at col 3, ST4 at col 4) but the
      // walk crosses the bus, so ST4 is passed before ST3.
      expect(idsOf(aisleOrder(layout)),
          ['ST1', 'ST2', 'ST4', 'ST3', 'ST5', 'ST6', 'ST8', 'ST7']);
    });

    test('a mixed bus walks the sleeper cabin before the seaters behind it', () {
      final layout = BusLayout.generate(
        busType: BusType.mixed,
        totalSeats: 30,
        seaterCount: 10,
        singleSofaCount: 6,
      );
      assertWalkIsSane(layout);
      final walk = aisleOrder(layout);
      final firstSeater = walk.indexWhere((c) => c.seatType == SeatType.seater);
      final lastSleeper =
          walk.lastIndexWhere((c) => c.seatType != SeatType.seater);
      expect(firstSeater, greaterThan(lastSleeper));
    });

    test('the advance covers every outstanding berth on a real coach, once',
        () {
      final layout = BusLayout.generate(
        busType: BusType.sleeper,
        totalSeats: 40,
        singleSofaCount: 12,
      );
      final walk = AisleWalk.of(layout);
      // Every fifth berth still owes money.
      final outstanding = <String>{
        for (var i = 0; i < walk.length; i += 5) walk.seatIds[i],
      };
      final expected = walk
          .where((c) => outstanding.contains(c.seatId))
          .map((c) => c.seatId)
          .toList();

      final visited = <String?>[];
      final left = {...outstanding};
      String? at;
      while (true) {
        final nxt = walk.next(from: at, matches: (c) => left.contains(c.seatId));
        if (nxt == null) break;
        at = nxt.seatId;
        visited.add(at);
        left.remove(at);
      }
      expect(visited, expected);
      expect(visited.length, outstanding.length);
      expect(left, isEmpty);
    });
  });
}
