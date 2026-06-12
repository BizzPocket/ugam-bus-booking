import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/bus_details.dart';
import '../models/collection.dart';
import '../models/expense.dart';
import '../models/handler_manifest.dart';
import '../models/seat_assignment.dart';
import '../models/trip_type.dart';

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
  final TripType tripType;
  final String status;
  final List<SeatAssignment> assignedSeats;
  final DateTime? customerEditedAt;
  final DateTime createdAt;
  final DateTime? lastRefreshedAt;

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
    this.tripType = TripType.roundTrip,
    this.status = 'pending',
    this.assignedSeats = const [],
    this.customerEditedAt,
    required this.createdAt,
    this.lastRefreshedAt,
  });

  bool get hasSeatsAssigned => assignedSeats.isNotEmpty;
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
    TripType? tripType,
    String? status,
    List<SeatAssignment>? assignedSeats,
    DateTime? customerEditedAt,
    DateTime? lastRefreshedAt,
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
      tripType: tripType ?? this.tripType,
      status: status ?? this.status,
      assignedSeats: assignedSeats ?? this.assignedSeats,
      customerEditedAt: customerEditedAt ?? this.customerEditedAt,
      createdAt: createdAt,
      lastRefreshedAt: lastRefreshedAt ?? this.lastRefreshedAt,
    );
  }

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
    'trip_type': tripType.storageKey,
    'status': status,
    'assigned_seats': assignedSeats.map((a) => a.toMap()).toList(),
    if (customerEditedAt != null)
      'customer_edited_at': customerEditedAt!.toIso8601String(),
    'created_at': createdAt.toIso8601String(),
    if (lastRefreshedAt != null)
      'last_refreshed_at': lastRefreshedAt!.toIso8601String(),
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
        out.add(SeatAssignment(busId: busId, seatId: seatId));
      }
      // Legacy bare-string entries had no busId — they can't be rendered on a
      // layout, so we drop them rather than fabricate a fake busId.
    }
    return out;
  }
}

class CustomerRequestsStore {
  static const _key = 'customer_requests_v1';

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
      // The booking_request → tours JOIN returned nothing: the organiser
      // deleted the tour (or the request). Flag the local ticket as
      // cancelled so it drops out of the active Pending/Confirmed tabs and
      // surfaces under "Cancelled" instead of lingering as if still live.
      if (existing.status == 'rejected') return existing;
      final cancelled = existing.copyWith(
        status: 'rejected',
        lastRefreshedAt: DateTime.now(),
      );
      await upsert(cancelled);
      return cancelled;
    }
    final row = Map<String, dynamic>.from(rows.first as Map);
    final updated = existing.copyWith(
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
    );
    await upsert(updated);
    return updated;
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
}
