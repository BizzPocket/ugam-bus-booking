part of 'customer_requests_store.dart';

/// Device-local journal of booking requests the customer submitted from
/// this device. The customer has no Supabase Auth session, so the server
/// has no concept of "my requests" — this store is the source of truth
/// for the list, with a per-row RPC refresh for live status.
class CustomerRequestEntry {
  final String id;
  final String tourId;
  final String tourTitle;
  final String tourFromCity;
  final String tourToCity;
  final DateTime tourDepartureDate;
  final double tourPricePerSeat;
  final String customerName;
  final String customerPhone;
  final int partySize;
  final int doubleSofa;
  final int singleSofa;
  final String? note;

  /// Snapshot of the global pickup location the customer chose for this request
  /// (id + name captured at submit time). Nullable — many riders pick no point.
  /// The name is kept alongside the id so a later rename/retire of the global
  /// pickup location never rewrites this device-local ticket.
  final String? pickupLocationId;
  final String? pickupLocationName;

  final TripType tripType;
  final String status;
  final List<SeatAssignment> assignedSeats;
  final DateTime? customerEditedAt;
  final DateTime createdAt;
  final DateTime? lastRefreshedAt;

  /// Whether the request's tour has reached the 'locked' (or 'completed')
  /// lifecycle state. Seats stay hidden until this is true — assignments are
  /// provisional and may shuffle right up until the organiser locks the tour.
  /// Sourced server-side via the `booking_request_tour_locked` RPC on refresh.
  final bool tourLocked;

  /// Whether the organiser has CONFIRMED this request (passengers.is_confirmed),
  /// sourced server-side via `booking_request_status_lookup` on refresh
  /// (migration 034). A confirmed request can no longer be self-cancelled — the
  /// customer must phone the organiser instead.
  final bool isConfirmed;

  /// The organiser's phone (tour.createdBy), captured at submit so the
  /// "Contact organiser to cancel" action can dial them even offline. Nullable
  /// for legacy entries created before this field existed.
  final String? organiserPhone;

  /// Set once the customer has RAISED a cancellation request on a CONFIRMED /
  /// seat-assigned booking (migration 035). Distinct from a completed cancel —
  /// the organiser still has to approve it (which frees the seat). Sourced
  /// server-side via `booking_request_status_lookup` on refresh; drives the
  /// "Cancellation requested — awaiting organiser" state, replacing the old
  /// dead-end "Call organiser" for a confirmed/seated booking.
  final DateTime? cancelRequestedAt;

  /// When this booking's SEAT HOLD lapses, for a chart booking on a tour that
  /// collects an advance (migration 064).
  ///
  /// Such a booking has NO `booking_requests` row until the advance is
  /// confirmed — `chart_hold_seats` writes only a `seat_holds` row, and
  /// `chart_finalize_hold` creates the booking row later. Before this field
  /// existed, refresh() read "no booking row" as "the organiser deleted it" and
  /// branded every live unpaid hold as Cancelled.
  final DateTime? holdExpiresAt;

  /// `seat_holds.id` behind this booking. Needed to record a UPI claim against
  /// the hold (`claim_upi_advance_for_hold`) when the customer pays LATER, from
  /// My Requests, rather than in the one sheet shown at checkout.
  final String? holdId;

  /// Advance due on this booking, in paise, captured at hold time.
  ///
  /// Stored on the ticket rather than re-derived from the tour so the retry
  /// works offline and cannot silently re-quote if the organiser edits the
  /// tour's advance after the seats were held.
  final int advancePaise;

  /// The organiser's collection VPA and payee name, captured with the advance
  /// for the same reason.
  final String? collectVpa;
  final String? collectPayeeName;

  /// Paise the customer has ALREADY told us they paid against this request.
  ///
  /// An assertion, never proof — the same caveat as `payment_claims` itself.
  /// Its job is narrow and important: without it, "Pay now" keeps offering
  /// itself to someone who has already paid, and they pay twice. That is the
  /// exact failure this whole feature exists to avoid on the other side.
  final int claimedPaise;

  CustomerRequestEntry({
    required this.id,
    required this.tourId,
    required this.tourTitle,
    required this.tourFromCity,
    required this.tourToCity,
    required this.tourDepartureDate,
    required this.tourPricePerSeat,
    required this.customerName,
    required this.customerPhone,
    required this.partySize,
    required this.doubleSofa,
    required this.singleSofa,
    this.note,
    this.pickupLocationId,
    this.pickupLocationName,
    this.tripType = TripType.roundTrip,
    this.status = 'pending',
    this.assignedSeats = const [],
    this.customerEditedAt,
    required this.createdAt,
    this.lastRefreshedAt,
    this.tourLocked = false,
    this.isConfirmed = false,
    this.organiserPhone,
    this.cancelRequestedAt,
    this.holdExpiresAt,
    this.holdId,
    this.advancePaise = 0,
    this.collectVpa,
    this.collectPayeeName,
    this.claimedPaise = 0,
  });

  bool get hasSeatsAssigned => assignedSeats.isNotEmpty;

  /// Seats are held pending an advance payment. The booking is LIVE — the
  /// seats are blocked on the chart for everyone else — it simply has not been
  /// paid for yet, so it must never read as cancelled.
  bool get isHeld => status == 'held';

  /// The hold window closed without payment. The seats are back on sale, so
  /// this ticket is re-bookable — which is what separates it from a cancel.
  bool get holdExpired => status == 'expired';

  /// Time left on the hold, floored at zero so a lapsed hold never counts
  /// backwards on the customer's countdown.
  Duration holdRemaining(DateTime now) {
    final until = holdExpiresAt;
    if (until == null) return Duration.zero;
    final left = until.difference(now);
    return left.isNegative ? Duration.zero : left;
  }

  /// Whether "Pay advance" can be offered on this ticket.
  ///
  /// Requires a LIVE hold (an expired one has released its seats and must be
  /// re-booked, not paid for), something to pay against, an amount, and a VPA
  /// to pay it to.
  bool get canPayAdvance =>
      isHeld &&
      (holdId?.isNotEmpty ?? false) &&
      advancePaise > 0 &&
      (collectVpa?.isNotEmpty ?? false);

  /// Paise still owed on a banded request.
  int get outstandingPaise =>
      (advancePaise - claimedPaise).clamp(0, advancePaise);

  /// The customer has told us they paid the whole charge. Unverified until the
  /// organiser confirms it against their bank statement.
  bool get paymentRecorded => advancePaise > 0 && claimedPaise >= advancePaise;

  /// Whether to offer "Pay now" for a REQUEST-mode charge.
  ///
  /// Deliberately excludes anything on a seat hold: chart-mode holds already
  /// carry their own countdown and retry ([canPayAdvance]), and offering both
  /// would put two Pay buttons on one card.
  bool get canPayCharge =>
      !isHeld &&
      (holdId?.isEmpty ?? true) &&
      !isCancelled &&
      outstandingPaise > 0 &&
      (collectVpa?.isNotEmpty ?? false);

  /// A request is cancellable by the customer ONLY while purely pending — not
  /// organiser-confirmed and with no seats assigned. Migration 034 enforces the
  /// same gate server-side, so a stale screen can never cancel a confirmed one.
  bool get canCancel =>
      status == 'pending' && !hasSeatsAssigned && !isConfirmed;

  /// True once the customer has raised a cancellation REQUEST (migration 035)
  /// and is awaiting the organiser's approval.
  bool get cancellationRequested => cancelRequestedAt != null;

  /// A confirmed / seat-assigned booking can no longer be self-cancelled, but
  /// the customer MAY request cancellation — offered only while no such request
  /// is already pending and the booking isn't already cancelled. The mirror of
  /// [canCancel] for the confirmed/seated case (migration 035 enforces the same
  /// gate server-side).
  bool get canRequestCancel =>
      !isCancelled &&
      !cancellationRequested &&
      (isConfirmed || hasSeatsAssigned);

  /// Both admin-decline ('rejected') and customer self-cancel ('cancelled') read
  /// as "Cancelled" to the customer.
  bool get isCancelled => status == 'rejected' || status == 'cancelled';

  /// Seats may only be shown once the tour is locked AND seats are assigned.
  /// Until the organiser locks the tour, assignments are provisional, so the
  /// UI must neither reveal seat numbers nor open the seat-layout sheet.
  bool get seatsVisible => tourLocked && hasSeatsAssigned;

  /// Whether the customer may re-open their own booking in the request form.
  ///
  /// Having a seat no longer closes the door. The organiser seats people days
  /// before departure, and a customer still legitimately needs to move their
  /// pickup point or change the party after that; blocking it sent every such
  /// change through a phone call. Migration 094 takes the same view server-side
  /// and trims any berths the edit leaves surplus off the chart — the same
  /// thing the admin's own edit sheet does.
  ///
  /// Two gates remain:
  ///   * a raised cancellation request — offering "Edit request" on a card that
  ///     already reads "Cancellation requested" asks the customer to argue with
  ///     themselves, and the organiser is mid-decision on that booking;
  ///   * the tour LOCK — once locked, seat numbers have gone out and the chart
  ///     is final, so a change goes through the organiser (the server enforces
  ///     the same gate, so a stale client can't slip past it).
  bool get canEdit =>
      status == 'pending' && !cancellationRequested && !tourLocked;
  bool get wasEdited => customerEditedAt != null;

  /// True once the tour's departure date has passed — the trip is over, so
  /// the ticket is history, not an active booking. "My Tickets" hides these
  /// (a completed/past tour shouldn't read as a live ticket).
  bool get isPast {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    return tourDepartureDate.isBefore(today);
  }

  CustomerRequestEntry copyWith({
    String? customerName,
    int? partySize,
    int? doubleSofa,
    int? singleSofa,
    String? note,
    String? pickupLocationId,
    String? pickupLocationName,
    TripType? tripType,
    String? status,
    List<SeatAssignment>? assignedSeats,
    DateTime? customerEditedAt,
    DateTime? lastRefreshedAt,
    bool? tourLocked,
    bool? isConfirmed,
    String? organiserPhone,
    DateTime? cancelRequestedAt,
    DateTime? holdExpiresAt,
    String? holdId,
    int? advancePaise,
    String? collectVpa,
    String? collectPayeeName,
    int? claimedPaise,

    /// Wins over [holdExpiresAt] so a finalized/dead hold can be nulled out —
    /// plain copyWith cannot set null through the `??` fallback.
    bool clearHold = false,
  }) {
    return CustomerRequestEntry(
      id: id,
      tourId: tourId,
      tourTitle: tourTitle,
      tourFromCity: tourFromCity,
      tourToCity: tourToCity,
      tourDepartureDate: tourDepartureDate,
      tourPricePerSeat: tourPricePerSeat,
      customerName: customerName ?? this.customerName,
      customerPhone: customerPhone,
      partySize: partySize ?? this.partySize,
      doubleSofa: doubleSofa ?? this.doubleSofa,
      singleSofa: singleSofa ?? this.singleSofa,
      note: note ?? this.note,
      pickupLocationId: pickupLocationId ?? this.pickupLocationId,
      pickupLocationName: pickupLocationName ?? this.pickupLocationName,
      tripType: tripType ?? this.tripType,
      status: status ?? this.status,
      assignedSeats: assignedSeats ?? this.assignedSeats,
      customerEditedAt: customerEditedAt ?? this.customerEditedAt,
      createdAt: createdAt,
      lastRefreshedAt: lastRefreshedAt ?? this.lastRefreshedAt,
      tourLocked: tourLocked ?? this.tourLocked,
      isConfirmed: isConfirmed ?? this.isConfirmed,
      organiserPhone: organiserPhone ?? this.organiserPhone,
      cancelRequestedAt: cancelRequestedAt ?? this.cancelRequestedAt,
      holdExpiresAt: clearHold ? null : (holdExpiresAt ?? this.holdExpiresAt),
      holdId: clearHold ? null : (holdId ?? this.holdId),
      advancePaise: advancePaise ?? this.advancePaise,
      collectVpa: collectVpa ?? this.collectVpa,
      collectPayeeName: collectPayeeName ?? this.collectPayeeName,
      claimedPaise: claimedPaise ?? this.claimedPaise,
    );
  }

  /// The server no longer has this request (the organiser deleted the request
  /// or its whole tour). Drop the local ticket to a cancelled state AND clear
  /// the now-orphaned seat/lock data: otherwise [seatsVisible] stays true, the
  /// row keeps rendering "seats assigned" with stale numbers, and tapping it
  /// opens the seat-layout sheet whose LIVE lookup returns nothing — the dead
  /// "No layout" empty state the customer sees over a still-"allocated" card.
  CustomerRequestEntry markCancelled({DateTime? at}) => copyWith(
    status: 'rejected',
    assignedSeats: const [],
    tourLocked: false,
    lastRefreshedAt: at ?? DateTime.now(),
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'tour_id': tourId,
    'tour_title': tourTitle,
    'tour_from_city': tourFromCity,
    'tour_to_city': tourToCity,
    'tour_departure_date': tourDepartureDate.toIso8601String(),
    'tour_price_per_seat': tourPricePerSeat,
    'customer_name': customerName,
    'customer_phone': customerPhone,
    'party_size': partySize,
    'double_sofa': doubleSofa,
    'single_sofa': singleSofa,
    if (note != null) 'note': note,
    if (pickupLocationId != null) 'pickup_location_id': pickupLocationId,
    if (pickupLocationName != null) 'pickup_location_name': pickupLocationName,
    'trip_type': tripType.storageKey,
    'status': status,
    'assigned_seats': assignedSeats.map((a) => a.toMap()).toList(),
    if (customerEditedAt != null)
      'customer_edited_at': customerEditedAt!.toIso8601String(),
    'created_at': createdAt.toIso8601String(),
    if (lastRefreshedAt != null)
      'last_refreshed_at': lastRefreshedAt!.toIso8601String(),
    'tour_locked': tourLocked,
    'is_confirmed': isConfirmed,
    if (organiserPhone != null) 'organiser_phone': organiserPhone,
    if (cancelRequestedAt != null)
      'cancel_requested_at': cancelRequestedAt!.toIso8601String(),
    if (holdExpiresAt != null)
      'hold_expires_at': holdExpiresAt!.toIso8601String(),
    if (holdId != null) 'hold_id': holdId,
    if (advancePaise > 0) 'advance_paise': advancePaise,
    if (claimedPaise > 0) 'claimed_paise': claimedPaise,
    if (collectVpa != null) 'collect_vpa': collectVpa,
    if (collectPayeeName != null) 'collect_payee_name': collectPayeeName,
  };

  factory CustomerRequestEntry.fromJson(Map<String, dynamic> m) {
    return CustomerRequestEntry(
      id: m['id'] as String,
      tourId: m['tour_id'] as String,
      tourTitle: m['tour_title'] as String,
      tourFromCity: m['tour_from_city'] as String,
      tourToCity: m['tour_to_city'] as String,
      tourDepartureDate: DateTime.parse(m['tour_departure_date'] as String),
      tourPricePerSeat: (m['tour_price_per_seat'] as num).toDouble(),
      customerName: m['customer_name'] as String,
      customerPhone: m['customer_phone'] as String,
      partySize: m['party_size'] as int,
      doubleSofa: (m['double_sofa'] as int?) ?? 0,
      singleSofa: (m['single_sofa'] as int?) ?? 0,
      note: m['note'] as String?,
      pickupLocationId: m['pickup_location_id'] as String?,
      pickupLocationName: m['pickup_location_name'] as String?,
      tripType: TripType.fromString(m['trip_type'] as String?),
      status: (m['status'] as String?) ?? 'pending',
      assignedSeats: _parseAssignedSeats(m['assigned_seats']),
      customerEditedAt: m['customer_edited_at'] != null
          ? DateTime.tryParse(m['customer_edited_at'] as String)
          : null,
      createdAt: DateTime.parse(m['created_at'] as String),
      lastRefreshedAt: m['last_refreshed_at'] != null
          ? DateTime.tryParse(m['last_refreshed_at'] as String)
          : null,
      tourLocked: (m['tour_locked'] as bool?) ?? false,
      isConfirmed: (m['is_confirmed'] as bool?) ?? false,
      organiserPhone: m['organiser_phone'] as String?,
      holdExpiresAt: m['hold_expires_at'] != null
          ? DateTime.tryParse(m['hold_expires_at'] as String)
          : null,
      holdId: m['hold_id'] as String?,
      advancePaise: (m['advance_paise'] as num?)?.toInt() ?? 0,
      claimedPaise: (m['claimed_paise'] as num?)?.toInt() ?? 0,
      collectVpa: m['collect_vpa'] as String?,
      collectPayeeName: m['collect_payee_name'] as String?,
      cancelRequestedAt: m['cancel_requested_at'] != null
          ? DateTime.tryParse(m['cancel_requested_at'] as String)
          : null,
    );
  }

  /// Decode an `assigned_seats` value from either the local JSON cache or a
  /// Supabase RPC response. The server stores it as `jsonb` so it arrives as a
  /// list of `{busId, seatId}` maps; older device caches may still hold the
  /// pre-fix string list ("L1", "L2") — both shapes are accepted.
  static List<SeatAssignment> _parseAssignedSeats(dynamic value) {
    if (value is! List) return const [];
    final out = <SeatAssignment>[];
    for (final raw in value) {
      if (raw is Map) {
        final map = Map<String, dynamic>.from(raw);
        final seatId = map['seatId']?.toString();
        final busId = map['busId']?.toString();
        if (seatId == null || busId == null) continue;
        // Keep the per-seat leg when the server stamped one (mixed-leg requests)
        // so the customer's own one-way seat can render as a half — the coarse
        // request tripType is the fallback where a seat has no leg.
        out.add(
          SeatAssignment(
            busId: busId,
            seatId: seatId,
            leg: map['leg'] != null
                ? TripType.fromString(map['leg'].toString())
                : null,
          ),
        );
      }
      // Legacy bare-string entries had no busId — they can't be rendered on a
      // layout, so we drop them rather than fabricate a fake busId.
    }
    return out;
  }
}
