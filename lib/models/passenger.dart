import 'package:uuid/uuid.dart';
import 'payment_status.dart';
import 'age_group.dart';
import 'seat_type.dart';

class Passenger {
  final String id;
  final String tourId;
  final String? userId;
  final String name;
  final String phone;
  final int requestedSeats;
  final SeatType seatPreference;
  final AgeGroup ageGroup;
  final List<String> assignedSeats;
  final PaymentStatus paymentStatus;
  final bool isHandler;
  final DateTime createdAt;

  Passenger({
    String? id,
    required this.tourId,
    this.userId,
    required this.name,
    required this.phone,
    this.requestedSeats = 1,
    this.seatPreference = SeatType.singleSofa,
    this.ageGroup = AgeGroup.other,
    this.assignedSeats = const [],
    this.paymentStatus = PaymentStatus.notPaid,
    this.isHandler = false,
    DateTime? createdAt,
  })  : id = id ?? const Uuid().v4(),
        createdAt = createdAt ?? DateTime.now();

  bool get isSeatsAssigned => assignedSeats.isNotEmpty;

  int get pendingSeats => requestedSeats - assignedSeats.length;

  // ── Appwrite serialization (camelCase, no id) ─────────────
  Map<String, dynamic> toAppwrite() {
    return {
      'tourId': tourId,
      'userId': userId,
      'name': name,
      'phone': phone,
      'requestedSeats': requestedSeats,
      'seatPreference': seatPreference.name,
      'ageGroup': ageGroup.name,
      'assignedSeats': assignedSeats,
      'paymentStatus': paymentStatus.name,
      'isHandler': isHandler,
    };
  }

  factory Passenger.fromAppwrite(Map<String, dynamic> map) {
    List<String> seats = [];
    if (map['assignedSeats'] is List) {
      seats = (map['assignedSeats'] as List).map((e) => e.toString()).toList();
    }

    return Passenger(
      id: (map[r'$id'] ?? map['id']) as String,
      tourId: map['tourId'] as String,
      userId: map['userId'] as String?,
      name: map['name'] as String,
      phone: map['phone'] as String,
      requestedSeats: map['requestedSeats'] as int? ?? 1,
      seatPreference: SeatType.values.firstWhere(
        (s) => s.name == map['seatPreference'],
        orElse: () => SeatType.singleSofa,
      ),
      ageGroup: AgeGroup.values.firstWhere(
        (a) => a.name == map['ageGroup'],
        orElse: () => AgeGroup.other,
      ),
      assignedSeats: seats,
      paymentStatus: PaymentStatus.values.firstWhere(
        (p) => p.name == map['paymentStatus'],
        orElse: () => PaymentStatus.notPaid,
      ),
      isHandler: map['isHandler'] as bool? ?? false,
      createdAt: (map[r'$createdAt'] ?? map['createdAt']) != null
          ? DateTime.tryParse(
                  (map[r'$createdAt'] ?? map['createdAt']).toString()) ??
              DateTime.now()
          : DateTime.now(),
    );
  }

  Passenger copyWith({
    String? id,
    String? tourId,
    String? userId,
    String? name,
    String? phone,
    int? requestedSeats,
    SeatType? seatPreference,
    AgeGroup? ageGroup,
    List<String>? assignedSeats,
    PaymentStatus? paymentStatus,
    bool? isHandler,
    DateTime? createdAt,
  }) {
    return Passenger(
      id: id ?? this.id,
      tourId: tourId ?? this.tourId,
      userId: userId ?? this.userId,
      name: name ?? this.name,
      phone: phone ?? this.phone,
      requestedSeats: requestedSeats ?? this.requestedSeats,
      seatPreference: seatPreference ?? this.seatPreference,
      ageGroup: ageGroup ?? this.ageGroup,
      assignedSeats: assignedSeats ?? this.assignedSeats,
      paymentStatus: paymentStatus ?? this.paymentStatus,
      isHandler: isHandler ?? this.isHandler,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is Passenger && other.id == id;

  @override
  int get hashCode => id.hashCode;
}
