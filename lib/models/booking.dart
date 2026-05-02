import 'package:uuid/uuid.dart';
import 'seat_type.dart';
import 'age_group.dart';
import 'payment_status.dart';
import 'booking_status.dart';

class Booking {
  final String id;
  final String customerName;
  final String? mobileNumber;
  final String busId;
  final List<String> seatNumbers;
  final List<SeatType> seatTypes;
  final AgeGroup ageGroup;
  final PaymentStatus paymentStatus;
  final BookingStatus status;
  final DateTime createdAt;
  final DateTime updatedAt;

  Booking({
    String? id,
    required this.customerName,
    this.mobileNumber,
    required this.busId,
    required this.seatNumbers,
    required this.seatTypes,
    required this.ageGroup,
    this.paymentStatus = PaymentStatus.notPaid,
    this.status = BookingStatus.confirmed,
    DateTime? createdAt,
    DateTime? updatedAt,
  })  : id = id ?? const Uuid().v4(),
        createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  Booking copyWith({
    String? id,
    String? customerName,
    String? mobileNumber,
    String? busId,
    List<String>? seatNumbers,
    List<SeatType>? seatTypes,
    AgeGroup? ageGroup,
    PaymentStatus? paymentStatus,
    BookingStatus? status,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return Booking(
      id: id ?? this.id,
      customerName: customerName ?? this.customerName,
      mobileNumber: mobileNumber ?? this.mobileNumber,
      busId: busId ?? this.busId,
      seatNumbers: seatNumbers ?? this.seatNumbers,
      seatTypes: seatTypes ?? this.seatTypes,
      ageGroup: ageGroup ?? this.ageGroup,
      paymentStatus: paymentStatus ?? this.paymentStatus,
      status: status ?? this.status,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is Booking && other.id == id;
  }

  @override
  int get hashCode => id.hashCode;
}