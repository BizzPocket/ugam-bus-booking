import 'package:occubusbooking/models/bus.dart';

import '../models/seat_type.dart';
import '../models/age_group.dart';
import '../services/bus_service.dart';

class SeatAllocator {
  final BusService _busService;

  SeatAllocator({BusService? busService}) : _busService = busService ?? BusService();

  SeatAllocationResult allocate({
    required String bookingId,
    required int seatCount,
    required List<SeatType> seatTypes,
    required AgeGroup ageGroup,
    bool preferContiguous = true,
  }) {
    final availableBuses = _busService.getAvailableBuses();

    if (availableBuses.isEmpty) {
      return SeatAllocationResult(
        success: false,
        busId: '',
        seatNumbers: [],
        partialAllocation: false,
        remainingSeats: seatCount,
      );
    }

    // Try to find a single bus with enough seats
    for (final bus in availableBuses) {
      final availableSeats = _countAvailableSeats(bus, seatTypes);
      if (availableSeats >= seatCount) {
        final seatNumbers = _allocateSeats(bus, seatCount, seatTypes, ageGroup);
        return SeatAllocationResult(
          success: true,
          busId: bus.id,
          seatNumbers: seatNumbers,
          partialAllocation: false,
        );
      }
    }

    // Partial allocation on first available bus
    final firstBus = availableBuses.first;
    final availableSeats = _countAvailableSeats(firstBus, seatTypes);
    final seatNumbers = _allocateSeats(firstBus, availableSeats, seatTypes, ageGroup);

    return SeatAllocationResult(
      success: true,
      busId: firstBus.id,
      seatNumbers: seatNumbers,
      partialAllocation: true,
      remainingSeats: seatCount - availableSeats,
    );
  }

  int _countAvailableSeats(Bus bus, List<SeatType> seatTypes) {
    int count = 0;
    for (final type in seatTypes) {
      count += bus.getAvailableSeatsByType(type);
    }
    return count;
  }

  List<String> _allocateSeats(
    Bus bus,
    int seatCount,
    List<SeatType> seatTypes,
    AgeGroup ageGroup,
  ) {
    final seatNumbers = <String>[];

    // Apply age-based position preference

    for (int i = 0; i < seatCount && i < seatTypes.length; i++) {
      final type = seatTypes[i];
      // Simplified seat allocation with position preference $preferredPosition
      seatNumbers.add('${i + 1}${type == SeatType.singleSofa ? 'A' : 'B'}');
    }

    return seatNumbers;
  }
}

enum SeatPosition { upper, bottom, any }

class SeatAllocationResult {
  final bool success;
  final String busId;
  final List<String> seatNumbers;
  final bool partialAllocation;
  final int? remainingSeats;

  SeatAllocationResult({
    required this.success,
    required this.busId,
    required this.seatNumbers,
    this.partialAllocation = false,
    this.remainingSeats,
  });
}