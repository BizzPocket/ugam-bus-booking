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
/// One Passenger = one booking request = one app submission.
/// A single passenger can request multiple seat types via [requestLines],
/// e.g. "1 Double Lower + 1 Single Upper + 2 Seater".
///
/// Identity is [id] (a UUID), NOT `(tourId, phone)`. A single phone may now
/// hold MULTIPLE distinct requests on the same tour (e.g. an agent submitting
/// for several travellers from one handset) — each is its own Passenger row,
/// linked to its booking_requests audit row via `booking_requests.passenger_id`
/// (migration 030). Resubmitting no longer overwrites an earlier request.
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

  /// Snapshot of the global pickup location the customer chose for this request
  /// (id + name captured at submit time). Nullable — many riders pick no point.
  /// The name is stored alongside the id so a later rename/retire of the global
  /// pickup location never rewrites this historical request.
  final String? pickupLocationId;
  final String? pickupLocationName;

  /// Set when the customer self-cancels a still-pending request (migration 034).
  /// The row is KEPT for history, but the app filters a cancelled passenger out
  /// of every active roster / capacity calc (loading + realtime), so it stops
  /// counting toward demand.
  final DateTime? cancelledAt;

  bool get isCancelled => cancelledAt != null;

  /// Set when the customer REQUESTS cancellation of a CONFIRMED / seat-assigned
  /// booking (migration 035). Mirror of the customer-side flag onto the row the
  /// admin roster reads. UNLIKE [cancelledAt] this KEEPS the passenger on the
  /// active roster/capacity — the organiser still has to APPROVE it (approval
  /// removes the row and frees the seat). Until then it only drives the
  /// "cancellation requested" badge, so it is deliberately NOT filtered out at
  /// load / realtime.
  final DateTime? cancelRequestedAt;

  bool get isCancelRequested => cancelRequestedAt != null;

  /// Stable signature of the seat-set most recently WhatsApp-notified to this
  /// rider (see [seatSignature]). Null until the first seat allocation is sent.
  /// When it differs from the current seats — a fresh lock, or an organiser edit
  /// AFTER lock — [seatsChangedSinceNotified] is true and the Notify screen
  /// offers a targeted re-notify. Persisted (migration 040) so "changed" survives
  /// an app restart.
  final String? seatsNotifiedSig;

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
    this.pickupLocationId,
    this.pickupLocationName,
    this.cancelledAt,
    this.cancelRequestedAt,
    this.seatsNotifiedSig,
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

  /// Physical berths of a single request line: a Double Sofa line counts as 2
  /// (upper+lower pair), every other seat counts as 1, times its qty.
  static int _berthsOfLine(RequestLine l) =>
      l.qty * (l.seatType == SeatType.doubleSofa ? 2 : 1);

  /// Trip-aware seat *weight*, summed PER REQUEST LINE (the leg now lives on
  /// each line, not on the passenger). A physical seat spans the whole trip, so
  /// a round-trip line weighs a full seat (1.0 per single berth) while a one-leg
  /// line weighs HALF (0.5) — the other leg of that seat stays bookable for an
  /// opposite-leg rider. A Double Sofa weighs twice a single (round-trip double
  /// = 2.0, one-way double = 1.0). A single request can mix legs, so each line
  /// is weighted independently and the results summed. Used for demand display
  /// and the "0.5 / 1.0" per-passenger label — NOT for assignment completeness
  /// (which stays physical, see [isFullyAssigned]).
  double get seatLoad => requestLines.fold(
    0.0,
    (sum, l) => sum + _berthsOfLine(l) * (l.leg.isOneWay ? 0.5 : 1.0),
  );

  /// Berths this passenger loads on the OUTBOUND (GO) leg, summed PER REQUEST
  /// LINE: only lines whose leg uses outbound contribute their berths. The
  /// per-leg counterpart that makes capacity honest — each physical seat offers
  /// one GO slot + one RET slot, so a one-way line consumes only its leg and
  /// frees the other for someone else. Because the leg is per line, a mixed
  /// request contributes only its outbound-bound lines here.
  int get goBerths => requestLines.fold(
    0,
    (sum, l) => sum + (l.leg.usesOutbound ? _berthsOfLine(l) : 0),
  );

  /// Berths this passenger loads on the RETURN (RET) leg, summed PER REQUEST
  /// LINE: only lines whose leg uses return contribute their berths. The leg is
  /// per line, so a mixed request contributes only its return-bound lines here.
  int get retBerths => requestLines.fold(
    0,
    (sum, l) => sum + (l.leg.usesReturn ? _berthsOfLine(l) : 0),
  );

  /// Coarse trip-leg SUMMARY derived from the per-line legs, for callers that
  /// want a single value (e.g. legacy display). Returns [TripType.roundTrip]
  /// when there are no lines, when any line is round-trip, or when lines
  /// disagree (mixed legs); [TripType.outboundOnly] when every line is
  /// outbound-only; [TripType.returnOnly] when every line is return-only.
  /// The stored [tripType] field is kept separately for backward-compat
  /// serialization and is NOT replaced by this getter.
  TripType get derivedTripType {
    if (requestLines.isEmpty) return TripType.roundTrip;
    final legs = requestLines.map((l) => l.leg).toSet();
    if (legs.length == 1) return legs.first;
    return TripType.roundTrip;
  }

  /// The trip [TripType] (leg) to charge / count for a held seat of [type]
  /// (optionally narrowed by [position]).
  ///
  /// Collects the request lines matching [type]. If an EXACT [position] match
  /// exists among them, only those lines are considered; otherwise all lines of
  /// that type are. From the chosen set:
  /// - none → [TripType.roundTrip];
  /// - all share one leg → that leg;
  /// - mixed legs → the HEAVIER leg (round-trip if any line is round-trip, else
  ///   outbound-only if any, else return-only).
  ///
  /// DOCUMENTED APPROXIMATION: a [SeatAssignment] carries no leg, so once seats
  /// are assigned a specific seat cannot be tied back to a specific request line.
  /// In the rare case where a passenger has multiple SAME-TYPE lines on DIFFERENT
  /// legs (e.g. 1 single-sofa round-trip + 1 single-sofa outbound-only), this
  /// returns the heavier leg for ALL held seats of that type rather than
  /// pinpointing each — the conservative choice that never under-charges or
  /// under-counts capacity.
  TripType legForSeatType(SeatType type, {SeatPosition? position}) {
    final typeLines = requestLines.where((l) => l.seatType == type).toList();
    // No request line of this seat type means the rider was placed in a seat
    // TYPE they didn't request — common when a one-way rider leg-shares a
    // double sofa (a single-sofa GO/RET rider seated on a double berth). Fall
    // back to the rider's OVERALL leg ([derivedTripType]) rather than assuming
    // round-trip: a wholly one-way rider then still gets the one-leg price,
    // while a round-trip or mixed-leg rider stays at full fare (derivedTripType
    // is round-trip for both), so this never under-charges.
    if (typeLines.isEmpty) return derivedTripType;
    // Narrow to an exact position match only if one exists; otherwise keep all
    // lines of this type (ignore position).
    final positionMatch =
        position == null ? const <RequestLine>[] : typeLines.where((l) => l.position == position).toList();
    final lines = positionMatch.isNotEmpty ? positionMatch : typeLines;

    final legs = lines.map((l) => l.leg).toSet();
    if (legs.length == 1) return legs.first;
    // Mixed legs → heavier leg.
    if (legs.contains(TripType.roundTrip)) return TripType.roundTrip;
    if (legs.contains(TripType.outboundOnly)) return TripType.outboundOnly;
    return TripType.returnOnly;
  }

  /// The trip leg this passenger holds [seatId] on: the per-seat
  /// [SeatAssignment.leg] when it was recorded, else the coarse passenger-level
  /// [tripType] (legacy rows / unstamped seats). This is what lets a mixed
  /// same-type request tint and charge EACH physical seat by its own leg
  /// instead of collapsing both to the [derivedTripType] summary — e.g. one
  /// "1 seater GO-only + 1 seater RET-only" booking shows one seat cyan (GO)
  /// and the other violet (RET). Pass [busId] to disambiguate the rare case of
  /// the same seatId across two buses; omit it on a per-bus chart.
  TripType legForSeat(String seatId, {String? busId}) {
    for (final a in assignedSeats) {
      if (a.seatId == seatId && (busId == null || a.busId == busId)) {
        return a.leg ?? tripType;
      }
    }
    return tripType;
  }

  /// Total number of seats actually assigned.
  int get totalSeatsAssigned => assignedSeats.length;

  /// Whether all requested seats have been assigned. Measured in physical
  /// *berths*, not request units: a whole Double Sofa is two berths (two
  /// [SeatAssignment] entries) and must be matched against [seatBerths], which
  /// also counts a double as two. Comparing against [totalSeatsRequested]
  /// (where a double counts as one) made a passenger holding several doubles
  /// read as fully assigned after only some sofas were freed, so they never
  /// re-entered the pending dock until EVERY sofa was freed.
  bool get isFullyAssigned => totalSeatsAssigned >= seatBerths;

  /// Whether at least one seat is assigned but not all.
  bool get isPartiallyAssigned => totalSeatsAssigned > 0 && !isFullyAssigned;

  /// Deterministic signature of the CURRENT seat allocation — sorted
  /// "busId:seatId" pairs joined — so it changes iff the held seats change.
  /// Empty when the rider holds no seat.
  String get seatSignature {
    if (assignedSeats.isEmpty) return '';
    final parts = assignedSeats.map((a) => '${a.busId}:${a.seatId}').toList()
      ..sort();
    return parts.join('|');
  }

  /// True when this rider holds a seat whose CURRENT allocation has not been
  /// notified — never sent, or changed since the last send. Drives the Notify
  /// screen's "re-notify changed" action after a post-lock seat edit.
  bool get seatsChangedSinceNotified =>
      assignedSeats.isNotEmpty && seatsNotifiedSig != seatSignature;

  /// Short summary of request lines for chips, e.g. "1 DL + 1 SU + 2 ST".
  String get requestSummary {
    if (requestLines.isEmpty) return 'No seats';
    return requestLines.map((l) => l.shortLabel).join(' + ');
  }

  /// Progress string like "2/4" or "✓ 4/4". Counted in berths (a Double Sofa
  /// is two) so the fraction and the ✓ stay in lock-step with [isFullyAssigned]
  /// — otherwise a passenger who freed one of several doubles would still read
  /// "✓ 2/2".
  String get progressLabel {
    final total = seatBerths;
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
      'pickup_location_id': pickupLocationId,
      'pickup_location_name': pickupLocationName,
      'cancelled_at': cancelledAt?.toIso8601String(),
      'cancel_requested_at': cancelRequestedAt?.toIso8601String(),
      'seats_notified_sig': seatsNotifiedSig,
      'created_at': createdAt.toIso8601String(),
    };
  }

  factory Passenger.fromMap(Map<String, dynamic> map) {
    // Parse the legacy passenger-level leg first so it can backfill any request
    // line that predates the per-line `leg` field (rows written before the
    // migration carried the leg only here, in `trip_type`).
    final tripType = TripType.fromString(map['trip_type'] as String?);
    return Passenger(
      id: (map['id'] ?? '').toString(),
      tourId: (map['tour_id'] ?? '').toString(),
      userId: map['user_id'] as String?,
      name: (map['name'] ?? '').toString(),
      phone: (map['phone'] ?? '').toString(),
      ageGroup: AgeGroup.fromString(map['age_group'] as String?),
      requestLines: _parseRequestLines(map['request_lines'], tripType),
      assignedSeats: _parseAssignedSeats(map['assigned_seats']),
      paymentStatus: PaymentStatus.values.firstWhere(
        (s) => s.name == map['payment_status'],
        orElse: () => PaymentStatus.notPaid,
      ),
      isHandler: map['is_handler'] as bool? ?? false,
      isWaitlisted: map['is_waitlisted'] as bool? ?? false,
      isConfirmed: map['is_confirmed'] as bool? ?? false,
      note: map['note'] as String?,
      tripType: tripType,
      groupId: map['group_id'] as String?,
      priorityStatus: PriorityStatus.fromString(map['priority_status'] as String?),
      priorityReason: map['priority_reason'] as String?,
      journeyDone: map['journey_done'] as bool? ?? false,
      pickupLocationId: map['pickup_location_id'] as String?,
      pickupLocationName: map['pickup_location_name'] as String?,
      cancelledAt: map['cancelled_at'] != null
          ? DateTime.tryParse(map['cancelled_at'].toString())
          : null,
      cancelRequestedAt: map['cancel_requested_at'] != null
          ? DateTime.tryParse(map['cancel_requested_at'].toString())
          : null,
      seatsNotifiedSig: map['seats_notified_sig'] as String?,
      createdAt: _parseDate(map['created_at']),
    );
  }

  static List<RequestLine> _parseRequestLines(
    dynamic value,
    TripType fallbackLeg,
  ) {
    if (value == null) return [];
    if (value is List) {
      return value
          .map((e) => RequestLine.fromMap(
                Map<String, dynamic>.from(e as Map),
                fallbackLeg: fallbackLeg,
              ))
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
    String? pickupLocationId,
    String? pickupLocationName,
    DateTime? cancelledAt,
    DateTime? cancelRequestedAt,
    String? seatsNotifiedSig,
    bool clearCancelRequested = false,
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
      pickupLocationId: pickupLocationId ?? this.pickupLocationId,
      pickupLocationName: pickupLocationName ?? this.pickupLocationName,
      cancelledAt: cancelledAt ?? this.cancelledAt,
      // `clearCancelRequested` wins so a dismiss can null the marker (plain
      // copyWith can't set null through the `??` fallback).
      cancelRequestedAt: clearCancelRequested
          ? null
          : (cancelRequestedAt ?? this.cancelRequestedAt),
      seatsNotifiedSig: seatsNotifiedSig ?? this.seatsNotifiedSig,
      createdAt: createdAt,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is Passenger && other.id == id;

  @override
  int get hashCode => id.hashCode;
}
