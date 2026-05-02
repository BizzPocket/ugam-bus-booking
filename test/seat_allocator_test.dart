import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/services/seat_allocator.dart';
import 'package:occubusbooking/services/bus_service.dart';
import 'package:occubusbooking/models/seat_type.dart';
import 'package:occubusbooking/models/age_group.dart';

void main() {
  group('SeatAllocator Tests', () {
    test('Allocates seats successfully across bus', () {
      final busService = BusService();
      final allocator = SeatAllocator(busService: busService);

      final result = allocator.allocate(
        bookingId: 'test1',
        seatCount: 2,
        seatTypes: [SeatType.singleSofa, SeatType.doubleSofa],
        ageGroup: AgeGroup.young,
      );

      expect(result.success, true);
      expect(result.seatNumbers.length, 2);
      expect(result.partialAllocation, false);
      expect(result.busId, isNotEmpty);
    });
  });
}
