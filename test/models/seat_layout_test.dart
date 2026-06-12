import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/bus_type.dart';
import 'package:occubusbooking/models/seat_layout.dart';
import 'package:occubusbooking/models/seat_type.dart';

void main() {
  group('BusLayout.generate — column placement', () {
    test('sleeper all-double places doubles in cols 3/4, none in 0/1', () {
      final l = BusLayout.generate(busType: BusType.sleeper, totalSeats: 40);
      // 40 berths, all doubles => 20 double sofas (each seats 2).
      expect(l.totalSeats, 40);
      expect(l.grid.where((c) => c.seatType == SeatType.doubleSofa).length, 20);
      for (final c in l.grid) {
        expect(c.col == SeatGridCols.doubleUpper || c.col == SeatGridCols.doubleLower,
            isTrue,
            reason: 'double cell at unexpected col ${c.col}');
      }
    });

    test('sleeper with singles uses single lane cols 0/1', () {
      final l = BusLayout.generate(
        busType: BusType.sleeper,
        totalSeats: 30,
        singleSofaCount: 10,
      );
      final singles = l.grid.where((c) => c.seatType == SeatType.singleSofa);
      expect(singles.length, 10);
      for (final c in singles) {
        expect(c.col == SeatGridCols.singleUpper || c.col == SeatGridCols.singleLower,
            isTrue);
      }
      // 30 - 10 singles = 20 double-berths = 10 double sofas. Total 10 + 20 = 30.
      expect(l.totalSeats, 30);
    });

    test('odd leftover berth becomes an extra single, no seat lost', () {
      // 21 sleeper, 0 requested singles => 21 double-berths is odd => 1 single.
      final l = BusLayout.generate(busType: BusType.sleeper, totalSeats: 21);
      expect(l.totalSeats, 21);
      expect(l.grid.where((c) => c.seatType == SeatType.singleSofa).length, 1);
      expect(l.grid.where((c) => c.seatType == SeatType.doubleSofa).length, 10);
    });

    test('unpaired single joins the last row as a full-width back bench', () {
      // 37 seats, 13 singles (odd) => 12 doubles. The 13th single can't pair in
      // the lane, so it rides the aisle column of the LAST seat row — merged into
      // a full-width back bench, never an appended aisle-only line.
      final l = BusLayout.generate(
        busType: BusType.sleeper,
        totalSeats: 37,
        singleSofaCount: 13,
      );
      final laneSingles = l.grid.where((c) =>
          c.seatType == SeatType.singleSofa && c.col != SeatGridCols.aisle);
      final aisleSingles = l.grid.where((c) =>
          c.seatType == SeatType.singleSofa && c.col == SeatGridCols.aisle);
      expect(laneSingles.length, 12, reason: 'lanes hold an even count');
      expect(aisleSingles.length, 1, reason: 'one orphan in the aisle');
      // The orphan sits in the very last row (the back bench), lower slot.
      final orphan = aisleSingles.single;
      expect(orphan.row, l.rows - 1);
      expect(orphan.position, SeatPosition.lower);
      expect(orphan.seatId, 'SL7');
      expect(l.hasBalcony, isTrue);
      // The bench is a real full-width row: the orphan shares its line with lane
      // berths rather than dangling alone on an appended row.
      final benchRowCells =
          l.grid.where((c) => c.row == orphan.row && c.hasSeat);
      expect(benchRowCells.any((c) => c.col != SeatGridCols.aisle), isTrue,
          reason: 'back bench is a full row, not an aisle-only line');
      expect(l.grid.where((c) => c.seatType == SeatType.singleSofa).length, 13);
      expect(l.grid.where((c) => c.seatType == SeatType.doubleSofa).length, 12);
      expect(l.totalSeats, 37);
    });

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

  group('BusLayout.generate — balcony', () {
    test('balcony adds an upper+lower pair in the aisle of the last row', () {
      final l = BusLayout.generate(
        busType: BusType.sleeper,
        totalSeats: 20,
        hasBalcony: true,
      );
      expect(l.hasBalcony, isTrue);
      final pair = l.balconyPair(l.rows - 1);
      expect(pair.upper.hasSeat, isTrue);
      expect(pair.lower.hasSeat, isTrue);
      expect(pair.upper.col, SeatGridCols.aisle);
      expect(pair.lower.col, SeatGridCols.aisle);
      expect(pair.upper.position, SeatPosition.upper);
      expect(pair.lower.position, SeatPosition.lower);
      // The pair shares the last row with lane berths — a full-width back bench,
      // not a dedicated aisle-only line.
      expect(
        l.grid.any((c) =>
            c.row == l.rows - 1 && c.hasSeat && c.col != SeatGridCols.aisle),
        isTrue,
      );
      // 20 lane berths + 2 balcony berths.
      expect(l.totalSeats, 22);
    });

    test('seater bus ignores the balcony flag', () {
      final l = BusLayout.generate(
        busType: BusType.seater,
        totalSeats: 20,
        hasBalcony: true,
      );
      expect(l.hasBalcony, isFalse);
      expect(l.grid.any((c) => c.isBalconyAisle), isFalse);
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
    test('placing then clearing a balcony pair toggles hasBalcony', () {
      var l = BusLayout.generate(busType: BusType.sleeper, totalSeats: 10);
      final balconyRow = l.rows; // a fresh row past the cabin
      l = l.updateCell(SeatCell(
        row: balconyRow,
        col: SeatGridCols.aisle,
        seatType: SeatType.singleSofa,
        position: SeatPosition.upper,
      ));
      l = l.updateCell(SeatCell(
        row: balconyRow,
        col: SeatGridCols.aisle,
        seatType: SeatType.singleSofa,
        position: SeatPosition.lower,
      ));
      expect(l.hasBalcony, isTrue);
      expect(l.balconyPair(balconyRow).upper.hasSeat, isTrue);
      expect(l.balconyPair(balconyRow).lower.hasSeat, isTrue);

      // Clear both.
      l = l.updateCell(SeatCell(row: balconyRow, col: SeatGridCols.aisle, position: SeatPosition.upper));
      l = l.updateCell(SeatCell(row: balconyRow, col: SeatGridCols.aisle, position: SeatPosition.lower));
      expect(l.hasBalcony, isFalse);
    });
  });
}
