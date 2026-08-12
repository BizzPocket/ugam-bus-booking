import 'dart:convert';
import 'dart:developer' as dev;

import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/attendance.dart';
import '../models/bus_details.dart';
import '../models/bus_handover.dart';
import '../models/collection.dart';
import '../models/expense.dart';
import '../models/income_entry.dart';
import '../models/handler_manifest.dart';
import '../models/handler_phase.dart';
import '../models/handler_report.dart';
import '../models/handler_tour_ref.dart';
import '../models/seat_assignment.dart';
import '../models/seat_ticket.dart';
import '../models/trip_type.dart';
import 'chart_hold_status.dart';

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
  bool get canEdit => status == 'pending' && !hasSeatsAssigned;
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
      holdExpiresAt:
          clearHold ? null : (holdExpiresAt ?? this.holdExpiresAt),
      holdId: clearHold ? null : (holdId ?? this.holdId),
      advancePaise: advancePaise ?? this.advancePaise,
      collectVpa: collectVpa ?? this.collectVpa,
      collectPayeeName: collectPayeeName ?? this.collectPayeeName,
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
        out.add(SeatAssignment(
          busId: busId,
          seatId: seatId,
          leg: map['leg'] != null
              ? TripType.fromString(map['leg'].toString())
              : null,
        ));
      }
      // Legacy bare-string entries had no busId — they can't be rendered on a
      // layout, so we drop them rather than fabricate a fake busId.
    }
    return out;
  }
}

class CustomerRequestsStore {
  static const _key = 'customer_requests_v1';

  /// The last mobile number a seat lookup succeeded with — see
  /// [lastSeatLookupPhone].
  static const _lastPhoneKey = 'find_my_seat_last_phone_v1';

  static final CustomerRequestsStore _instance =
      CustomerRequestsStore._internal();
  factory CustomerRequestsStore() => _instance;
  CustomerRequestsStore._internal();

  Future<List<CustomerRequestEntry>> list() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return [];
    try {
      final decoded = jsonDecode(raw) as List;
      return decoded
          .map(
            (e) => CustomerRequestEntry.fromJson(
              Map<String, dynamic>.from(e as Map),
            ),
          )
          .toList()
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    } catch (_) {
      return [];
    }
  }

  Future<void> _persist(List<CustomerRequestEntry> entries) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _key,
      jsonEncode(entries.map((e) => e.toJson()).toList()),
    );
  }

  Future<void> add(CustomerRequestEntry entry) async {
    final all = await list();
    all.removeWhere((e) => e.id == entry.id);
    all.add(entry);
    await _persist(all);
  }

  Future<CustomerRequestEntry?> get(String id) async {
    final all = await list();
    for (final e in all) {
      if (e.id == id) return e;
    }
    return null;
  }

  Future<void> upsert(CustomerRequestEntry entry) => add(entry);

  /// Live state of the SEAT HOLD behind a chart booking, or null when this
  /// request has no hold (the ordinary request-mode case).
  ///
  /// Deliberately a SEPARATE RPC rather than an extension of
  /// `booking_request_status_lookup`: that function exists only in the live
  /// database and not in this repo, so replacing it blind would overwrite a
  /// definition nobody here can see. The two results are merged client-side
  /// instead.
  ///
  /// Returns null ONLY when the server genuinely reports no hold. Errors
  /// propagate — the caller must not read a failed lookup as "no hold", because
  /// that would resurrect the very bug this exists to fix.
  Future<ChartHoldSnapshot?> _lookupHold(String requestId) async {
    final result = await Supabase.instance.client.rpc(
      'chart_hold_status_lookup',
      params: {
        'p_request_ids': [requestId],
      },
    );
    if (result == null) return null;
    final rows = result as List;
    if (rows.isEmpty) return null;
    return ChartHoldSnapshot.fromMap(
      Map<String, dynamic>.from(rows.first as Map),
    );
  }

  Future<void> remove(String id) async {
    final all = await list();
    all.removeWhere((e) => e.id == id);
    await _persist(all);
  }

  /// Calls the booking_request_status_lookup RPC for [id] and merges the
  /// server's view (status / assigned_seats / customer_edited_at) back
  /// into the local entry. Returns the updated entry, or null if the row
  /// no longer exists on the server (e.g., admin deleted it).
  Future<CustomerRequestEntry?> refresh(String id) async {
    final existing = await get(id);
    if (existing == null) return null;
    final client = Supabase.instance.client;
    final result = await client.rpc(
      'booking_request_status_lookup',
      params: {'p_id': id},
    );
    if (result == null) return existing;
    final rows = result as List;
    if (rows.isEmpty) {
      // An empty booking lookup is NOT proof of deletion.
      //
      // On a tour that collects an advance, `chart_hold_seats` writes only a
      // `seat_holds` row; the booking_requests row appears later, from
      // `chart_finalize_hold`. So a live, seats-blocked, unpaid hold looks
      // exactly like a deleted request here. Branding those "Cancelled" is the
      // bug this branch used to ship: the customer's ticket died while the
      // chart still showed their berths taken.
      //
      // Ask the holds table before concluding anything.
      final ChartHoldSnapshot? hold;
      try {
        hold = await _lookupHold(id);
      } catch (e) {
        // Migration 067 not applied on this database yet, or the network
        // dropped mid-refresh. Either way we cannot tell a live hold from a
        // deletion — so change NOTHING. Guessing "deleted" is what produced
        // the cancelled-while-held bug, and it is the more damaging guess.
        dev.log(
          'hold lookup unavailable for $id; leaving status untouched',
          name: 'CustomerRequestsStore',
          error: e,
        );
        return existing;
      }

      final resolved = resolveMissingBookingRow(
        existing: existing,
        hold: hold,
        now: DateTime.now(),
      );
      if (identical(resolved, existing)) return existing;
      await upsert(resolved);
      return resolved;
    }
    final row = Map<String, dynamic>.from(rows.first as Map);
    // Seat assignments are provisional until the organiser locks the tour. The
    // lock flag now rides on the SAME lookup row (migration 037) so one atomic
    // read decides it; the legacy standalone RPC is only a fallback, and a
    // transient failure can never revert an already-locked ticket. See
    // [_resolveTourLocked].
    final locked = await _resolveTourLocked(id, row, existing.tourLocked);
    final updated = existing.copyWith(
      // A booking row now exists, so any hold behind it has been finalized.
      // Clearing the expiry stops a stale countdown ticking under a booking
      // that is already confirmed.
      clearHold: true,
      status: (row['status'] as String?) ?? existing.status,
      assignedSeats: CustomerRequestEntry._parseAssignedSeats(
        row['assigned_seats'],
      ),
      tripType: row['trip_type'] != null
          ? TripType.fromString(row['trip_type'] as String?)
          : existing.tripType,
      customerEditedAt: row['customer_edited_at'] != null
          ? DateTime.tryParse(row['customer_edited_at'] as String)
          : existing.customerEditedAt,
      lastRefreshedAt: DateTime.now(),
      tourLocked: locked,
      isConfirmed: (row['is_confirmed'] as bool?) ?? existing.isConfirmed,
      cancelRequestedAt: row['cancel_requested_at'] != null
          ? DateTime.tryParse(row['cancel_requested_at'] as String)
          : existing.cancelRequestedAt,
    );
    await upsert(updated);
    return updated;
  }

  /// Customer self-cancels a still-pending request. Routes through the
  /// `booking_request_customer_cancel` SECURITY DEFINER RPC (migration 034),
  /// which enforces the same not-confirmed / not-seated gate server-side. On a
  /// server-confirmed cancel it marks the local entry 'cancelled' and clears any
  /// stale seat data. Returns the updated entry, or null when the server refused
  /// (already confirmed/seated) or the row is gone — the caller surfaces that.
  Future<CustomerRequestEntry?> cancel(String id) async {
    final existing = await get(id);
    if (existing == null) return null;
    final client = Supabase.instance.client;
    final ok = await client.rpc(
      'booking_request_customer_cancel',
      params: {'p_id': id},
    );
    if (ok != true) return null;
    final cancelled = existing.copyWith(
      status: 'cancelled',
      assignedSeats: const [],
      tourLocked: false,
      lastRefreshedAt: DateTime.now(),
    );
    await upsert(cancelled);
    return cancelled;
  }

  /// Customer REQUESTS cancellation of a CONFIRMED / seat-assigned booking. This
  /// is the confirmed/seated counterpart to [cancel]: it does NOT free the seat,
  /// it only raises a request the organiser approves later. Routes through the
  /// `booking_request_customer_request_cancel` SECURITY DEFINER RPC (migration
  /// 035), which enforces the confirmed/seated gate server-side and mirrors the
  /// marker onto the passenger row so the organiser sees it. On success it stamps
  /// the local entry's [cancelRequestedAt] (status/seat untouched — the booking
  /// stays live until the organiser acts) and returns it; returns null when the
  /// server refused (still purely pending / already requested / gone) or on
  /// error — the caller surfaces that.
  Future<CustomerRequestEntry?> requestCancellation(String id) async {
    final existing = await get(id);
    if (existing == null) return null;
    final client = Supabase.instance.client;
    try {
      final ok = await client.rpc(
        'booking_request_customer_request_cancel',
        params: {'p_id': id},
      );
      if (ok != true) return null;
    } catch (_) {
      return null;
    }
    final updated = existing.copyWith(
      cancelRequestedAt: DateTime.now(),
      lastRefreshedAt: DateTime.now(),
    );
    await upsert(updated);
    return updated;
  }

  /// Resolve whether the request's tour is locked (seats final, may be revealed)
  /// during a refresh. Customers are anonymous and can't read tour status
  /// directly, so the value is server-provided:
  ///   1. Prefer the `tour_locked` column the single `booking_request_status_lookup`
  ///      now returns inline (migration 037) — one atomic read, no extra round trip.
  ///   2. Fall back to the legacy standalone `booking_request_tour_locked` RPC
  ///      when that column is absent (pre-037 server).
  ///   3. If neither yields a definite answer, KEEP the last known [previous]
  ///      value rather than failing to false. A tour only ever advances
  ///      locked → completed (never back), so a transient error must not flip an
  ///      already-revealed ticket back to the "seats being finalized" state.
  Future<bool> _resolveTourLocked(
    String requestId,
    Map<String, dynamic> row,
    bool previous,
  ) async {
    final inline = row['tour_locked'];
    if (inline is bool) return inline;
    try {
      final result = await Supabase.instance.client.rpc(
        'booking_request_tour_locked',
        params: {'p_id': requestId},
      );
      if (result is bool) return result;
    } catch (_) {
      // Fall through — keep the last known value below.
    }
    return previous;
  }

  /// Refreshes every entry. Errors on individual rows are swallowed so a
  /// flaky row doesn't kill the whole pull-to-refresh.
  Future<List<CustomerRequestEntry>> refreshAll() async {
    final all = await list();
    for (final e in all) {
      try {
        await refresh(e.id);
      } catch (_) {
        // ignore per-row failures
      }
    }
    return list();
  }

  /// Fetches just enough bus metadata (id, name, registration_no, layout) to
  /// render the seat layout for every bus that has a seat assigned to this
  /// customer's request. Customers are anonymous and can't `select` from
  /// `buses` directly, so this goes through a SECURITY DEFINER RPC.
  Future<List<Bus>> busLayoutsForRequest(String requestId) async {
    final client = Supabase.instance.client;
    final result = await client.rpc(
      'bus_layouts_for_request',
      params: {'p_id': requestId},
    );
    if (result is! List) return const [];
    return result
        .whereType<Map>()
        .map((m) => Bus.fromMap(Map<String, dynamic>.from(m)))
        .toList();
  }

  /// Occupant identity (name + phone) for every ASSIGNED seat on the request's
  /// tour, one entry per (busId, seatId) berth, via the lock-gated
  /// `bus_roster_for_request` RPC. Empty until the tour is locked.
  ///
  /// PRIVACY: this returns the FULL roster's contact details to the (anonymous)
  /// customer — the organiser's deliberate choice so co-travellers can
  /// coordinate boarding (see migration 041). Do not repurpose it for a context
  /// where a rider must not see co-travellers.
  Future<List<({String busId, String seatId, String name, String phone})>>
  seatRosterForRequest(String requestId) async {
    final client = Supabase.instance.client;
    final result = await client.rpc(
      'bus_roster_for_request',
      params: {'p_id': requestId},
    );
    if (result is! List) return const [];
    return result
        .whereType<Map>()
        .map(
          (m) => (
            busId: (m['bus_id'] ?? '').toString(),
            seatId: (m['seat_id'] ?? '').toString(),
            name: (m['name'] ?? '').toString(),
            phone: (m['phone'] ?? '').toString(),
          ),
        )
        .toList();
  }

  /// The mobile number that last resolved to a seat on this device, if any.
  ///
  /// A manually-added passenger has no local booking journal entry, so their
  /// number is the ONLY thing the app can remember about them. Persisting it
  /// turns the second visit into a single tap: the home-screen field and the
  /// lookup screen both open pre-filled, and the lookup runs itself.
  Future<String?> lastSeatLookupPhone() async {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getString(_lastPhoneKey)?.trim();
    return (v == null || v.isEmpty) ? null : v;
  }

  /// Remembers [phone] as the number to pre-fill next time. Only ever called
  /// after a lookup actually returned something, so a typo is never sticky.
  Future<void> rememberSeatLookupPhone(String phone) async {
    final trimmed = phone.trim();
    if (trimmed.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_lastPhoneKey, trimmed);
  }

  /// "Find my seat by phone": resolves every seat held under [phone] on a
  /// LOCKED/completed tour, with the bus diagram(s) to draw them — bypassing
  /// booking_requests entirely so manually-added passengers (who have no in-app
  /// ticket) can still see their seat. Phone is matched on its last 10 digits
  /// server-side, so +91 / spaces never cause a miss. Goes through the
  /// `seat_lookup_by_phone` SECURITY DEFINER RPC (customers are anonymous).
  Future<List<SeatTicket>> seatsByPhone(String phone) async {
    final client = Supabase.instance.client;
    final result = await client.rpc(
      'seat_lookup_by_phone',
      params: {'p_phone': phone},
    );
    if (result is! List) return const [];
    return result
        .whereType<Map>()
        .map((m) => SeatTicket.fromJson(Map<String, dynamic>.from(m)))
        .toList();
  }

  /// "Find tours I handle by phone": resolves every tour where [phone] is the
  /// designated handler into a booking_request ref the UI can feed straight to
  /// the existing requestId-scoped HandlerBusChartScreen flow — no request id
  /// entered by hand. Phone is matched on its last 10 digits server-side, so
  /// +91 / spaces never cause a miss. Goes through the `handler_requests_by_phone`
  /// SECURITY DEFINER RPC (handlers are anonymous). Tours whose handler has no
  /// booking_request aren't returned (they can't be managed via that flow).
  Future<List<HandlerTourRef>> handlerRequestsByPhone(String phone) async {
    final client = Supabase.instance.client;
    final result = await client.rpc(
      'handler_requests_by_phone',
      params: {'p_phone': phone},
    );
    if (result is! List) return const [];
    return result
        .whereType<Map>()
        .map((m) => HandlerTourRef.fromJson(Map<String, dynamic>.from(m)))
        .toList();
  }

  /// Whether this request belongs to the tour's designated handler. Only the
  /// handler may pull the full bus chart, so the UI gates on this first. Goes
  /// through a SECURITY DEFINER RPC since customers are anonymous. Any error
  /// or null result is treated as "not a handler".
  Future<bool> isRequestHandler(String requestId) async {
    final client = Supabase.instance.client;
    try {
      final result = await client.rpc(
        'is_request_handler',
        params: {'p_request_id': requestId},
      );
      return result as bool? ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Fetches the full tour manifest (every bus + every passenger) for the
  /// handler tied to [requestId]. Returns null when the RPC yields null (e.g.
  /// the request isn't a handler). Customers are anonymous, so this goes
  /// through a SECURITY DEFINER RPC.
  Future<HandlerManifest?> handlerTourManifest(String requestId) async {
    final client = Supabase.instance.client;
    final result = await client.rpc(
      'handler_tour_manifest',
      params: {'p_request_id': requestId},
    );
    if (result == null) return null;
    return HandlerManifest.fromJson(Map<String, dynamic>.from(result as Map));
  }

  /// Records the customer's assertion that they paid a UPI advance for
  /// [requestId] (migration 060).
  ///
  /// This is NOT a payment confirmation. The QR is a direct UPI deep-link to
  /// the organiser's own VPA — zero-MDR precisely because no gateway sits in
  /// the middle, so nothing ever calls the app back to say the transfer
  /// landed. The agent verifies it against their bank statement before it
  /// becomes money.
  ///
  /// Recording it unverified is still the fix for the real defect: without any
  /// record at all, the handler's collect sheet prices from the fare alone and
  /// charges the advance a SECOND time on the bus. A pending claim is visible
  /// to both the agent and the handler immediately.
  ///
  /// Returns the claim id, or null when the server refused (unknown booking,
  /// rate limit, implausible amount). Never throws — a failed claim must not
  /// block a booking that has already succeeded.
  Future<String?> claimUpiAdvance({
    required String requestId,
    required int amountPaise,
    String? reference,
  }) async {
    try {
      final result = await Supabase.instance.client.rpc(
        'claim_upi_advance',
        params: {
          'p_request_id': requestId,
          'p_amount_paise': amountPaise,
          'p_upi_ref': reference,
        },
      );
      return result?.toString();
    } catch (e) {
      dev.log('claimUpiAdvance failed for $requestId — $e',
          name: 'CustomerRequestsStore');
      return null;
    }
  }

  /// UPI claim against a soft seat hold (advance chart flow) — no passenger yet.
  Future<String?> claimUpiAdvanceForHold({
    required String holdId,
    required int amountPaise,
    String? reference,
  }) async {
    try {
      final result = await Supabase.instance.client.rpc(
        'claim_upi_advance_for_hold',
        params: {
          'p_hold_id': holdId,
          'p_amount_paise': amountPaise,
          'p_upi_ref': reference,
        },
      );
      return result?.toString();
    } catch (e) {
      dev.log('claimUpiAdvanceForHold failed for $holdId — $e',
          name: 'CustomerRequestsStore');
      return null;
    }
  }

  /// Inserts or updates a passenger [Collection] for the handler's tour via a
  /// SECURITY DEFINER RPC (customers are anonymous). The collection is sent as a
  /// jsonb payload; the server resolves the tour from the request and verifies
  /// the bus + passenger belong to it. Returns the upserted row, or null when
  /// the caller isn't the tour's handler. Lets exceptions propagate so the UI
  /// can surface a real failure.
  Future<Collection?> handlerUpsertCollection(
    String requestId,
    Collection c,
  ) async {
    final client = Supabase.instance.client;
    final result = await client.rpc(
      'handler_upsert_collection',
      params: {'p_request_id': requestId, 'p_collection': c.toMap()},
    );
    if (result is! Map) return null;
    return Collection.fromMap(Map<String, dynamic>.from(result));
  }

  /// Inserts or updates an [Attendance] row for the handler's tour via a
  /// SECURITY DEFINER RPC (customers are anonymous). The attendance is sent as a
  /// jsonb payload; the server resolves the tour from the request and verifies
  /// the bus + passenger belong to it. Returns the upserted row, or null when
  /// the caller isn't the tour's handler. Lets exceptions propagate so the UI
  /// can surface a real failure.
  Future<Attendance?> handlerUpsertAttendance(
    String requestId,
    Attendance a,
  ) async {
    final client = Supabase.instance.client;
    final result = await client.rpc(
      'handler_upsert_attendance',
      params: {'p_request_id': requestId, 'p_attendance': a.toMap()},
    );
    if (result is! Map) return null;
    return Attendance.fromMap(Map<String, dynamic>.from(result));
  }

  /// Inserts or updates a bus [Expense] for the handler's tour via a SECURITY
  /// DEFINER RPC (customers are anonymous). The expense is sent as a jsonb
  /// payload; the server resolves the tour from the request and verifies the
  /// bus belongs to it. Returns the upserted row, or null when the caller isn't
  /// the tour's handler (or the bus isn't on their tour). Lets exceptions
  /// propagate so the UI can surface a real failure.
  Future<Expense?> handlerUpsertExpense(String requestId, Expense e) async {
    final client = Supabase.instance.client;
    final result = await client.rpc(
      'handler_upsert_expense',
      params: {'p_request_id': requestId, 'p_expense': e.toMap()},
    );
    if (result is! Map) return null;
    return Expense.fromMap(Map<String, dynamic>.from(result));
  }

  /// Deletes one expense the handler logged on their own tour via a SECURITY
  /// DEFINER RPC. Returns true when a row was removed (false when the caller
  /// isn't the handler or the expense isn't on their tour).
  Future<bool> handlerDeleteExpense(String requestId, String expenseId) async {
    final client = Supabase.instance.client;
    final result = await client.rpc(
      'handler_delete_expense',
      params: {'p_request_id': requestId, 'p_expense_id': expenseId},
    );
    return result as bool? ?? false;
  }

  /// Inserts or updates a bus [IncomeEntry] for the handler's tour via a SECURITY
  /// DEFINER RPC (customers are anonymous). The income is sent as a jsonb
  /// payload; the server resolves the tour from the request and verifies the
  /// bus belongs to it. Returns the upserted row, or null when the caller isn't
  /// the tour's handler (or the bus isn't on their tour). Lets exceptions
  /// propagate so the UI can surface a real failure.
  Future<IncomeEntry?> handlerUpsertIncome(
    String requestId,
    IncomeEntry i,
  ) async {
    final client = Supabase.instance.client;
    final result = await client.rpc(
      'handler_upsert_income',
      params: {'p_request_id': requestId, 'p_income': i.toMap()},
    );
    if (result is! Map) return null;
    return IncomeEntry.fromMap(Map<String, dynamic>.from(result));
  }

  /// Deletes one income the handler logged on their own tour via a SECURITY
  /// DEFINER RPC. Returns true when a row was removed (false when the caller
  /// isn't the handler or the income isn't on their tour).
  Future<bool> handlerDeleteIncome(String requestId, String incomeId) async {
    final client = Supabase.instance.client;
    final result = await client.rpc(
      'handler_delete_income',
      params: {'p_request_id': requestId, 'p_income_id': incomeId},
    );
    return result as bool? ?? false;
  }

  /// Every cash handover recorded against the buses this handler runs — the
  /// ones they logged themselves AND any the admin entered from the other side,
  /// so the handler sees the whole settlement picture for their bus.
  ///
  /// Deliberately NOT part of `handler_tour_manifest`: that RPC has been
  /// re-created verbatim across a dozen migrations and its live body has drifted
  /// from the files, so handovers are read through their own RPC rather than
  /// risk rewriting the manifest from a stale copy. Returns an empty list when
  /// the caller isn't a handler.
  Future<List<BusHandover>> handlerBusHandovers(String requestId) async {
    final client = Supabase.instance.client;
    final result = await client.rpc(
      'handler_bus_handovers',
      params: {'p_request_id': requestId},
    );
    if (result is! List) return const [];
    return result
        .whereType<Map>()
        .map((m) => BusHandover.fromMap(Map<String, dynamic>.from(m)))
        .toList();
  }

  /// Records (or corrects) one cash handover the handler made to the admin, via
  /// a SECURITY DEFINER RPC — handlers are anonymous, and `bus_handovers` is
  /// owner-only under RLS. The server resolves the tour, verifies the bus is one
  /// the CALLER handles, and stamps `source='handler'`; an admin-recorded row
  /// can never be overwritten this way. Returns the saved row, or null when the
  /// write was rejected. Lets exceptions propagate so the UI can surface a real
  /// failure.
  Future<BusHandover?> handlerUpsertHandover(
    String requestId,
    BusHandover h,
  ) async {
    final client = Supabase.instance.client;
    final result = await client.rpc(
      'handler_upsert_handover',
      params: {'p_request_id': requestId, 'p_handover': h.toMap()},
    );
    if (result is! Map) return null;
    return BusHandover.fromMap(Map<String, dynamic>.from(result));
  }

  /// Deletes one handover the handler logged themselves. Returns true when a row
  /// was removed — false for a non-handler, a bus they don't run, or a row the
  /// admin recorded (those stay read-only on the handler side).
  Future<bool> handlerDeleteHandover(
    String requestId,
    String handoverId,
  ) async {
    final client = Supabase.instance.client;
    final result = await client.rpc(
      'handler_delete_handover',
      params: {'p_request_id': requestId, 'p_handover_id': handoverId},
    );
    return result as bool? ?? false;
  }

  /// How far the handler's own bus has got through the journey.
  ///
  /// Deliberately its own RPC rather than new fields on `handler_tour_manifest`:
  /// that function's live body has drifted from the migration files, so it is
  /// never rewritten from a stale copy (the same reason handovers read through
  /// their own RPC). It supplies the one thing the manifest omits —
  /// `journey_done` — which is what tells the UI whether the GO leg is finished.
  /// Returns an empty list when the caller isn't a handler.
  Future<List<HandlerBusLegState>> handlerBusLegState(String requestId) async {
    final client = Supabase.instance.client;
    final result = await client.rpc(
      'handler_bus_leg_state',
      params: {'p_request_id': requestId},
    );
    if (result is! List) return const [];
    return result.whereType<Map>().map((m) {
      int n(String k) => (m[k] as num?)?.toInt() ?? 0;
      return (
        busId: (m['bus_id'] ?? '').toString(),
        outboundOnlyTotal: n('outbound_only_total'),
        outboundOnlyDone: n('outbound_only_done'),
        ridersOnOutbound: n('riders_on_outbound'),
        ridersOnReturn: n('riders_on_return'),
      );
    }).toList();
  }

  /// Finishes the GO leg for ONE bus the handler runs: every outbound-only
  /// rider on it has completed their only journey, so their seats on this bus
  /// are released and they are marked `journey_done`. Round-trip and
  /// return-only riders are untouched.
  ///
  /// The server freezes this bus's outbound chart into `tour_seat_snapshots`
  /// in the SAME transaction before releasing anything, so — unlike the admin's
  /// best-effort client-side capture — seats can never be destroyed without
  /// their history being kept. Returns the number of riders cleared, or null
  /// when the caller doesn't handle that bus. Lets exceptions propagate so the
  /// UI can surface a real failure.
  Future<int?> handlerCompleteOutboundLeg(
    String requestId,
    String busId,
  ) async {
    final client = Supabase.instance.client;
    final result = await client.rpc(
      'handler_complete_outbound_leg',
      params: {'p_request_id': requestId, 'p_bus_id': busId},
    );
    return (result as num?)?.toInt();
  }

  // ── Trip milestones (migration 090) ───────────────────────

  /// The departure / arrival / completion stamps for every bus this handler
  /// runs. These drive [resolveHandlerPhase], so they decide what the whole
  /// handler surface points at.
  ///
  /// Its own RPC for the same reason as leg state and handovers: the manifest's
  /// live body has drifted from the migration files and is never rewritten.
  /// Returns an empty list when the caller isn't a handler.
  Future<List<HandlerTripState>> handlerBusTripState(String requestId) async {
    final client = Supabase.instance.client;
    final result = await client.rpc(
      'handler_bus_trip_state',
      params: {'p_request_id': requestId},
    );
    if (result is! List) return const [];
    return result.whereType<Map>().map(HandlerTripState.fromMap).toList();
  }

  /// Stamps one trip milestone on one bus and returns the bus's whole updated
  /// state.
  ///
  /// The milestone is sent by NAME and the server stamps `now()` itself rather
  /// than trusting a client clock — a handler's phone can be hours out, and
  /// these timestamps order the trip. The RPC is idempotent per milestone: a
  /// retry on a flaky link re-stamps nothing and returns the existing row, so
  /// the double-tap and the lost-response retry are both harmless.
  Future<HandlerTripState?> handlerStampMilestone(
    String requestId,
    String busId,
    HandlerMilestone milestone,
  ) async {
    final client = Supabase.instance.client;
    final result = await client.rpc(
      'handler_stamp_milestone',
      params: {
        'p_request_id': requestId,
        'p_bus_id': busId,
        'p_milestone': milestone.name,
      },
    );
    if (result is! Map) return null;
    return HandlerTripState.fromMap(result);
  }

  // ── Problem reports (migration 090) ───────────────────────

  /// Reports this handler has already raised, newest first — so the Trip tab
  /// can show what was sent and whether the agent has seen it.
  Future<List<HandlerReport>> handlerReports(String requestId) async {
    final client = Supabase.instance.client;
    final result = await client.rpc(
      'handler_reports',
      params: {'p_request_id': requestId},
    );
    if (result is! List) return const [];
    return result.whereType<Map>().map(HandlerReport.fromMap).toList();
  }

  /// Raises a problem with the agent from the bus.
  ///
  /// The client mints the id so a retry after a lost response updates the same
  /// row instead of filing the breakdown twice — the same idempotency the cash
  /// writes needed. Returns the saved row, or null when rejected.
  Future<HandlerReport?> handlerCreateReport(
    String requestId,
    HandlerReport report,
  ) async {
    final client = Supabase.instance.client;
    final result = await client.rpc(
      'handler_create_report',
      params: {'p_request_id': requestId, 'p_report': report.toMap()},
    );
    if (result is! Map) return null;
    return HandlerReport.fromMap(result);
  }
}

/// Per-bus journey progress for the handler, from `handler_bus_leg_state`.
typedef HandlerBusLegState = ({
  String busId,
  int outboundOnlyTotal,
  int outboundOnlyDone,
  int ridersOnOutbound,
  int ridersOnReturn,
});
