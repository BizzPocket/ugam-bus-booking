import 'package:get/get.dart';
import 'package:occubusbooking/models/payment_status.dart';
import '../models/booking.dart';
import '../models/booking_input.dart';
import '../services/booking_service.dart';
import '../utils/app_dialogs.dart';
import '../utils/app_snackbar.dart';

class BookingController extends GetxController {
  final bookings = <Booking>[].obs;
  final isLoading = false.obs;

  final BookingService _bookingService = Get.find<BookingService>();

  void createBooking(ParsedBookingInput input) {
    isLoading.value = true;
    try {
      final booking = _bookingService.createBooking(input);
      bookings.add(booking);
      AppSnackBar.success('Booking created successfully');
    } catch (e) {
      AppSnackBar.error('Failed to create booking: $e');
    } finally {
      isLoading.value = false;
    }
  }

  void updatePaymentStatus(String bookingId, PaymentStatus status) {
    _bookingService.updatePaymentStatus(bookingId, status);
    final index = bookings.indexWhere((b) => b.id == bookingId);
    if (index != -1) {
      bookings[index] = bookings[index].copyWith(
        paymentStatus: status,
        updatedAt: DateTime.now(),
      );
    }
  }

  Future<void> cancelBooking(String bookingId) async {
    final confirmed = await AppDialogs.confirm(
      title: 'Cancel Booking',
      message: 'Are you sure you want to cancel this booking? This action cannot be undone.',
      confirmText: 'Cancel Booking',
      isDestructive: true,
    );
    if (!confirmed) return;

    _bookingService.cancelBooking(bookingId);
    bookings.removeWhere((b) => b.id == bookingId);
    AppSnackBar.info('Booking has been cancelled');
  }

  List<Booking> getBookingsByBus(String busId) {
    return bookings.where((b) => b.busId == busId).toList();
  }

  List<Booking> searchByName(String query) {
    return bookings
        .where((b) => b.customerName.toLowerCase().contains(query.toLowerCase()))
        .toList();
  }

  List<Booking> searchByMobile(String query) {
    return bookings
        .where((b) => b.mobileNumber?.contains(query) ?? false)
        .toList();
  }
}