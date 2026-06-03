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
}
