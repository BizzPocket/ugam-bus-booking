import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/bus_type.dart';
import 'package:occubusbooking/models/seat_layout.dart';
import 'package:occubusbooking/models/seat_type.dart';

void main() {
  group('BusLayout.generate — back-row toggle ON (all double)', () {
    BusLayout gen(int n, {int singles = 0}) => BusLayout.generate(
          busType: BusType.sleeper,
          totalSeats: n,
          singleSofaCount: singles,
          allDoubleBackRow: true,
        );

    test('last row is 4 double sofas, aisle is a double pair', () {
      final l = gen(40);
      expect(l.totalSeats, 40);
      final backRow = l.rows - 1;
      final back = l.grid.where((c) => c.row == backRow && c.hasSeat).toList();
      expect(back.where((c) => c.seatType == SeatType.doubleSofa).length, 4,
          reason: '4 doubles in the back row');
      expect(back.where((c) => c.seatType == SeatType.singleSofa), isEmpty);
      final pair = l.balconyPair(backRow);
      expect(pair.upper.seatType, SeatType.doubleSofa);
      expect(pair.lower.seatType, SeatType.doubleSofa);
      // All-double bus: zero singles anywhere, 20 double sofas.
      expect(l.grid.where((c) => c.seatType == SeatType.singleSofa), isEmpty);
      expect(l.grid.where((c) => c.seatType == SeatType.doubleSofa).length, 20);
    });

    test('requested singles fill the front, never the all-double back row', () {
      final l = gen(14, singles: 6);
      final backRow = l.rows - 1;
      expect(
          l.grid.where((c) =>
              c.row == backRow && c.seatType == SeatType.singleSofa),
          isEmpty,
          reason: 'all-double back row holds no single');
      expect(l.grid.where((c) => c.seatType == SeatType.singleSofa).length, 6);
      expect(l.totalSeats, 14);
    });

    test('applies for any length, count conserved', () {
      for (final n in [20, 21, 36, 37, 51]) {
        final l = gen(n);
        expect(l.totalSeats, n, reason: 'n=$n conserved');
        final back = l.grid.where((c) => c.row == l.rows - 1 && c.hasSeat);
        expect(back.where((c) => c.seatType == SeatType.doubleSofa).length, 4,
            reason: 'n=$n back row 4 doubles');
        expect(back.where((c) => c.seatType == SeatType.singleSofa), isEmpty,
            reason: 'n=$n no single in back row');
      }
    });
  });

  group('BusLayout.generate — back-row toggle OFF (3 single + 2 double)', () {
    test('the 37 / 13-single example: back 3S+2D drawn from 13S + 12D total', () {
      // 37 seats, 13 single sofas → 12 doubles. The back row's 3 single + 2
      // double are DRAWN FROM that composition (not added), so the totals stay
      // exactly 13 singles + 12 doubles.
      final l = BusLayout.generate(
        busType: BusType.sleeper,
        totalSeats: 37,
        singleSofaCount: 13,
      );
      expect(l.totalSeats, 37);
      expect(l.grid.where((c) => c.seatType == SeatType.singleSofa).length, 13,
          reason: 'no extra singles added');
      expect(l.grid.where((c) => c.seatType == SeatType.doubleSofa).length, 12);

      final back = l.grid.where((c) => c.row == l.rows - 1 && c.hasSeat).toList();
      final backSingles =
          back.where((c) => c.seatType == SeatType.singleSofa).toList();
      final backDoubles =
          back.where((c) => c.seatType == SeatType.doubleSofa).toList();
      expect(backSingles.length, 3, reason: '3 single sofas');
      expect(backDoubles.length, 2, reason: '2 double sofas');
      // Singles on the left (single lanes + aisle), doubles on the right.
      expect(backSingles.every((c) => c.col <= SeatGridCols.aisle), isTrue);
      expect(
          backDoubles.every((c) =>
              c.col == SeatGridCols.doubleUpper ||
              c.col == SeatGridCols.doubleLower),
          isTrue);
    });

    test('OFF back row is 3S+2D when 3S+2D keeps the body EVEN (hole-free)', () {
      // The designed 3S+2D bench is honoured only when, after carving it, BOTH
      // body lane pairs stay even — i.e. an ODD single count AND an EVEN double
      // count (ts-3 even, td-2 even). 41/13 (ts=13 odd, td=14 even) qualifies.
      for (final cfg in [(n: 41, s: 13), (n: 37, s: 13)]) {
        final l = BusLayout.generate(
          busType: BusType.sleeper,
          totalSeats: cfg.n,
          singleSofaCount: cfg.s,
        );
        expect(l.totalSeats, cfg.n, reason: 'n=${cfg.n} conserved');
        // Total singles is exactly what was requested (no fabricated extras).
        expect(
            l.grid.where((c) => c.seatType == SeatType.singleSofa).length, cfg.s,
            reason: 'n=${cfg.n} keeps ${cfg.s} singles');
        final back = l.grid.where((c) => c.row == l.rows - 1 && c.hasSeat);
        expect(back.where((c) => c.seatType == SeatType.singleSofa).length, 3,
            reason: 'n=${cfg.n} back row 3 singles');
        expect(back.where((c) => c.seatType == SeatType.doubleSofa).length, 2,
            reason: 'n=${cfg.n} back row 2 doubles');
      }
    });

    test('OFF drops to a hole-free minimal bench when 3S+2D would leave a hole',
        () {
      // 38/8 (ts=8 even, td=15 odd) and 50/8: carving the designed 3S+2D bench
      // would leave the body ODD on BOTH sides (5S+13D) → a stranded tile + a
      // half-empty bunk, which is exactly the hole that reached the WhatsApp PDF.
      // So the bench drops back to the minimal aisle bench that just parks the
      // one odd double, keeping every lane pair even and the chart hole-free.
      List<int> laneRows(BusLayout l, int col) =>
          (l.grid.where((c) => c.col == col && c.hasSeat).map((c) => c.row)
                .toSet().toList()
            ..sort());
      for (final n in [38, 50]) {
        final l = BusLayout.generate(
          busType: BusType.sleeper,
          totalSeats: n,
          singleSofaCount: 8,
        );
        expect(l.totalSeats, n, reason: 'n=$n conserved');
        expect(l.grid.where((c) => c.seatType == SeatType.singleSofa).length, 8,
            reason: 'n=$n keeps 8 singles');
        // Every lane pair is balanced row-for-row → no stranded tile.
        expect(laneRows(l, SeatGridCols.singleUpper),
            laneRows(l, SeatGridCols.singleLower),
            reason: 'n=$n single lane balanced');
        expect(laneRows(l, SeatGridCols.doubleUpper),
            laneRows(l, SeatGridCols.doubleLower),
            reason: 'n=$n double lane balanced');
        // The lone odd double is parked in the aisle, not stranded in a lane.
        final aisle = l.grid.where((c) =>
            c.col == SeatGridCols.aisle && c.hasSeat);
        expect(aisle.length, 1, reason: 'n=$n one aisle odd-tail berth');
        expect(aisle.first.seatType, SeatType.doubleSofa);
      }
    });

    test('a perfectly-pairable bus has NO rear bench, just clean rows', () {
      // When both the single and double cell counts are even the bus lays flat
      // into full [single | double] rows with no leftover, so no bench is carved
      // (matches a 36-seat / 12-single coach with no gallery). This used to leave
      // a hole in the last body row (body 9S+10D → singleLower one short).
      int colCount(BusLayout l, int col) =>
          l.grid.where((c) => c.col == col && c.hasSeat).length;

      for (final cfg in [
        (n: 20, singles: 8), // 8S + 6D, both even
        (n: 36, singles: 12), // 12S + 12D, both even
        (n: 40, singles: 8), // 8S + 16D, both even
      ]) {
        final l = BusLayout.generate(
          busType: BusType.sleeper,
          totalSeats: cfg.n,
          singleSofaCount: cfg.singles,
        );
        expect(l.totalSeats, cfg.n, reason: 'n=${cfg.n} conserved');
        // No bench: nothing lives in the aisle column.
        expect(l.grid.where((c) => c.col == SeatGridCols.aisle && c.hasSeat),
            isEmpty,
            reason: 'n=${cfg.n} has no rear bench');
        expect(l.hasBalcony, isFalse, reason: 'n=${cfg.n} no balcony/bench');
        // Each lane's upper and lower halves are equal → no holes.
        expect(colCount(l, SeatGridCols.singleUpper),
            colCount(l, SeatGridCols.singleLower),
            reason: 'n=${cfg.n} single lane balanced');
        expect(colCount(l, SeatGridCols.doubleUpper),
            colCount(l, SeatGridCols.doubleLower),
            reason: 'n=${cfg.n} double lane balanced');
      }

      // The headline case: 36 / 12 → exactly 6 clean rows, no bench.
      final l = BusLayout.generate(
        busType: BusType.sleeper,
        totalSeats: 36,
        singleSofaCount: 12,
      );
      expect(l.rows, 6, reason: '36/12 → six full rows');
      expect(l.grid.where((c) => c.seatType == SeatType.singleSofa).length, 12);
      expect(l.grid.where((c) => c.seatType == SeatType.doubleSofa).length, 12);
    });

    test('OFF never fabricates singles: an all-double bus stays all double', () {
      // No requested singles → OFF cannot make a 3-single back row, so it does
      // NOT invent any singles; the bus stays entirely double.
      final l = BusLayout.generate(busType: BusType.sleeper, totalSeats: 40);
      expect(l.totalSeats, 40);
      expect(l.grid.where((c) => c.seatType == SeatType.singleSofa), isEmpty);
      expect(l.grid.where((c) => c.seatType == SeatType.doubleSofa).length, 20);
    });

    test('back-row singles come OUT of the requested count, not on top', () {
      // 41/13 carves the designed 3S+2D bench (ts=13 odd, td=14 even keeps the
      // body even). The 3 back-row singles must be DRAWN FROM the 13 requested —
      // never fabricated on top — so 10 sit up front.
      final l = BusLayout.generate(
        busType: BusType.sleeper,
        totalSeats: 41,
        singleSofaCount: 13,
      );
      expect(l.totalSeats, 41);
      // Exactly 13 singles total: 3 in the back row, 10 up front — none added.
      expect(l.grid.where((c) => c.seatType == SeatType.singleSofa).length, 13);
      final backRow = l.rows - 1;
      final frontSingles = l.grid.where((c) =>
          c.row < backRow && c.seatType == SeatType.singleSofa);
      expect(frontSingles.length, 10);
      for (final c in frontSingles) {
        expect(
            c.col == SeatGridCols.singleUpper ||
                c.col == SeatGridCols.singleLower,
            isTrue);
      }
    });
  });

  group('BusLayout.generate — no ragged mid-cabin holes (36/37/38 sweep)', () {
    // Rows occupied in a given lane column, sorted ascending.
    List<int> laneRows(BusLayout l, int col) =>
        (l.grid.where((c) => c.col == col && c.hasSeat).map((c) => c.row).toSet()
              .toList()
          ..sort());

    // A lane column is "contiguous" when there is no empty interior row between
    // its first and last filled rows — i.e. no hole sits ABOVE a filled row in
    // the SAME lane (the rendered mid-cabin gap we are hunting).
    bool contiguous(List<int> rows) {
      if (rows.length < 2) return true;
      return rows.last - rows.first == rows.length - 1;
    }

    // The default (customer-facing) path is the OFF back row. There the layout
    // must be FULLY hole-free: every lane pair balanced AND contiguous, so the
    // WhatsApp PDF never shows a stranded mid-cabin tile or a half-empty bunk.
    for (final n in [36, 37, 38]) {
      for (final singles in [0, 1, 2, 3]) {
        test('OFF n=$n singles=$singles — paired & hole-free', () {
          final l = BusLayout.generate(
            busType: BusType.sleeper,
            totalSeats: n,
            singleSofaCount: singles,
          );

          // (a) Berth count is EXACTLY conserved — the invariant we must keep.
          expect(l.totalSeats, n,
              reason: 'berth count must stay conserved (n=$n)');

          final c0 = laneRows(l, SeatGridCols.singleUpper);
          final c1 = laneRows(l, SeatGridCols.singleLower);
          final c3 = laneRows(l, SeatGridCols.doubleUpper);
          final c4 = laneRows(l, SeatGridCols.doubleLower);

          // (b1) No interior hole: every lane column is filled contiguously, so
          // there is never a blank cell ABOVE a filled cell in the same lane.
          expect(contiguous(c0), isTrue,
              reason: 'singleUpper lane has a mid-cabin hole: $c0');
          expect(contiguous(c1), isTrue,
              reason: 'singleLower lane has a mid-cabin hole: $c1');
          expect(contiguous(c3), isTrue,
              reason: 'doubleUpper lane has a mid-cabin hole: $c3');
          expect(contiguous(c4), isTrue,
              reason: 'doubleLower lane has a mid-cabin hole: $c4');

          // (b2) No unpaired tail: within each SIDE the upper and lower columns
          // occupy exactly the SAME rows, so no tile floats with a blank partner
          // beside it. Every odd-tail berth (the 38/0 odd double, the 37-series
          // odd single) lives in the AISLE column, never in cols 0/1/3/4 — so the
          // lane pairs stay perfectly balanced.
          expect(c0, c1,
              reason: 'single side unpaired (upper $c0 vs lower $c1)');
          expect(c3, c4,
              reason: 'double side unpaired (upper $c3 vs lower $c4)');
        });
      }
    }

    // The all-double back row (toggle ON) is a deliberate product shape: the LAST
    // row is always 4 double sofas. For an EVEN double-cell count that lays out
    // fully paired; for an ODD count one trailing half-bunk is unavoidable while
    // honouring the 4-double back row (the toggle's whole point). So here we only
    // require: count conserved, the single side never invents/strands a tile, and
    // the 4-double back row is intact — never a *single*-side mid-cabin hole.
    for (final n in [36, 37, 38]) {
      for (final singles in [0, 1, 2, 3]) {
        test('ON n=$n singles=$singles — conserved, single side clean', () {
          final l = BusLayout.generate(
            busType: BusType.sleeper,
            totalSeats: n,
            singleSofaCount: singles,
            allDoubleBackRow: true,
          );
          expect(l.totalSeats, n, reason: 'conserved (n=$n)');

          final c0 = laneRows(l, SeatGridCols.singleUpper);
          final c1 = laneRows(l, SeatGridCols.singleLower);
          expect(contiguous(c0), isTrue, reason: 'singleUpper hole: $c0');
          expect(contiguous(c1), isTrue, reason: 'singleLower hole: $c1');

          // 4-double back row guarantee (when the bus has ≥4 doubles, which all
          // 36/37/38 buses do): the last row carries 4 double sofas, no singles.
          final back = l.grid.where((c) => c.row == l.rows - 1 && c.hasSeat);
          expect(back.where((c) => c.seatType == SeatType.doubleSofa).length, 4,
              reason: 'n=$n ON last row must be 4 doubles');
          expect(back.where((c) => c.seatType == SeatType.singleSofa), isEmpty,
              reason: 'n=$n ON last row holds no single');
        });
      }
    }
  });

  group('BusLayout.generate — column placement', () {
    test('seater fills cols 0,1,3,4 and never the aisle', () {
      final l = BusLayout.generate(busType: BusType.seater, totalSeats: 40);
      expect(l.totalSeats, 40);
      expect(l.grid.every((c) => c.col != SeatGridCols.aisle), isTrue);
      expect(l.grid.every((c) => c.seatType == SeatType.seater), isTrue);
      expect(l.grid.every((c) => c.position == null), isTrue);
    });

    test('mixed puts seaters below the sleeper rows', () {
      final l = BusLayout.generate(
        busType: BusType.mixed,
        totalSeats: 30,
        seaterCount: 6,
      );
      final sleeperMaxRow = l.grid
          .where((c) => c.seatType != SeatType.seater)
          .map((c) => c.row)
          .fold<int>(-1, (m, v) => v > m ? v : m);
      final seaterMinRow = l.grid
          .where((c) => c.seatType == SeatType.seater)
          .map((c) => c.row)
          .fold<int>(1 << 30, (m, v) => v < m ? v : m);
      expect(seaterMinRow, greaterThan(sleeperMaxRow));
      expect(l.totalSeats, 30);
    });
  });

  group('seat ids', () {
    test('ids are unique and prefixed by type+position', () {
      final l = BusLayout.generate(
        busType: BusType.sleeper,
        totalSeats: 30,
        singleSofaCount: 10,
      );
      final ids = l.allSeatIds;
      expect(ids.toSet().length, ids.length, reason: 'duplicate seat id');
      expect(ids.where((id) => id.startsWith('DU')).isNotEmpty, isTrue);
      expect(ids.where((id) => id.startsWith('SU') || id.startsWith('SL')).isNotEmpty,
          isTrue);
    });
  });

  group('serialisation round-trip', () {
    test('toMap/fromMap preserves seats and balcony', () {
      final l = BusLayout.generate(
        busType: BusType.sleeper,
        totalSeats: 20,
        singleSofaCount: 4,
        hasBalcony: true,
      );
      final restored = BusLayout.fromMap(l.toMap());
      expect(restored.totalSeats, l.totalSeats);
      expect(restored.hasBalcony, l.hasBalcony);
      expect(restored.allSeatIds.toSet(), l.allSeatIds.toSet());
    });
  });

  group('legacy two-deck migration', () {
    test('converts old format and preserves seat ids', () {
      // Old format: lowerDeck/upperDeck grids, cols=4 (single col0, aisle col1,
      // doubles col2/3). Assignments out there reference these ids.
      final legacy = {
        'rows': 2,
        'cols': 4,
        'lowerDeck': [
          {'row': 0, 'col': 0, 'seatType': 'singleSofa', 'position': 'lower', 'seatId': 'SL1'},
          {'row': 0, 'col': 2, 'seatType': 'doubleSofa', 'position': 'lower', 'seatId': 'DL1'},
          {'row': 0, 'col': 3, 'seatType': 'doubleSofa', 'position': 'lower', 'seatId': 'DL2'},
        ],
        'upperDeck': [
          {'row': 0, 'col': 0, 'seatType': 'singleSofa', 'position': 'upper', 'seatId': 'SU1'},
          {'row': 0, 'col': 2, 'seatType': 'doubleSofa', 'position': 'upper', 'seatId': 'DU1'},
        ],
      };
      final l = BusLayout.fromMap(legacy);

      // All original ids survive (assignments stay valid).
      expect(l.allSeatIds.toSet(), {'SL1', 'DL1', 'DL2', 'SU1', 'DU1'});
      // Capacity: 1 single-lower + 2 doubles(x2) + 1 single-upper + 1 double(x2)
      // = 1 + 4 + 1 + 2 = 8 berths.
      expect(l.totalSeats, 8);
      // Singles landed in the single lane, doubles in the double lane.
      final single = l.grid.firstWhere((c) => c.seatId == 'SU1');
      expect(single.col, SeatGridCols.singleUpper);
      final dbl = l.grid.firstWhere((c) => c.seatId == 'DL1');
      expect(dbl.col, SeatGridCols.doubleLower);
    });
  });

  group('updateCell', () {
    test('clearing then replacing the aisle pair toggles hasBalcony', () {
      // An all-double back row puts a double pair in the aisle from the start.
      var l = BusLayout.generate(
        busType: BusType.sleeper,
        totalSeats: 10,
        allDoubleBackRow: true,
      );
      final benchRow = l.rows - 1;
      expect(l.hasBalcony, isTrue);
      expect(l.balconyPair(benchRow).upper.hasSeat, isTrue);
      expect(l.balconyPair(benchRow).lower.hasSeat, isTrue);

      // Clear both aisle berths — the only aisle cells in the layout.
      l = l.updateCell(SeatCell(
          row: benchRow, col: SeatGridCols.aisle, position: SeatPosition.upper));
      l = l.updateCell(SeatCell(
          row: benchRow, col: SeatGridCols.aisle, position: SeatPosition.lower));
      expect(l.hasBalcony, isFalse);

      // Place one back — hasBalcony flips on again.
      l = l.updateCell(SeatCell(
        row: benchRow,
        col: SeatGridCols.aisle,
        seatType: SeatType.doubleSofa,
        position: SeatPosition.lower,
      ));
      expect(l.hasBalcony, isTrue);
    });
  });
}
