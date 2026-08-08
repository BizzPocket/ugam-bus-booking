import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/bus_details.dart';
import '../models/trip_type.dart';
import '../utils/chart_seat_availability.dart';
import '../utils/chart_selection.dart';
import '../utils/tour_public_summary.dart';

/// Outcome of a `chart_claim_seats` call.
///
/// A claim either wholly succeeds or wholly fails — there is no partial write.
/// [conflicts] names the seats that were lost (taken in the meantime, held back
/// by the organiser, or unknown), so the UI can point at them on the chart
/// instead of showing a generic error.
class ChartClaimResult {
  final bool ok;
  final String? requestId;
  final String? passengerId;
  final int berths;
  final List<String> conflicts;

  /// Set when the server refused outright (tour closed, bad leg, too many
  /// seats) rather than losing a race.
  final String? errorMessage;

  const ChartClaimResult({
    required this.ok,
    this.requestId,
    this.passengerId,
    this.berths = 0,
    this.conflicts = const [],
    this.errorMessage,
  });

  bool get lostSeats => !ok && conflicts.isNotEmpty;
}

/// Customer-side seat-chart booking. Every call goes through a SECURITY DEFINER
/// RPC from migration 048 — customers are anonymous and cannot read `buses` or
/// `passengers` directly (there is deliberately no anon SELECT on passengers,
/// which is what stops a stranger reading the roster off a public tour).
class SeatChartBookingService {
  static final SeatChartBookingService _instance =
      SeatChartBookingService._internal();
  factory SeatChartBookingService() => _instance;
  SeatChartBookingService._internal();

  SupabaseClient get _client => Supabase.instance.client;

  /// The buses (with layouts and prices) a customer may draw for this tour.
  ///
  /// Empty when the tour isn't open in chart mode — which is also what enforces
  /// "a chart tour needs a bus before it can sell". Fields the customer has no
  /// business seeing (driver/owner phones, the bus_price the agent pays the
  /// owner) are omitted server-side, so this is safe to render wholesale.
  Future<List<Bus>> tourBuses(String tourId) async {
    final result = await _client.rpc(
      'chart_tour_buses',
      params: {'p_tour_id': tourId},
    );
    if (result is! List) return const [];
    return result
        .whereType<Map>()
        .map((m) => Bus.fromMap(Map<String, dynamic>.from(m)))
        .toList();
  }

  /// Everything the PUBLIC tour page may say about a tour's inventory: the
  /// "from" price, how many berths exist, and how many are still free.
  ///
  /// Reads the 052 twins (`public_tour_buses` / `public_tour_availability`)
  /// rather than [tourBuses] / [availability], because those are gated on
  /// `chart_tour_open()` — chart mode AND not yet locked — and would return
  /// nothing for a request-mode tour, which is most of them. Gate here is
  /// `is_public` alone: describing a tour is not booking one.
  ///
  /// Returns [TourPublicSummary.pending] on ANY failure — including 052 not
  /// being deployed yet. That is "we don't know", not "there is nothing", so
  /// the page hides the price and seat count instead of asserting a false
  /// "0 seats left" or flipping a chart tour's CTA to "seats open soon".
  Future<TourPublicSummary> publicSummary(String tourId) async {
    try {
      final results = await Future.wait([
        _client.rpc('public_tour_buses', params: {'p_tour_id': tourId}),
        _client.rpc('public_tour_availability', params: {'p_tour_id': tourId}),
      ]);

      final busRows = results[0];
      final occRows = results[1];
      if (busRows is! List) return TourPublicSummary.pending;

      final buses = busRows
          .whereType<Map>()
          .map((m) => Bus.fromMap(Map<String, dynamic>.from(m)))
          .toList();

      final occupancy = occRows is List
          ? availabilityByKey(
              occRows
                  .whereType<Map>()
                  .map(
                    (m) => SeatAvailability.fromMap(
                      Map<String, dynamic>.from(m),
                    ),
                  ),
            )
          : const <String, SeatAvailability>{};

      return summariseTourForPublic(buses: buses, availability: occupancy);
    } catch (_) {
      return TourPublicSummary.pending;
    }
  }

  /// Anonymised per-seat occupancy, keyed by `busId|seatId`.
  ///
  /// Seats absent from the map are wholly free — the server only emits occupied
  /// ones. Carries NO names and NO phones, only berth counts per leg plus a
  /// ladies marker, matching the convention every Indian operator app follows.
  Future<Map<String, SeatAvailability>> availability(String tourId) async {
    final result = await _client.rpc(
      'chart_seat_availability',
      params: {'p_tour_id': tourId},
    );
    if (result is! List) return const {};
    return availabilityByKey(
      result
          .whereType<Map>()
          .map((m) => SeatAvailability.fromMap(Map<String, dynamic>.from(m))),
    );
  }

  /// Claim [picks] atomically and create the booking.
  ///
  /// The server re-validates every seat inside an advisory lock on the tour, so
  /// a stale chart can never double-book: the loser gets its seat ids back in
  /// [ChartClaimResult.conflicts]. Callers MUST keep the customer's entered
  /// details on a conflict and simply refresh the chart — the loudest complaint
  /// in this market is being made to re-enter everything after a lost seat.
  Future<ChartClaimResult> claim({
    required String requestId,
    required String tourId,
    required String busId,
    required String phone,
    required String name,
    required TripType leg,
    required List<ChartPick> picks,
    String? gender,
    String? note,
    String? pickupLocationId,
    String? pickupLocationName,
  }) async {
    try {
      final result = await _client.rpc(
        'chart_claim_seats',
        params: {
          'p_request_id': requestId,
          'p_tour_id': tourId,
          'p_bus_id': busId,
          'p_phone': phone,
          'p_name': name,
          'p_leg': leg.storageKey,
          'p_seats': claimPayload(picks),
          'p_gender': gender,
          'p_note': note,
          'p_pickup_location_id': pickupLocationId,
          'p_pickup_location_name': pickupLocationName,
        },
      );
      return _parseClaimResult(result);
    } on PostgrestException catch (e) {
      return ChartClaimResult(ok: false, errorMessage: e.message);
    }
  }

  /// Soft-hold seats for 5 minutes (advance tours). Does NOT write
  /// `assigned_seats` until [finalizeHold] / claim confirm / pay-later.
  Future<ChartHoldResult> hold({
    required String requestId,
    required String tourId,
    required String busId,
    required String phone,
    required String name,
    required TripType leg,
    required List<ChartPick> picks,
    String? gender,
    String? note,
    String? pickupLocationId,
    String? pickupLocationName,
  }) async {
    try {
      final result = await _client.rpc(
        'chart_hold_seats',
        params: {
          'p_request_id': requestId,
          'p_tour_id': tourId,
          'p_bus_id': busId,
          'p_phone': phone,
          'p_name': name,
          'p_leg': leg.storageKey,
          'p_seats': claimPayload(picks),
          'p_gender': gender,
          'p_note': note,
          'p_pickup_location_id': pickupLocationId,
          'p_pickup_location_name': pickupLocationName,
        },
      );
      if (result is! Map) {
        return const ChartHoldResult(ok: false);
      }
      final map = Map<String, dynamic>.from(result);
      if (map['ok'] == true) {
        return ChartHoldResult(
          ok: true,
          holdId: map['hold_id']?.toString(),
          requestId: map['request_id']?.toString(),
          expiresAt: map['expires_at'] != null
              ? DateTime.tryParse(map['expires_at'].toString())
              : null,
        );
      }
      return ChartHoldResult(
        ok: false,
        conflicts: (map['conflicts'] as List?)
                ?.map((e) => e.toString())
                .toList() ??
            const [],
      );
    } on PostgrestException catch (e) {
      return ChartHoldResult(ok: false, errorMessage: e.message);
    }
  }

  /// Owner/admin: turn a pending hold into a final passenger booking.
  Future<ChartClaimResult> finalizeHold(String holdId) async {
    try {
      final result = await _client.rpc(
        'chart_finalize_hold',
        params: {'p_hold_id': holdId},
      );
      return _parseClaimResult(result);
    } on PostgrestException catch (e) {
      return ChartClaimResult(ok: false, errorMessage: e.message);
    }
  }

  /// Pending holds for the organiser money board.
  Future<List<Map<String, dynamic>>> pendingHolds(String tourId) async {
    try {
      final result = await _client.rpc(
        'tour_pending_seat_holds',
        params: {'p_tour_id': tourId},
      );
      if (result is! List) return const [];
      return result
          .whereType<Map>()
          .map((m) => Map<String, dynamic>.from(m))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  ChartClaimResult _parseClaimResult(dynamic result) {
    if (result is! Map) {
      return const ChartClaimResult(ok: false);
    }
    final map = Map<String, dynamic>.from(result);
    if (map['ok'] == true) {
      return ChartClaimResult(
        ok: true,
        requestId: map['request_id']?.toString(),
        passengerId: map['passenger_id']?.toString(),
        berths: (map['berths'] as num?)?.toInt() ?? 0,
      );
    }
    return ChartClaimResult(
      ok: false,
      conflicts: (map['conflicts'] as List?)
              ?.map((e) => e.toString())
              .toList() ??
          const [],
      errorMessage: map['error']?.toString(),
    );
  }
}

/// Outcome of `chart_hold_seats`.
class ChartHoldResult {
  final bool ok;
  final String? holdId;
  final String? requestId;
  final DateTime? expiresAt;
  final List<String> conflicts;
  final String? errorMessage;

  const ChartHoldResult({
    required this.ok,
    this.holdId,
    this.requestId,
    this.expiresAt,
    this.conflicts = const [],
    this.errorMessage,
  });

  bool get lostSeats => !ok && conflicts.isNotEmpty;
}
