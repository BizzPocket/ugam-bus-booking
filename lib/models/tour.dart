import 'dart:math' as math;

import 'package:uuid/uuid.dart';
import 'booking_mode.dart';
import 'tour_status.dart';
import 'bus_details.dart';
import 'passenger.dart';
import 'passenger_group.dart';

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

  /// Local departure time-of-day on [departureDate] in 'HH:mm' 24h form.
  /// Null when the agent hasn't set a time — kept separate from the date so
  /// an unset time stays distinguishable from midnight.
  final String? departureTime;
  final DateTime? returnDate;

  /// Local return time-of-day on [returnDate] in 'HH:mm' 24h form. Null when
  /// unset (no return date, or date set without a time).
  final String? returnTime;
  final double pricePerSeat;
  final String? description;
  final TourStatus status;
  final String? ownerId;
  final String? busId;
  final String? handlerId;
  final String? createdBy;
  final bool isPublic;

  /// How customers book seats on this tour (migration 048). Defaults to
  /// [BookingMode.request] — the legacy flow — so every pre-048 tour is
  /// untouched.
  ///
  /// DELIBERATELY ABSENT FROM [toMap]: PostgREST rejects the WHOLE payload when
  /// it carries a column the live schema doesn't have yet, so shipping this in
  /// the tour insert/update would break EVERY tour write on any server where
  /// 048 hasn't been applied. It is read here and written only through
  /// `TourController.setBookingMode`, whose single-column update can fail
  /// loudly on its own without taking tour create/edit down with it.
  final BookingMode bookingMode;

  /// Phase-2 broadcast composed at create time: the announcement text sent to
  /// the agent's audience via WhatsApp, plus an optional hero image URL
  /// (Supabase Storage). Both null until the agent fills the broadcast composer.
  final String? broadcastMessage;
  final String? broadcastImageUrl;

  final DateTime createdAt;
  final DateTime updatedAt;

  // Embedded by sync layer (not stored in Tour document)
  final List<Bus> buses;
  final List<Passenger> passengers;
  final List<PassengerGroup> groups;

  Tour({
    String? id,
    required this.title,
    required this.fromCity,
    required this.toCity,
    required this.departureDate,
    this.departureTime,
    this.returnDate,
    this.returnTime,
    required this.pricePerSeat,
    this.description,
    this.status = TourStatus.planning,
    this.ownerId,
    this.busId,
    this.handlerId,
    this.createdBy,
    this.isPublic = true,
    this.bookingMode = BookingMode.request,
    this.broadcastMessage,
    this.broadcastImageUrl,
    this.buses = const [],
    this.passengers = const [],
    this.groups = const [],
    DateTime? createdAt,
    DateTime? updatedAt,
  })  : id = id ?? const Uuid().v4(),
        createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  String get route => '$fromCity → $toCity';
  int get passengerCount => passengers.length;

  /// Whether this tour still accepts a NEW booking request / passenger.
  /// Delegates to [TourStatus.acceptsBookings] so every "book"/"add request"
  /// surface (customer + admin/handler) gates on one shared rule. Closed once
  /// the tour is locked or completed.
  bool get acceptsBookings => status.acceptsBookings;

  /// Buses on this tour that actually have a drawable seat chart.
  Iterable<Bus> get chartableBuses =>
      buses.where((b) => (b.layout?.totalSeats ?? 0) > 0);

  /// Whether the customer seat chart is SELLABLE right now: chart mode, still
  /// open for bookings, and at least one bus with a layout to tap on.
  ///
  /// This is the one real ordering change chart mode imposes — a customer can't
  /// pick a seat that doesn't exist yet, so the vehicle has to be attached
  /// before the tour can sell, instead of being booked after demand is tallied.
  bool get sellsFromChart =>
      bookingMode.isChart && acceptsBookings && chartableBuses.isNotEmpty;

  /// A chart-mode tour held back purely because no bus has a layout yet — the
  /// organiser-facing "add a bus to open bookings" state.
  bool get chartNeedsBus => bookingMode.isChart && chartableBuses.isEmpty;

  int get totalSeatsRequested =>
      passengers.fold(0, (sum, p) => sum + p.totalSeatsRequested);

  int get totalSeatsAssigned =>
      passengers.fold(0, (sum, p) => sum + p.totalSeatsAssigned);

  /// Berths still needing assignment for ACTIVE riders only — the count that
  /// drives the "allocate N more seats" next-step everywhere.
  ///
  /// A passenger whose leg is finished ([Passenger.journeyDone]) is
  /// intentionally seatless and is excluded, so completing the GO leg never
  /// re-shows the card. Measured PER RIDER in physical berths
  /// (`max(0, seatBerths − totalSeatsAssigned)`) so it matches
  /// [Passenger.isFullyAssigned]: a Double Sofa counts as two on both sides
  /// (never the old unit-vs-berth skew that could go negative or hide a
  /// half-filled double), and it is never negative. The raw `totalSeats*`
  /// getters stay whole-roster for seats-sold / revenue.
  int get pendingSeatsToAssign => passengers
      .where((p) => !p.journeyDone)
      .fold(0, (sum, p) => sum + math.max(0, p.seatBerths - p.totalSeatsAssigned));

  /// True once the GO (outbound) leg has been completed: completeOutboundLeg
  /// marks every one-way rider [Passenger.journeyDone], so that flag IS the
  /// "GO done" signal — no separate DB column needed.
  bool get goLegCompleted => passengers.any((p) => p.journeyDone);

  /// The tour is locked AND its GO leg is done → the RETURN-leg phase: outbound
  /// riders have left, their seats are free to resell as return tickets, and the
  /// agent can still cancel/replace return riders before completing the trip.
  bool get isReturnPhase =>
      status == TourStatus.locked && goLegCompleted;

  int get totalBusSeats => buses.fold(0, (sum, b) => sum + b.totalSeats);

  /// Leg-aware berths occupied per bus — the BUSIER leg's load, `max(GO, RET)`.
  ///
  /// A physical berth offers ONE outbound slot and ONE return slot, so two
  /// opposite one-way riders share a single seat (GO on one, RET on the other)
  /// and produce TWO [SeatAssignment] entries on ONE berth. Counting raw
  /// entries double-counts that berth — pushing a bus PAST capacity ("38/37")
  /// and reading "full" while a seat sits physically empty. The honest load is
  /// the busier leg, which never exceeds capacity and never reads full while a
  /// berth is free. Distinct from [totalSeatsAssigned] (raw entries), which
  /// stays the unit for "seats sold" — a leg-shared berth is still two fares.
  ///
  /// Leg load is now PER REQUEST LINE: a [SeatAssignment] carries no leg, so we
  /// can't tag each seat, but [Passenger.goBerths]/[Passenger.retBerths] are the
  /// whole-passenger per-line leg totals. For each passenger we contribute
  /// `min(seatsOnBus, goBerths)` to GO and `min(seatsOnBus, retBerths)` to RET —
  /// EXACT when the passenger's seats sit on one bus (the engine keeps them
  /// together), a safe upper bound otherwise.
  Map<String, int> occupiedBerthsByBus() {
    final go = <String, int>{};
    final ret = <String, int>{};
    final busIds = <String>{};
    for (final p in passengers) {
      final perBus = <String, int>{};
      for (final a in p.assignedSeats) {
        busIds.add(a.busId);
        perBus[a.busId] = (perBus[a.busId] ?? 0) + 1;
      }
      perBus.forEach((busId, seatsOnBus) {
        go[busId] = (go[busId] ?? 0) + math.min(seatsOnBus, p.goBerths);
        ret[busId] = (ret[busId] ?? 0) + math.min(seatsOnBus, p.retBerths);
      });
    }
    return {
      for (final id in busIds) id: math.max(go[id] ?? 0, ret[id] ?? 0),
    };
  }

  /// Leg-aware berths occupied on one bus — `max(GO, RET)`. See
  /// [occupiedBerthsByBus]. Leg load is per request line: each passenger
  /// contributes `min(seatsOnBus, goBerths)` / `min(seatsOnBus, retBerths)`.
  int occupiedBerthsFor(String busId) {
    var go = 0;
    var ret = 0;
    for (final p in passengers) {
      var seatsOnBus = 0;
      for (final a in p.assignedSeats) {
        if (a.busId == busId) seatsOnBus++;
      }
      if (seatsOnBus == 0) continue;
      go += math.min(seatsOnBus, p.goBerths);
      ret += math.min(seatsOnBus, p.retBerths);
    }
    return math.max(go, ret);
  }

  /// Leg-aware berths occupied across every bus on this tour — the sum of each
  /// bus's busier leg. The honest "seats placed" total, free of the leg-share
  /// double-count that lets [totalSeatsAssigned] exceed [totalBusSeats].
  int get occupiedBerths =>
      occupiedBerthsByBus().values.fold(0, (sum, n) => sum + n);

  /// Seat capacity of the single LARGEST bus on this tour, in berths. A
  /// cross-booking group must ride ONE bus, so this is the largest group that
  /// can possibly be seated together. Zero when the tour has no buses yet (in
  /// which case group sizing can't be enforced).
  int get biggestBusSeats =>
      buses.isEmpty ? 0 : buses.map((b) => b.totalSeats).reduce(math.max);

  /// Total seat berths needed by every member of [groupId] — the group's size
  /// measured against [biggestBusSeats].
  int groupSeatBerths(String groupId) => passengers
      .where((p) => p.groupId == groupId)
      .fold(0, (sum, p) => sum + p.seatBerths);

  int get paidCount =>
      passengers.where((p) => p.paymentStatus.name == 'paid').length;

  Passenger? get handler => handlerId != null
      ? passengers.cast<Passenger?>().firstWhere(
            (p) => p?.id == handlerId,
            orElse: () => null,
          )
      : null;

  bool get allSeatsAssigned {
    // Passengers whose leg is finished (journeyDone) are intentionally seatless
    // — ignore them so a completed GO leg never blocks the lock gate.
    final active = passengers.where((p) => !p.journeyDone);
    return active.isNotEmpty && active.every((p) => p.isFullyAssigned);
  }

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
        'departure_time': departureTime,
        'return_date': returnDate?.toIso8601String().split('T').first,
        'return_time': returnTime,
        'price_per_seat': pricePerSeat,
        if (description != null) 'description': description,
        'status': status.name,
        if (handlerId != null) 'handler_id': handlerId,
        if (createdBy != null) 'created_by': createdBy,
        'is_public': isPublic,
        if (broadcastMessage != null) 'broadcast_message': broadcastMessage,
        if (broadcastImageUrl != null) 'broadcast_image_url': broadcastImageUrl,
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

    List<PassengerGroup> groups = const [];
    if (map['groups'] is List) {
      groups = (map['groups'] as List)
          .whereType<Map>()
          .map((g) => PassengerGroup.fromMap(Map<String, dynamic>.from(g)))
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
      departureTime: _parseTime(map['departure_time']),
      returnDate: map['return_date'] != null
          ? _parseDate(map['return_date'])
          : null,
      returnTime: _parseTime(map['return_time']),
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
      // Absent on a pre-048 server -> BookingMode.request, i.e. today's flow.
      bookingMode: BookingMode.fromString(map['booking_mode']?.toString()),
      broadcastMessage: map['broadcast_message']?.toString(),
      broadcastImageUrl: map['broadcast_image_url']?.toString(),
      buses: buses,
      passengers: passengers,
      groups: groups,
      createdAt: _parseDate(map['created_at']),
      updatedAt: _parseDate(map['updated_at']),
    );
  }

  static DateTime _parseDate(dynamic v) {
    if (v == null) return DateTime.now();
    if (v is DateTime) return v;
    return DateTime.tryParse(v.toString()) ?? DateTime.now();
  }

  /// Normalises a stored time to 'HH:mm'. Accepts Postgres `time` values
  /// ('HH:mm:ss') and bare 'HH:mm'; returns null for empty/invalid input.
  static String? _parseTime(dynamic v) {
    if (v == null) return null;
    final s = v.toString().trim();
    if (s.isEmpty) return null;
    final parts = s.split(':');
    if (parts.length < 2) return null;
    final h = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    if (h == null || m == null) return null;
    return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
  }

  Tour copyWith({
    String? title,
    String? fromCity,
    String? toCity,
    DateTime? departureDate,
    String? departureTime,
    DateTime? returnDate,
    String? returnTime,
    double? pricePerSeat,
    String? description,
    TourStatus? status,
    String? ownerId,
    String? busId,
    String? handlerId,
    String? createdBy,
    bool? isPublic,
    BookingMode? bookingMode,
    String? broadcastMessage,
    String? broadcastImageUrl,
    List<Bus>? buses,
    List<Passenger>? passengers,
    List<PassengerGroup>? groups,
    DateTime? updatedAt,
  }) {
    return Tour(
      id: id,
      title: title ?? this.title,
      fromCity: fromCity ?? this.fromCity,
      toCity: toCity ?? this.toCity,
      departureDate: departureDate ?? this.departureDate,
      departureTime: departureTime ?? this.departureTime,
      returnDate: returnDate ?? this.returnDate,
      returnTime: returnTime ?? this.returnTime,
      pricePerSeat: pricePerSeat ?? this.pricePerSeat,
      description: description ?? this.description,
      status: status ?? this.status,
      ownerId: ownerId ?? this.ownerId,
      busId: busId ?? this.busId,
      handlerId: handlerId ?? this.handlerId,
      createdBy: createdBy ?? this.createdBy,
      isPublic: isPublic ?? this.isPublic,
      bookingMode: bookingMode ?? this.bookingMode,
      broadcastMessage: broadcastMessage ?? this.broadcastMessage,
      broadcastImageUrl: broadcastImageUrl ?? this.broadcastImageUrl,
      buses: buses ?? this.buses,
      passengers: passengers ?? this.passengers,
      groups: groups ?? this.groups,
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
