import 'package:uuid/uuid.dart';
import 'tour_status.dart';
import 'bus_details.dart';
import 'passenger.dart';

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
  final BusDetails? busDetails;
  final List<Passenger> passengers;
  final String? handlerId;
  final String? createdBy;
  /// When true, the tour is visible to anonymous customers in the
  /// customer-mode tour list. Defaults to true so admins don't have to
  /// flip a toggle on every tour they create. Set to false in the
  /// Appwrite console (or via a future admin UI) to hide a tour.
  final bool isPublic;
  final DateTime createdAt;
  final DateTime updatedAt;

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
    this.busDetails,
    this.passengers = const [],
    this.handlerId,
    this.createdBy,
    this.isPublic = true,
    DateTime? createdAt,
    DateTime? updatedAt,
  })  : id = id ?? const Uuid().v4(),
        createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  int get totalSeatsRequested =>
      passengers.fold(0, (sum, p) => sum + p.requestedSeats);

  int get totalSeatsAssigned =>
      passengers.fold(0, (sum, p) => sum + p.assignedSeats.length);

  int get passengerCount => passengers.length;

  int get paidCount =>
      passengers.where((p) => p.paymentStatus.name == 'paid').length;

  String get route => '$fromCity → $toCity';

  Passenger? get handler => handlerId != null
      ? passengers.cast<Passenger?>().firstWhere(
            (p) => p?.id == handlerId,
            orElse: () => null,
          )
      : null;

  bool get allSeatsAssigned =>
      passengers.isNotEmpty &&
      passengers.every((p) => p.assignedSeats.length >= p.requestedSeats);

  // ── Appwrite serialization (camelCase, no id) ─────────────
  /// Convert this tour to an Appwrite document data map.
  /// The document ID is passed separately to `createDocument`.
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

  /// Build a Tour from an Appwrite document.
  /// The sync layer embeds `passengers` (List) and `busDetails` (Map) in the
  /// map, since Appwrite doesn't support joins.
  factory Tour.fromAppwrite(Map<String, dynamic> map) {
    // Parse nested passengers if embedded by sync layer
    List<Passenger> passengers = [];
    if (map['passengers'] is List) {
      passengers = (map['passengers'] as List)
          .map((p) => Passenger.fromAppwrite(Map<String, dynamic>.from(p)))
          .toList();
    }

    // Parse nested bus details
    BusDetails? busDetails;
    if (map['busDetails'] is Map) {
      busDetails = BusDetails.fromAppwrite(
          Map<String, dynamic>.from(map['busDetails'] as Map));
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
      busDetails: busDetails,
      passengers: passengers,
      handlerId: map['handlerId'] as String?,
      createdBy: map['createdBy'] as String?,
      isPublic: map['isPublic'] is bool ? map['isPublic'] as bool : true,
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
    String? id,
    String? title,
    String? fromCity,
    String? toCity,
    DateTime? departureDate,
    DateTime? returnDate,
    double? pricePerSeat,
    String? description,
    TourStatus? status,
    BusDetails? busDetails,
    List<Passenger>? passengers,
    String? handlerId,
    String? createdBy,
    bool? isPublic,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return Tour(
      id: id ?? this.id,
      title: title ?? this.title,
      fromCity: fromCity ?? this.fromCity,
      toCity: toCity ?? this.toCity,
      departureDate: departureDate ?? this.departureDate,
      returnDate: returnDate ?? this.returnDate,
      pricePerSeat: pricePerSeat ?? this.pricePerSeat,
      description: description ?? this.description,
      status: status ?? this.status,
      busDetails: busDetails ?? this.busDetails,
      passengers: passengers ?? this.passengers,
      handlerId: handlerId ?? this.handlerId,
      createdBy: createdBy ?? this.createdBy,
      isPublic: isPublic ?? this.isPublic,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? DateTime.now(),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is Tour && other.id == id;

  @override
  int get hashCode => id.hashCode;
}
