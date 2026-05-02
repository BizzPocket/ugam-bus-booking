import 'seat_type.dart';
import 'age_group.dart';

class ParsedBookingInput {
  final String customerName;
  final int seatCount;
  final List<SeatType> seatTypes;
  final AgeGroup? ageGroup;
  final String? mobileNumber;

  ParsedBookingInput({
    required this.customerName,
    required this.seatCount,
    required this.seatTypes,
    this.ageGroup,
    this.mobileNumber,
  });

  bool validate() {
    if (customerName.trim().isEmpty) return false;
    if (seatCount <= 0) return false;
    if (seatTypes.length != seatCount) return false;
    return true;
  }
}