import 'package:uuid/uuid.dart';
import 'tour_status.dart';
import 'bus.dart';
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
  final String? handlerId; // FK → Passenger.id
  final String? createdBy; // admin phone
  final bool isPublic;
  final DateTime createdAt;
  final DateTime updatedAt;

  // ── Embedded by sync layer (not stored in Tour document) ──
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

  // ── Computed properties ───────────────────────────────────

  String get route => '$fromCity → $toCity';

  int get passengerCount => passengers.length;

  /// Total seats requested across all passengers.
  int get totalSeatsRequested =>
      passengers.fold(0, (sum, p) => sum + p.totalSeatsRequested);

  /// Total seats assigned across all passengers.
  int get totalSeatsAssigned =>
      passengers.fold(0, (sum, p) => sum + p.totalSeatsAssigned);

  /// Total seats available across all buses.
  int get totalBusSeats => buses.fold(0, (sum, b) => sum + b.totalSeats);

  /// Passengers who have paid.
  int get paidCount =>
      passengers.where((p) => p.paymentStatus.name == 'paid').length;

  /// The handler passenger, if one is set.
  Passenger? get handler => handlerId != null
      ? passengers.cast<Passenger?>().firstWhere(
            (p) => p?.id == handlerId,
            orElse: () => null,
          )
      : null;

  /// Whether all passengers' request lines are fully assigned.
  bool get allSeatsAssigned =>
      passengers.isNotEmpty && passengers.every((p) => p.isFullyAssigned);

  /// Backward compat: returns first bus or null. Used by screens that
  /// haven't been updated to multi-bus yet.
  @Deprecated('Use tour.buses instead')
  Bus? get busDetails => buses.isNotEmpty ? buses.first : null;

  // ── Appwrite serialization (only Tour's own fields) ───────

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
  /// The sync layer embeds `passengers` and `buses` in the map.
  factory Tour.fromAppwrite(Map<String, dynamic> map) {
    // Parse nested passengers
    List<Passenger> passengers = [];
    if (map['passengers'] is List) {
      passengers = (map['passengers'] as List)
          .map((p) => Passenger.fromAppwrite(Map<String, dynamic>.from(p)))
          .toList();
    }

    // Parse nested buses (embedded by sync layer).
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
