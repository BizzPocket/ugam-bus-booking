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
  final String? ownerId;
  final String? busId;
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
    this.ownerId,
    this.busId,
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

  /// Backward compat for screens still using single-bus access. Returns
  /// the first bus or null. Prefer `tour.buses` directly.
  @Deprecated('Use tour.buses')
  Bus? get busDetails => buses.isNotEmpty ? buses.first : null;

  Map<String, dynamic> toMap() => {
        'id': id,
        if (ownerId != null) 'owner_id': ownerId,
        'title': title,
        'from_city': fromCity,
        'to_city': toCity,
        'departure_date': departureDate.toIso8601String().split('T').first,
        'return_date': returnDate?.toIso8601String().split('T').first,
        'price_per_seat': pricePerSeat,
        if (description != null) 'description': description,
        'status': status.name,
        if (handlerId != null) 'handler_id': handlerId,
        if (createdBy != null) 'created_by': createdBy,
        'is_public': isPublic,
      };

  factory Tour.fromMap(Map<String, dynamic> map) {
    List<Bus> buses = const [];
    if (map['buses'] is List) {
      buses = (map['buses'] as List)
          .whereType<Map>()
          .map((b) => Bus.fromMap(Map<String, dynamic>.from(b)))
          .toList();
    }

    List<Passenger> passengers = const [];
    if (map['passengers'] is List) {
      passengers = (map['passengers'] as List)
          .whereType<Map>()
          .map((p) => Passenger.fromMap(Map<String, dynamic>.from(p)))
          .toList();
    }

    return Tour(
      id: (map['id'] ?? '').toString(),
      ownerId: map['owner_id']?.toString(),
      title: (map['title'] ?? '').toString(),
      fromCity: (map['from_city'] ?? '').toString(),
      toCity: (map['to_city'] ?? '').toString(),
      departureDate: map['departure_date'] != null
          ? _parseDate(map['departure_date'])
          : DateTime.now(),
      returnDate: map['return_date'] != null
          ? _parseDate(map['return_date'])
          : null,
      pricePerSeat: (map['price_per_seat'] as num?)?.toDouble() ?? 0.0,
      description: map['description']?.toString(),
      status: TourStatus.values.firstWhere(
        (s) => s.name == (map['status'] ?? 'planning'),
        orElse: () => TourStatus.planning,
      ),
      busId: map['bus_id']?.toString(),
      handlerId: map['handler_id']?.toString(),
      createdBy: map['created_by']?.toString(),
      isPublic: map['is_public'] is bool ? map['is_public'] as bool : true,
      buses: buses,
      passengers: passengers,
      createdAt: _parseDate(map['created_at']),
      updatedAt: _parseDate(map['updated_at']),
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
    String? ownerId,
    String? busId,
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
      ownerId: ownerId ?? this.ownerId,
      busId: busId ?? this.busId,
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
