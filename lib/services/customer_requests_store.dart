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
import '../models/payment_claim.dart';
import '../models/handler_tour_ref.dart';
import '../models/seat_assignment.dart';
import '../models/seat_ticket.dart';
import '../models/trip_type.dart';
import '../utils/trip_auto_complete.dart';
import 'chart_hold_status.dart';

part 'customer_request_entry.dart';
part 'customer_requests_handler_rpcs.dart';

class CustomerRequestsStore with _CustomerRequestsHandlerRpcs {
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
}

/// Per-bus journey progress for the handler, from `handler_bus_leg_state`.
typedef HandlerBusLegState = ({
  String busId,
  int outboundOnlyTotal,
  int outboundOnlyDone,
  int ridersOnOutbound,
  int ridersOnReturn,
});
