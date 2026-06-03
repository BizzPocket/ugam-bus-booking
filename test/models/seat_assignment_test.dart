import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/seat_assignment.dart';

void main() {
  group('SeatAssignment.locked', () {
    test('defaults to false and is omitted from toMap when false', () {
      const a = SeatAssignment(busId: 'b1', seatId: 'DL3');
      expect(a.locked, isFalse);
      expect(a.toMap().containsKey('locked'), isFalse);
    });

    test('serializes locked=true and round-trips', () {
      const a = SeatAssignment(busId: 'b1', seatId: 'DL3', locked: true);
      expect(a.toMap()['locked'], true);
      final back = SeatAssignment.fromMap(a.toMap());
      expect(back.locked, isTrue);
    });

    test('fromMap defaults locked to false when key missing', () {
      final a = SeatAssignment.fromMap({'busId': 'b1', 'seatId': 'DL3'});
      expect(a.locked, isFalse);
    });

    test('equality and hashCode ignore locked (occupancy lookups must work)', () {
      const free = SeatAssignment(busId: 'b1', seatId: 'DL3');
      const locked = SeatAssignment(busId: 'b1', seatId: 'DL3', locked: true);
      expect(free, equals(locked));
      expect(free.hashCode, locked.hashCode);
      expect([free].contains(locked), isTrue);
    });

    test('copyWith toggles locked, keeps identity', () {
      const a = SeatAssignment(busId: 'b1', seatId: 'DL3');
      final b = a.copyWith(locked: true);
      expect(b.busId, 'b1');
      expect(b.seatId, 'DL3');
      expect(b.locked, isTrue);
    });
  });
}
