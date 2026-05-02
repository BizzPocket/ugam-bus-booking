import '../models/booking.dart';
import '../models/payment_status.dart';
import '../models/seat_type.dart';

class ReportGenerator {
  final List<Booking> _bookings;

  ReportGenerator({List<Booking>? bookings}) : _bookings = bookings ?? [];

  BookingSummary generateBookingSummary() {
    final totalBookings = _bookings.length;
    final paidBookings = _bookings.where((b) => b.paymentStatus == PaymentStatus.paid).length;
    final pendingBookings = totalBookings - paidBookings;

    return BookingSummary(
      totalBookings: totalBookings,
      paidBookings: paidBookings,
      pendingBookings: pendingBookings,
      totalRevenue: 0, // Would calculate based on pricing
    );
  }

  List<SeatUtilization> generateSeatUtilization() {
    final busGroups = <String, List<Booking>>{};
    for (final booking in _bookings) {
      busGroups.putIfAbsent(booking.busId, () => []).add(booking);
    }

    return busGroups.entries.map((entry) {
      final busId = entry.key;
      final busBookings = entry.value;
      final totalBookedSeats = busBookings.fold(0, (sum, b) => sum + b.seatNumbers.length);

      return SeatUtilization(
        busId: busId,
        totalSeats: 0, // Would get from bus configuration
        bookedSeats: totalBookedSeats,
        utilizationPercentage: 0,
        totalByType: {},
        bookedByType: {},
      );
    }).toList();
  }

  String generateBusPassengerList(String busId) {
    final busBookings = _bookings.where((b) => b.busId == busId).toList();
    final buffer = StringBuffer();

    buffer.writeln('Passenger List for Bus: $busId');
    buffer.writeln('=' * 40);
    buffer.writeln('Total Passengers: ${busBookings.length}');
    buffer.writeln('');

    for (final booking in busBookings) {
      buffer.writeln('Name: ${booking.customerName}');
      if (booking.mobileNumber != null) {
        buffer.writeln('Mobile: ${booking.mobileNumber}');
      }
      buffer.writeln('Seats: ${booking.seatNumbers.join(', ')}');
      buffer.writeln('Status: ${booking.paymentStatus.displayName}');
      buffer.writeln('-' * 40);
    }

    return buffer.toString();
  }

  String exportToText(dynamic report) {
    return report.toString();
  }
}

class BookingSummary {
  final int totalBookings;
  final int paidBookings;
  final int pendingBookings;
  final double totalRevenue;

  BookingSummary({
    required this.totalBookings,
    required this.paidBookings,
    required this.pendingBookings,
    required this.totalRevenue,
  });
}

class SeatUtilization {
  final String busId;
  final int totalSeats;
  final int bookedSeats;
  final double utilizationPercentage;
  final Map<SeatType, int> totalByType;
  final Map<SeatType, int> bookedByType;

  SeatUtilization({
    required this.busId,
    required this.totalSeats,
    required this.bookedSeats,
    required this.utilizationPercentage,
    required this.totalByType,
    required this.bookedByType,
  });
}