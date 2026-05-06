import 'package:uuid/uuid.dart';
import 'tour_status.dart';
import 'bus_details.dart';
import 'passenger.dart';

/// A tour planned and managed by the agent.
///
/// Buses and Passengers are stored as separate collections linked by tourId.
/// The sync layer embeds them into the Tour object when fetching.
class Tour {
  final String id;
  final String title;
  final String fromCity;
  final String toCity;
  final DateTime departureDate;
  final DateTime? returnDate;
  final double pricePerSeat;
  final String? description;
  final TourStatus status;
  final String? handlerId;
  final String? createdBy;
  final bool isPublic;
  final DateTime createdAt;
  final DateTime updatedAt;

  // Embedded by sync layer (not stored in Tour document)
  final List<Bus> buses;
  final List<Passenger> passengers;

  Tour({
    String? id,
    required this.title,
    required this.fromCity,
    required this.toCity,
    required this.departureDate,
    this.returnDate,
    required this.pricePerSeat,
    this.description,
    this.status = TourStatus.planning,
    this.handlerId,
    this.createdBy,
    this.isPublic = true,
    this.buses = const [],
    this.passengers = const [],
    DateTime? createdAt,
    DateTime? updatedAt,
  })  : id = id ?? const Uuid().v4(),
        createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  String get route => '$fromCity → $toCity';
  int get passengerCount => passengers.length;

  int get totalSeatsRequested =>
      passengers.fold(0, (sum, p) => sum + p.totalSeatsRequested);

  int get totalSeatsAssigned =>
      passengers.fold(0, (sum, p) => sum + p.totalSeatsAssigned);

  int get totalBusSeats => buses.fold(0, (sum, b) => sum + b.totalSeats);

  int get paidCount =>
      passengers.where((p) => p.paymentStatus.name == 'paid').length;

  Passenger? get handler => handlerId != null
      ? passengers.cast<Passenger?>().firstWhere(
            (p) => p?.id == handlerId,
            orElse: () => null,
          )
      : null;

  bool get allSeatsAssigned =>
      passengers.isNotEmpty && passengers.every((p) => p.isFullyAssigned);

  Map<String, dynamic> toAppwrite() {
    return {
      'title': title,
      'fromCity': fromCity,
      'toCity': toCity,
      'departureDate': departureDate.toIso8601String(),
      'returnDate': returnDate?.toIso8601String(),
      'pricePerSeat': pricePerSeat,
      'description': description,
      'status': status.name,
      'handlerId': handlerId,
      'createdBy': createdBy,
      'isPublic': isPublic,
    };
  }

  factory Tour.fromAppwrite(Map<String, dynamic> map) {
    List<Passenger> passengers = [];
    if (map['passengers'] is List) {
      passengers = (map['passengers'] as List)
          .map((p) => Passenger.fromAppwrite(Map<String, dynamic>.from(p)))
          .toList();
    }

    List<Bus> buses = [];
    if (map['buses'] is List) {
      buses = (map['buses'] as List)
          .map((b) => Bus.fromAppwrite(Map<String, dynamic>.from(b)))
          .toList();
    }

    return Tour(
      id: (map[r'$id'] ?? map['id']) as String,
      title: map['title'] as String,
      fromCity: map['fromCity'] as String,
      toCity: map['toCity'] as String,
      departureDate: DateTime.parse(map['departureDate'] as String),
      returnDate: map['returnDate'] != null
          ? DateTime.parse(map['returnDate'] as String)
          : null,
      pricePerSeat: (map['pricePerSeat'] as num).toDouble(),
      description: map['description'] as String?,
      status: TourStatus.values.firstWhere(
        (s) => s.name == map['status'],
        orElse: () => TourStatus.planning,
      ),
      handlerId: map['handlerId'] as String?,
      createdBy: map['createdBy'] as String?,
      isPublic: map['isPublic'] is bool ? map['isPublic'] as bool : true,
      buses: buses,
      passengers: passengers,
      createdAt: _parseDate(map[r'$createdAt'] ?? map['createdAt']),
      updatedAt: _parseDate(map[r'$updatedAt'] ?? map['updatedAt']),
    );
  }

  static DateTime _parseDate(dynamic v) {
    if (v == null) return DateTime.now();
    if (v is DateTime) return v;
    return DateTime.tryParse(v.toString()) ?? DateTime.now();
  }

  Tour copyWith({
    String? title,
    String? fromCity,
    String? toCity,
    DateTime? departureDate,
    DateTime? returnDate,
    double? pricePerSeat,
    String? description,
    TourStatus? status,
    String? handlerId,
    String? createdBy,
    bool? isPublic,
    List<Bus>? buses,
    List<Passenger>? passengers,
    DateTime? updatedAt,
  }) {
    return Tour(
      id: id,
      title: title ?? this.title,
      fromCity: fromCity ?? this.fromCity,
      toCity: toCity ?? this.toCity,
      departureDate: departureDate ?? this.departureDate,
      returnDate: returnDate ?? this.returnDate,
      pricePerSeat: pricePerSeat ?? this.pricePerSeat,
      description: description ?? this.description,
      status: status ?? this.status,
      handlerId: handlerId ?? this.handlerId,
      createdBy: createdBy ?? this.createdBy,
      isPublic: isPublic ?? this.isPublic,
      buses: buses ?? this.buses,
      passengers: passengers ?? this.passengers,
      createdAt: createdAt,
      updatedAt: updatedAt ?? DateTime.now(),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is Tour && other.id == id;

  @override
  int get hashCode => id.hashCode;
}
