import 'package:uuid/uuid.dart';
import 'age_group.dart';
import 'payment_status.dart';
import 'priority_status.dart';
import 'request_line.dart';
import 'seat_assignment.dart';
import 'seat_type.dart';
import 'trip_type.dart';

/// A passenger (customer) who has requested seats on a tour.
///
/// One Passenger = one WhatsApp contact = one app submission.
/// A single passenger can request multiple seat types via [requestLines],
/// e.g. "1 Double Lower + 1 Single Upper + 2 Seater".
///
/// Idempotency key: `(tourId, phone)` — resubmitting from the app updates
/// the existing record rather than creating a duplicate.
class Passenger {
  final String id;
  final String tourId;
  final String? userId; // set if customer-app user, null if manual
  final String name;
  final String phone;
  final AgeGroup ageGroup;

  /// What the passenger asked for — replaces the old single seatPreference + requestedSeats.
  final List<RequestLine> requestLines;

  /// Which seats have been assigned — each entry ties to a specific bus + seat.
  final List<SeatAssignment> assignedSeats;

  final PaymentStatus paymentStatus;
  final bool isHandler;

  /// Set when the agent holds this request without assigning seats.
  /// Distinct from "no seats yet" — waitlisted means the agent has
  /// deliberately deferred them (typically due to capacity).
  final bool isWaitlisted;

  /// Set when the agent confirms this request, making it eligible for seat
  /// allotment (no seats assigned yet). Distinct from waitlisted — confirmed
  /// means the customer has been notified and is in line for seats.
  final bool isConfirmed;

  final String? note; // optional note from customer

  /// Which legs of the tour this passenger is travelling on.
  /// Defaults to round-trip; existing rows missing this column also
  /// fall back to round-trip via [TripType.fromString].
  final TripType tripType;

  /// Cross-booking group this passenger belongs to (null = ungrouped).
  /// Members of the same group are kept on one bus by the seating engine.
  final String? groupId;

  /// Whether this passenger has an approved priority (front/sofa) need.
  /// Requested by the customer, approved by the agent.
  final PriorityStatus priorityStatus;

  /// Short reason for the priority request (e.g. "elderly, needs front").
  final String? priorityReason;

  /// True once the agent completes the leg this one-way passenger travelled on
  /// (e.g. the outbound GO half). Their seats are freed so the OTHER leg's
  /// chart shows them empty, but the record is kept for money/history — they
  /// just drop off the active roster. Round-trip riders are never marked here.
  final bool journeyDone;

  final DateTime createdAt;

  Passenger({
    String? id,
    required this.tourId,
    this.userId,
    required this.name,
    required this.phone,
    this.ageGroup = AgeGroup.adult,
    this.requestLines = const [],
    this.assignedSeats = const [],
    this.paymentStatus = PaymentStatus.notPaid,
    this.isHandler = false,
    this.isWaitlisted = false,
    this.isConfirmed = false,
    this.note,
    this.tripType = TripType.roundTrip,
    this.groupId,
    this.priorityStatus = PriorityStatus.none,
    this.priorityReason,
    this.journeyDone = false,
    DateTime? createdAt,
  }) : id = id ?? const Uuid().v4(),
       createdAt = createdAt ?? DateTime.now();

  /// Total number of seats requested across all request lines.
  int get totalSeatsRequested =>
      requestLines.fold(0, (sum, line) => sum + line.qty);

  /// Seat *berths* this passenger occupies on a bus. A Double Sofa line counts
  /// as 2 berths (it takes an upper+lower pair); every other seat counts as 1.
  /// This matches the capacity accounting in the Requests capacity banner and
  /// [Tour.totalBusSeats] — distinct from [totalSeatsRequested], which counts a
  /// Double Sofa line as a single requested unit. Used to size a cross-booking
  /// group against a single bus.
  int get seatBerths => requestLines.fold(
    0,
    (sum, l) => sum + l.qty * (l.seatType == SeatType.doubleSofa ? 2 : 1),
  );

  /// Total number of seats actually assigned.
  int get totalSeatsAssigned => assignedSeats.length;

  /// Whether all requested seats have been assigned.
  bool get isFullyAssigned => totalSeatsAssigned >= totalSeatsRequested;

  /// Whether at least one seat is assigned but not all.
  bool get isPartiallyAssigned => totalSeatsAssigned > 0 && !isFullyAssigned;

  /// Short summary of request lines for chips, e.g. "1 DL + 1 SU + 2 ST".
  String get requestSummary {
    if (requestLines.isEmpty) return 'No seats';
    return requestLines.map((l) => l.shortLabel).join(' + ');
  }

  /// Progress string like "2/4" or "✓ 4/4".
  String get progressLabel {
    final total = totalSeatsRequested;
    final assigned = totalSeatsAssigned;
    if (assigned >= total && total > 0) return '✓ $total/$total';
    return '$assigned/$total';
  }

  bool get isPriorityApproved => priorityStatus.isApproved;
  bool get isPriorityPending => priorityStatus.isPending;

  // ── Postgres serialization ────────────────────────────────

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'tour_id': tourId,
      'user_id': userId,
      'name': name,
      'phone': phone,
      'age_group': ageGroup.name,
      'request_lines': requestLines.map((l) => l.toMap()).toList(),
      'assigned_seats': assignedSeats.map((a) => a.toMap()).toList(),
      'payment_status': paymentStatus.name,
      'is_handler': isHandler,
      'is_waitlisted': isWaitlisted,
      'is_confirmed': isConfirmed,
      'note': note,
      'trip_type': tripType.storageKey,
      'group_id': groupId,
      'priority_status': priorityStatus.name,
      'priority_reason': priorityReason,
      'journey_done': journeyDone,
      'created_at': createdAt.toIso8601String(),
    };
  }

  factory Passenger.fromMap(Map<String, dynamic> map) {
    return Passenger(
      id: (map['id'] ?? '').toString(),
      tourId: (map['tour_id'] ?? '').toString(),
      userId: map['user_id'] as String?,
      name: (map['name'] ?? '').toString(),
      phone: (map['phone'] ?? '').toString(),
      ageGroup: AgeGroup.fromString(map['age_group'] as String?),
      requestLines: _parseRequestLines(map['request_lines']),
      assignedSeats: _parseAssignedSeats(map['assigned_seats']),
      paymentStatus: PaymentStatus.values.firstWhere(
        (s) => s.name == map['payment_status'],
        orElse: () => PaymentStatus.notPaid,
      ),
      isHandler: map['is_handler'] as bool? ?? false,
      isWaitlisted: map['is_waitlisted'] as bool? ?? false,
      isConfirmed: map['is_confirmed'] as bool? ?? false,
      note: map['note'] as String?,
      tripType: TripType.fromString(map['trip_type'] as String?),
      groupId: map['group_id'] as String?,
      priorityStatus: PriorityStatus.fromString(map['priority_status'] as String?),
      priorityReason: map['priority_reason'] as String?,
      journeyDone: map['journey_done'] as bool? ?? false,
      createdAt: _parseDate(map['created_at']),
    );
  }

  static List<RequestLine> _parseRequestLines(dynamic value) {
    if (value == null) return [];
    if (value is List) {
      return value
          .map((e) => RequestLine.fromMap(Map<String, dynamic>.from(e as Map)))
          .toList();
    }
    // Backward compat: old format had seatPreference + requestedSeats
    return [];
  }

  static List<SeatAssignment> _parseAssignedSeats(dynamic value) {
    if (value == null) return [];
    if (value is List) {
      // Check if it's the new format (list of maps) or old format (list of strings)
      if (value.isNotEmpty && value.first is String) {
        // Old format: ["L1", "L2"] — can't recover busId, return empty
        return [];
      }
      return value
          .map(
            (e) => SeatAssignment.fromMap(Map<String, dynamic>.from(e as Map)),
          )
          .toList();
    }
    return [];
  }

  static DateTime _parseDate(dynamic v) {
    if (v == null) return DateTime.now();
    if (v is DateTime) return v;
    return DateTime.tryParse(v.toString()) ?? DateTime.now();
  }

  Passenger copyWith({
    String? tourId,
    String? userId,
    String? name,
    String? phone,
    AgeGroup? ageGroup,
    List<RequestLine>? requestLines,
    List<SeatAssignment>? assignedSeats,
    PaymentStatus? paymentStatus,
    bool? isHandler,
    bool? isWaitlisted,
    bool? isConfirmed,
    String? note,
    TripType? tripType,
    String? groupId,
    PriorityStatus? priorityStatus,
    String? priorityReason,
    bool? journeyDone,
  }) {
    return Passenger(
      id: id,
      tourId: tourId ?? this.tourId,
      userId: userId ?? this.userId,
      name: name ?? this.name,
      phone: phone ?? this.phone,
      ageGroup: ageGroup ?? this.ageGroup,
      requestLines: requestLines ?? this.requestLines,
      assignedSeats: assignedSeats ?? this.assignedSeats,
      paymentStatus: paymentStatus ?? this.paymentStatus,
      isHandler: isHandler ?? this.isHandler,
      isWaitlisted: isWaitlisted ?? this.isWaitlisted,
      isConfirmed: isConfirmed ?? this.isConfirmed,
      note: note ?? this.note,
      tripType: tripType ?? this.tripType,
      groupId: groupId ?? this.groupId,
      priorityStatus: priorityStatus ?? this.priorityStatus,
      priorityReason: priorityReason ?? this.priorityReason,
      journeyDone: journeyDone ?? this.journeyDone,
      createdAt: createdAt,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is Passenger && other.id == id;

  @override
  int get hashCode => id.hashCode;
}
