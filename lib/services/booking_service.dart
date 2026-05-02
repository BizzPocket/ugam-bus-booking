import 'package:uuid/uuid.dart';
import '../models/booking.dart';
import '../models/booking_input.dart';
import '../models/payment_status.dart';
import '../models/booking_status.dart';
import '../models/age_group.dart';
import '../services/seat_allocator.dart';
import '../services/bus_service.dart';

class BookingService {
  final List<Booking> _bookings = [];
  final SeatAllocator _seatAllocator;

  BookingService({BusService? busService, SeatAllocator? seatAllocator})
      : _seatAllocator = seatAllocator ?? SeatAllocator(busService: busService);

  Booking createBooking(ParsedBookingInput input) {
    if (!input.validate()) {
      throw ArgumentError('Invalid booking input');
    }

    // Allocate seats
    final allocationResult = _seatAllocator.allocate(
      bookingId: const Uuid().v4(),
      seatCount: input.seatCount,
      seatTypes: input.seatTypes,
      ageGroup: input.ageGroup ?? AgeGroup.other,
    );

    if (!allocationResult.success) {
      throw Exception('Failed to allocate seats: ${allocationResult.remainingSeats} seats available');
    }

    final booking = Booking(
      id: const Uuid().v4(),
      customerName: input.customerName,
      mobileNumber: input.mobileNumber,
      busId: allocationResult.busId,
      seatNumbers: allocationResult.seatNumbers,
      seatTypes: input.seatTypes,
      ageGroup: input.ageGroup ?? AgeGroup.other,
      paymentStatus: PaymentStatus.notPaid,
      status: BookingStatus.confirmed,
    );

    _bookings.add(booking);
    return booking;
  }

  void cancelBooking(String bookingId) {
    final booking = _bookings.firstWhere((b) => b.id == bookingId);
    _bookings.remove(booking);
  }

  void updatePaymentStatus(String bookingId, PaymentStatus status) {
    final index = _bookings.indexWhere((b) => b.id == bookingId);
    if (index != -1) {
      _bookings[index] = _bookings[index].copyWith(paymentStatus: status);
    }
  }

  Booking? getBooking(String bookingId) {
    try {
      return _bookings.firstWhere((b) => b.id == bookingId);
    } catch (e) {
      return null;
    }
  }

  List<Booking> getBookingsByBus(String busId) {
    return _bookings.where((b) => b.busId == busId).toList();
  }

  List<Booking> getBookingsByCustomer(String name) {
    return _bookings
        .where((b) => b.customerName.toLowerCase().contains(name.toLowerCase()))
        .toList();
  }

  List<Booking> getBookingsByMobile(String mobile) {
    return _bookings.where((b) => b.mobileNumber?.contains(mobile) ?? false).toList();
  }

  List<Booking> getAllBookings() => List.unmodifiable(_bookings);
}