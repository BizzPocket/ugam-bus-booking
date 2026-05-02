import 'seat_type.dart';

class Bus {
  final String id;
  final String name;
  final int totalCapacity;
  final int currentBookings;
  final SeatConfiguration seatConfiguration;

  Bus({
    required this.id,
    required this.name,
    required this.totalCapacity,
    required this.seatConfiguration,
    this.currentBookings = 0,
  });

  int get availableSeats => totalCapacity - currentBookings;

  bool get isFull => currentBookings >= totalCapacity;

  int getAvailableSeatsByType(SeatType type) {
    switch (type) {
      case SeatType.singleSofa:
        return seatConfiguration.singleSofaUpper + seatConfiguration.singleSofaBottom - currentBookings;
      case SeatType.doubleSofa:
        return seatConfiguration.doubleSofaUpper + seatConfiguration.doubleSofaBottom - currentBookings;
    }
  }
}

class SeatConfiguration {
  final int singleSofaUpper;
  final int singleSofaBottom;
  final int doubleSofaUpper;
  final int doubleSofaBottom;

  SeatConfiguration({
    required this.singleSofaUpper,
    required this.singleSofaBottom,
    required this.doubleSofaUpper,
    required this.doubleSofaBottom,
  });

  int get totalSeats =>
      singleSofaUpper + singleSofaBottom + doubleSofaUpper + doubleSofaBottom;
}