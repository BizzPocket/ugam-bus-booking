import 'dart:async';
import 'dart:developer' as dev;

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:get/get.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'supabase_service.dart';

/// Online-only Supabase access layer.
///
/// The former SQLite offline cache + write-queue (`OfflineDatabase`) was
/// removed: it let stale tours survive logout / reinstall (Android Auto
/// Backup restored the DB) and masked real fetch failures as empty
/// results. Reads now hit Supabase live; writes await the server and
/// throw on failure so callers can revert optimistic UI and surface the
/// real error. [isOnline] still tracks connectivity so writes fail fast
/// with a clear message instead of hanging when there is no network.
/// Thrown by [SyncService]'s RPC helpers when the backing Postgres function is
/// not deployed yet (migration 011), so callers can fall back to the legacy
/// per-row write path instead of failing the operation outright.
class RpcUnavailableException implements Exception {
  final String functionName;
  RpcUnavailableException(this.functionName);
  @override
  String toString() => 'RpcUnavailableException($functionName)';
}

class SyncService extends GetxService {
  static const _readTimeout = Duration(seconds: 8);
  static const _writeTimeout = Duration(seconds: 12);

  /// Best-effort connectivity flag (interface up — not a reachability
  /// guarantee). Used to fail writes fast when plainly offline.
  final isOnline = true.obs;

  StreamSubscription? _connectivitySub;

  SupabaseClient get _client => SupabaseService.instance.client;

  @override
  void onInit() {
    super.onInit();
    _monitorConnectivity();
  }

  @override
  void onClose() {
    _connectivitySub?.cancel();
    super.onClose();
  }

  void _monitorConnectivity() {
    _connectivitySub = Connectivity().onConnectivityChanged.listen((results) {
      isOnline.value = results.any((r) => r != ConnectivityResult.none);
    });
    Connectivity().checkConnectivity().then((results) {
      isOnline.value = results.any((r) => r != ConnectivityResult.none);
    });
  }

  // ── API-compat stubs ────────────────────────────────────────────────
  // The offline cache/queue is gone; these keep the existing controller
  // call sites compiling and are intentional no-ops.

  /// Nothing is ever queued locally now.
  Future<Set<String>> pendingEntityIdsForTable(String table) async => {};

  /// No local cache to paint from on cold start.
  Future<List<Map<String, dynamic>>?> getCachedList(String cacheKey) async =>
      null;

  /// No local cache to invalidate; callers follow this with a live refresh.
  Future<void> invalidateCache(String key) async {}

  // ── Reads (live) ────────────────────────────────────────────────────

  /// Row caps. Reads are not paginated, so a result that hits the cap is
  /// SILENTLY truncated — we log a loud warning when that happens so an
  /// operator who has outgrown the cap is at least visible in logs.
  static const int defaultRowLimit = 500;
  static const int passengersRowLimit = 2000;

  /// True when the most recent [smartFetch] could not reach the server (error
  /// or offline) — as opposed to genuinely returning zero rows. Lets callers
  /// tell "refresh failed" apart from "no data" and keep showing what they
  /// already have (with a warning) instead of blanking the screen.
  bool lastReadFailed = false;

  /// Fetches [table] from Supabase. Returns `[]` (and sets [lastReadFailed])
  /// on any failure or when offline, so a read never throws into the UI — the
  /// caller shows its own empty/error state. [cacheKey]/[select]/[maxAge] are
  /// retained for call-site compatibility and are unused now.
  Future<List<Map<String, dynamic>>> smartFetch({
    required String table,
    required String cacheKey,
    String? select,
    Map<String, String>? filters,
    String? orderBy,
    int maxAge = 300000,
  }) async {
    lastReadFailed = false;
    if (!isOnline.value) {
      lastReadFailed = true;
      return [];
    }
    try {
      return await _withTimeout(
        _fetchFromSupabase(table, filters, orderBy),
        _readTimeout,
        '$table fetch',
      );
    } catch (e, st) {
      dev.log('FETCH FAILED $table — $e\n$st', name: 'SyncService');
      lastReadFailed = true;
      return [];
    }
  }

  /// Logs a loud warning when a fetch returned exactly its row cap, which
  /// means the result was almost certainly truncated.
  void _warnIfCapped(String table, int count, int limit) {
    if (count >= limit) {
      dev.log(
        'ROW CAP HIT: "$table" returned $count rows (limit $limit) — results '
        'may be TRUNCATED. Add pagination before this operator grows further.',
        name: 'SyncService',
      );
    }
  }

  Future<List<Map<String, dynamic>>> _fetchFromSupabase(
    String table,
    Map<String, String>? filters,
    String? orderBy,
  ) async {
    if (table == 'tours') return _fetchToursWithRelations(filters, orderBy);

    var query = _client.from(table).select();
    if (filters != null) {
      filters.forEach((k, v) {
        query = query.eq(k, v);
      });
    }
    final transform = orderBy != null
        ? query.order(orderBy, ascending: false).limit(defaultRowLimit)
        : query.limit(defaultRowLimit);
    final rows = await transform;
    final list = List<Map<String, dynamic>>.from(
      (rows as List).map((r) => Map<String, dynamic>.from(r)),
    );
    _warnIfCapped(table, list.length, defaultRowLimit);
    return list;
  }

  Future<List<Map<String, dynamic>>> _fetchToursWithRelations(
    Map<String, String>? filters,
    String? orderBy,
  ) async {
    var tourQuery = _client.from('tours').select();
    if (filters != null) {
      filters.forEach((k, v) {
        tourQuery = tourQuery.eq(k, v);
      });
    }
    final transform = orderBy != null
        ? tourQuery.order(orderBy, ascending: false).limit(defaultRowLimit)
        : tourQuery.limit(defaultRowLimit);
    final tours = List<Map<String, dynamic>>.from(
      (await transform as List).map((r) => Map<String, dynamic>.from(r)),
    );
    _warnIfCapped('tours', tours.length, defaultRowLimit);
    if (tours.isEmpty) return [];

    final tourIds = tours.map((t) => t['id'] as String).toList();

    // Passengers + buses are independent once we know tour ids — fetch
    // them in parallel. Previously these awaits ran sequentially, which
    // cost one full extra round-trip per tour load on cellular networks
    // (passenger response gates the bus request for no reason).
    final passengersFuture = _client
        .from('passengers')
        .select()
        .inFilter('tour_id', tourIds)
        .limit(passengersRowLimit);
    // Buses are joined by buses.tour_id (one-to-many). A tour can have
    // multiple buses; the legacy single tours.bus_id is no longer used.
    final busesFuture = _client
        .from('buses')
        .select()
        .inFilter('tour_id', tourIds)
        .limit(defaultRowLimit);
    // Passenger groups (cross-booking groups) are also keyed by tour_id.
    final groupsFuture = _client
        .from('passenger_groups')
        .select()
        .inFilter('tour_id', tourIds)
        .limit(defaultRowLimit);

    // passengers + buses are the core relations and MUST load. passenger_groups
    // is new (migration 006) and OPTIONAL — if that table isn't present yet (or
    // its query fails for any reason) it must NOT take down the whole tour load
    // via Future.wait. Degrade to "no groups" instead of breaking every screen.
    final coreResults = await Future.wait([passengersFuture, busesFuture]);
    final passengersRaw = coreResults[0];
    final busesRaw = coreResults[1];
    _warnIfCapped('passengers', passengersRaw.length, passengersRowLimit);
    _warnIfCapped('buses', busesRaw.length, defaultRowLimit);
    List<dynamic> groupsRaw;
    try {
      groupsRaw = await groupsFuture as List;
    } catch (_) {
      groupsRaw = const [];
    }

    final passengersByTour = <String, List<Map<String, dynamic>>>{};
    for (final p in passengersRaw as List) {
      final m = Map<String, dynamic>.from(p as Map);
      final tId = m['tour_id'] as String?;
      if (tId != null) passengersByTour.putIfAbsent(tId, () => []).add(m);
    }

    final busesByTour = <String, List<Map<String, dynamic>>>{};
    for (final b in busesRaw as List) {
      final m = Map<String, dynamic>.from(b as Map);
      final tId = m['tour_id'] as String?;
      if (tId != null) busesByTour.putIfAbsent(tId, () => []).add(m);
    }

    final groupsByTour = <String, List<Map<String, dynamic>>>{};
    for (final g in groupsRaw) {
      final m = Map<String, dynamic>.from(g as Map);
      final tId = m['tour_id'] as String?;
      if (tId != null) groupsByTour.putIfAbsent(tId, () => []).add(m);
    }

    return tours.map((t) {
      final tId = t['id'] as String;
      return {
        ...t,
        'passengers': passengersByTour[tId] ?? const [],
        'buses': busesByTour[tId] ?? const [],
        'groups': groupsByTour[tId] ?? const [],
      };
    }).toList();
  }

  // ── Writes (live, online-only) ──────────────────────────────────────

  /// Tables whose RLS policies require `owner_id = auth.uid()`. We backfill
  /// `owner_id` from the current session before writing so an admin write
  /// never lands without it.
  static const _ownerScopedTables = {
    'tours',
    'buses',
    'admin_contacts',
    'customer_memory',
  };

  void _ensureOnline() {
    if (!isOnline.value) {
      throw Exception('You appear to be offline. Connect to save changes.');
    }
  }

  Future<void> smartInsert({
    required String table,
    required String entityId,
    required Map<String, dynamic> data,
    String? cacheKey,
  }) async {
    _ensureOnline();
    await _withTimeout(
      _writeToServer(
        operation: 'insert',
        table: table,
        entityId: entityId,
        data: data,
      ),
      _writeTimeout,
      'insert $table',
    );
  }

  Future<void> smartUpdate({
    required String table,
    required String entityId,
    required Map<String, dynamic> data,
  }) async {
    _ensureOnline();
    await _withTimeout(
      _writeToServer(
        operation: 'update',
        table: table,
        entityId: entityId,
        data: data,
      ),
      _writeTimeout,
      'update $table',
    );
  }

  Future<void> smartDelete({
    required String table,
    required String entityId,
  }) async {
    _ensureOnline();
    await _withTimeout(
      _writeToServer(
        operation: 'delete',
        table: table,
        entityId: entityId,
        data: {'id': entityId},
      ),
      _writeTimeout,
      'delete $table',
    );
  }

  // ── Atomic seat RPCs (migration 011) ────────────────────────────────
  // These run server-side in a single transaction, closing the consistency
  // windows the multi-step client writes had. They throw
  // [RpcUnavailableException] when not yet deployed so callers degrade
  // gracefully to the legacy path.

  /// Atomically swap two passengers' seat assignments. [seatsA]/[seatsB] are
  /// the new `assigned_seats` arrays (lists of {busId, seatId, locked?} maps).
  Future<void> swapPassengerSeats({
    required String passengerAId,
    required List<Map<String, dynamic>> seatsA,
    required String passengerBId,
    required List<Map<String, dynamic>> seatsB,
  }) async {
    _ensureOnline();
    await _withTimeout(
      _callRpc('swap_passenger_seats', {
        'p_passenger_a': passengerAId,
        'p_seats_a': seatsA,
        'p_passenger_b': passengerBId,
        'p_seats_b': seatsB,
      }),
      _writeTimeout,
      'swap seats',
    );
  }

  /// Atomically apply a whole seat plan in one transaction. [assignments] is
  /// `[{"id": <passengerId>, "assigned_seats": [...]}, ...]`.
  Future<void> applySeatAssignments({
    required String tourId,
    required List<Map<String, dynamic>> assignments,
  }) async {
    _ensureOnline();
    await _withTimeout(
      _callRpc('apply_seat_assignments', {
        'p_tour_id': tourId,
        'p_assignments': assignments,
      }),
      _writeTimeout,
      'apply seat plan',
    );
  }

  Future<void> _callRpc(String fn, Map<String, dynamic> params) async {
    try {
      await _client.rpc(fn, params: params);
    } on PostgrestException catch (e) {
      // PGRST202 (PostgREST) / 42883 (Postgres) = function does not exist —
      // the migration isn't deployed. Signal a graceful fallback.
      if (e.code == 'PGRST202' || e.code == '42883') {
        throw RpcUnavailableException(fn);
      }
      rethrow;
    }
  }

  /// Single source of truth for the actual server write. Throws on failure —
  /// callers decide whether to revert optimistic UI or surface an error.
  Future<void> _writeToServer({
    required String operation,
    required String table,
    required String entityId,
    required Map<String, dynamic> data,
  }) async {
    final clean = Map<String, dynamic>.from(data)
      ..remove(r'$id')
      ..remove(r'$createdAt')
      ..remove(r'$updatedAt');
    clean['id'] = entityId;

    // Backfill owner_id from the current Supabase Auth session for tables
    // whose RLS requires it.
    final authUid = _client.auth.currentUser?.id;
    if (_ownerScopedTables.contains(table) &&
        authUid != null &&
        (clean['owner_id'] == null ||
            (clean['owner_id'] is String &&
                (clean['owner_id'] as String).isEmpty))) {
      clean['owner_id'] = authUid;
    }

    switch (operation) {
      case 'insert':
        try {
          await _client.from(table).insert(clean);
        } on PostgrestException catch (e) {
          // 23505 = unique_violation. Usually the conflict is on a non-id
          // column (e.g. (tour_id, phone) on passengers). Only fall back
          // to UPDATE when a row with this exact id already exists.
          if (e.code == '23505') {
            final existing = await _client
                .from(table)
                .select('id')
                .eq('id', entityId)
                .maybeSingle();
            if (existing == null) {
              rethrow;
            }
            final updateData = Map<String, dynamic>.from(clean)..remove('id');
            await _client.from(table).update(updateData).eq('id', entityId);
          } else {
            rethrow;
          }
        }
        break;
      case 'update':
        final updateData = Map<String, dynamic>.from(clean)..remove('id');
        final res = await _client
            .from(table)
            .update(updateData)
            .eq('id', entityId)
            .select();
        if ((res as List).isEmpty) {
          // Row missing — fall back to insert.
          await _client.from(table).insert(clean);
        }
        break;
      case 'delete':
        await _client.from(table).delete().eq('id', entityId);
        break;
    }
  }

  Future<T> _withTimeout<T>(
    Future<T> future,
    Duration duration,
    String label,
  ) {
    return future.timeout(
      duration,
      onTimeout: () => throw TimeoutException('$label timed out', duration),
    );
  }
}
