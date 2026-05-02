import 'seat_type.dart';
import 'age_group.dart';

class ParsedBookingInput {
  final String customerName;
  final int seatCount;
  final List<SeatType> seatTypes;
  final AgeGroup? ageGroup;
  final String? mobileNumber;
  /// Set when the input came from the standardized customer-mode
  /// WhatsApp booking message (Phase 4) — `UGM-XXXXXX`. Lets the admin
  /// match the request back to the right tour automatically.
  final String? tourCode;
  /// Optional free-text note included in the booking-request message.
  final String? note;

  ParsedBookingInput({
    required this.customerName,
    required this.seatCount,
    required this.seatTypes,
    this.ageGroup,
    this.mobileNumber,
    this.tourCode,
    this.note,
  });

  bool validate() {
    if (customerName.trim().isEmpty) return false;
    if (seatCount <= 0) return false;
    if (seatTypes.length != seatCount) return false;
    return true;
  }
}