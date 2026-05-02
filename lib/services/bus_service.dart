import '../models/bus.dart';
import '../models/seat_type.dart';

class BusService {
  final List<Bus> _buses = [];

  Bus configureBus(String id, String name, SeatConfiguration config) {
    final bus = Bus(
      id: id,
      name: name,
      totalCapacity: config.totalSeats,
      seatConfiguration: config,
    );
    _buses.add(bus);
    return bus;
  }

  Bus? getBus(String busId) {
    try {
      return _buses.firstWhere((b) => b.id == busId);
    } catch (e) {
      return null;
    }
  }

  List<Bus> getAllBuses() => List.unmodifiable(_buses);

  BusStatus getBusStatus(String busId) {
    final bus = getBus(busId);
    if (bus == null) {
      throw Exception('Bus not found: $busId');
    }

    final availableByType = {
      SeatType.singleSofa: bus.getAvailableSeatsByType(SeatType.singleSofa),
      SeatType.doubleSofa: bus.getAvailableSeatsByType(SeatType.doubleSofa),
    };

    return BusStatus(
      busId: bus.id,
      availableSeats: bus.availableSeats,
      bookedSeats: bus.currentBookings,
      utilizationPercentage: bus.totalCapacity > 0
          ? (bus.currentBookings / bus.totalCapacity) * 100
          : 0,
      availableByType: availableByType,
    );
  }

  int getAvailableSeats(String busId, SeatType seatType) {
    final bus = getBus(busId);
    if (bus == null) return 0;
    return bus.getAvailableSeatsByType(seatType);
  }

  bool isBusFull(String busId) {
    final bus = getBus(busId);
    return bus?.isFull ?? true;
  }

  List<Bus> getAvailableBuses() {
    return _buses.where((b) => !b.isFull).toList();
  }
}

class BusStatus {
  final String busId;
  final int availableSeats;
  final int bookedSeats;
  final double utilizationPercentage;
  final Map<SeatType, int> availableByType;

  BusStatus({
    required this.busId,
    required this.availableSeats,
    required this.bookedSeats,
    required this.utilizationPercentage,
    required this.availableByType,
  });
}