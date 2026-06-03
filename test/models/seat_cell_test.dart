import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/seat_layout.dart';
import 'package:occubusbooking/models/seat_type.dart';

void main() {
  group('SeatCell.reserved', () {
    test('defaults to false and is omitted from toMap when false', () {
      const c = SeatCell(
        row: 0, col: 0, seatType: SeatType.seater, seatId: 'ST1',
      );
      expect(c.reserved, isFalse);
      expect(c.toMap().containsKey('reserved'), isFalse);
    });

    test('serializes reserved=true and round-trips', () {
      const c = SeatCell(
        row: 0, col: 0, seatType: SeatType.seater, seatId: 'ST1', reserved: true,
      );
      expect(c.toMap()['reserved'], true);
      final back = SeatCell.fromMap(c.toMap());
      expect(back.reserved, isTrue);
      expect(back.seatId, 'ST1');
    });

    test('fromMap defaults reserved to false when key missing', () {
      final c = SeatCell.fromMap({'row': 1, 'col': 1});
      expect(c.reserved, isFalse);
    });

    test('equality/hashCode ignore reserved (identity is row,col,position)', () {
      const a = SeatCell(row: 2, col: 3, seatType: SeatType.doubleSofa,
          position: SeatPosition.upper, seatId: 'DU2');
      const b = SeatCell(row: 2, col: 3, seatType: SeatType.doubleSofa,
          position: SeatPosition.upper, seatId: 'DU2', reserved: true);
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
    });

    test('copyWith sets reserved', () {
      const c = SeatCell(row: 0, col: 0, seatType: SeatType.seater, seatId: 'ST1');
      expect(c.copyWith(reserved: true).reserved, isTrue);
    });
  });

  group('SeatCell.forward', () {
    test('defaults to false and is omitted from toMap when false', () {
      const c = SeatCell(
        row: 0, col: 0, seatType: SeatType.seater, seatId: 'ST1',
      );
      expect(c.forward, isFalse);
      expect(c.toMap().containsKey('forward'), isFalse);
    });

    test('serializes forward=true and round-trips', () {
      const c = SeatCell(
        row: 0, col: 0, seatType: SeatType.seater, seatId: 'ST1', forward: true,
      );
      expect(c.toMap()['forward'], true);
      final back = SeatCell.fromMap(c.toMap());
      expect(back.forward, isTrue);
      expect(back.seatId, 'ST1');
    });

    test('fromMap defaults forward to false when key missing', () {
      final c = SeatCell.fromMap({'row': 1, 'col': 1});
      expect(c.forward, isFalse);
    });

    test('equality/hashCode ignore forward (identity is row,col,position)', () {
      const a = SeatCell(row: 2, col: 3, seatType: SeatType.doubleSofa,
          position: SeatPosition.upper, seatId: 'DU2');
      const b = SeatCell(row: 2, col: 3, seatType: SeatType.doubleSofa,
          position: SeatPosition.upper, seatId: 'DU2', forward: true);
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
    });

    test('copyWith sets forward', () {
      const c = SeatCell(row: 0, col: 0, seatType: SeatType.seater, seatId: 'ST1');
      expect(c.copyWith(forward: true).forward, isTrue);
    });
  });

  group('BusLayout._regenerateIds preserves flags (regression)', () {
    test('forward + reserved survive an updateCell that re-numbers ids', () {
      // A layout with two flagged sofa cells. Adding an UNRELATED seat triggers
      // _regenerateIds; the flags on the untouched cells must survive.
      final layout = BusLayout(
        rows: 1,
        cols: SeatGridCols.count,
        grid: const [
          SeatCell(
            row: 0,
            col: SeatGridCols.singleUpper,
            seatType: SeatType.singleSofa,
            position: SeatPosition.upper,
            seatId: 'SU1',
            forward: true,
            reserved: true,
          ),
          SeatCell(
            row: 0,
            col: SeatGridCols.singleLower,
            seatType: SeatType.singleSofa,
            position: SeatPosition.lower,
            seatId: 'SL1',
            forward: true,
          ),
        ],
      );

      // Add an unrelated double-upper seat — forces re-numbering of all ids.
      final next = layout.updateCell(const SeatCell(
        row: 1,
        col: SeatGridCols.doubleUpper,
        seatType: SeatType.doubleSofa,
        position: SeatPosition.upper,
      ));

      SeatCell find(int row, int col, SeatPosition pos) =>
          next.cellAt(row, col, position: pos);

      final su = find(0, SeatGridCols.singleUpper, SeatPosition.upper);
      final sl = find(0, SeatGridCols.singleLower, SeatPosition.lower);
      expect(su.forward, isTrue, reason: 'forward must survive re-numbering');
      expect(su.reserved, isTrue, reason: 'reserved must survive re-numbering');
      expect(sl.forward, isTrue);
      expect(sl.reserved, isFalse);
    });

    test('forward flag set via copyWith survives the updateCell write', () {
      // Mark an existing cell forward via copyWith, then write it back. The
      // _regenerateIds pass inside updateCell must not drop the flag.
      final layout = BusLayout(
        rows: 1,
        cols: SeatGridCols.count,
        grid: const [
          SeatCell(
            row: 0,
            col: SeatGridCols.singleUpper,
            seatType: SeatType.singleSofa,
            position: SeatPosition.upper,
            seatId: 'SU1',
          ),
        ],
      );
      final marked = layout
          .cellAt(0, SeatGridCols.singleUpper, position: SeatPosition.upper)
          .copyWith(forward: true);
      final next = layout.updateCell(marked);

      final back =
          next.cellAt(0, SeatGridCols.singleUpper, position: SeatPosition.upper);
      expect(back.forward, isTrue,
          reason: 'the flag on the cell being written must persist');
    });
  });
}
