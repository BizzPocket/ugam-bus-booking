import 'dart:async';
import 'dart:developer' as dev;

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:get/get.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../utils/app_snackbar.dart';
import 'offline_database.dart';
import 'supabase_service.dart';

/// Manages offline-first sync between local SQLite cache and Supabase.
///
/// Strategy:
/// - READ: Local cache first → fetch from Supabase in background → update cache
/// - WRITE: Write to cache immediately → queue for Supabase → sync when online
/// - SYNC: On connectivity change, flush pending operations
class SyncService extends GetxService {
  static const _readTimeout = Duration(seconds: 8);
  static const _writeTimeout = Duration(seconds: 12);

  final OfflineDatabase _cache = OfflineDatabase();
  final isOnline = true.obs;
  final isSyncing = false.obs;
  final pendingCount = 0.obs;

  StreamSubscription? _connectivitySub;
  Timer? _syncTimer;

  SupabaseClient get _client => SupabaseService.instance.client;

  @override
  void onInit() {
    super.onInit();
    _monitorConnectivity();
    _syncTimer = Timer.periodic(const Duration(minutes: 2), (_) {
      if (isOnline.value) syncPendingOps();
    });
  }

  @override
  void onClose() {
    _connectivitySub?.cancel();
    _syncTimer?.cancel();
    super.onClose();
  }

  void _monitorConnectivity() {
    _connectivitySub = Connectivity().onConnectivityChanged.listen((results) {
      final connected = results.any((r) => r != ConnectivityResult.none);
      isOnline.value = connected;
      if (connected) syncPendingOps();
    });
    Connectivity().checkConnectivity().then((results) {
      final online = results.any((r) => r != ConnectivityResult.none);
      isOnline.value = online;
      // The change-listener above only fires on *changes*. If the first
      // resolved value is already online, flush any ops queued before this
      // initial check finished (otherwise they'd sit until the 2-minute
      // timer or the next connectivity flap).
      if (online) syncPendingOps();
    });
  }

  /// Returns the set of entity ids that have at least one pending op
  /// queued for [table]. Callers use this to avoid clobbering local-only
  /// rows when refreshing from the server.
  Future<Set<String>> pendingEntityIdsForTable(String table) async {
    final ops = await _cache.getPendingOps();
    return ops
        .where((op) => op['table_name'] == table)
        .map((op) => op['entity_id'] as String)
        .toSet();
  }

  /// Exposes cached list payloads so controllers can paint something
  /// immediately on cold start before the live fetch finishes.
  Future<List<Map<String, dynamic>>?> getCachedList(String cacheKey) async {
    final cached = await _cache.getCachedData(cacheKey);
    if (cached == null) return null;
    return _asListOfMap(cached);
  }

  // ── Smart Fetch (cache-first) ─────────────────────────────

  Future<List<Map<String, dynamic>>> smartFetch({
    required String table,
    required String cacheKey,
    String? select,
    Map<String, String>? filters,
    String? orderBy,
    int maxAge = 300000,
  }) async {
    // Live-first when online. Supabase Realtime now feeds TourController, so
    // serving stale cache for up to 5 minutes (the previous behaviour) is
    // wrong — by the time the cache is "fresh enough", another device or
    // the customer-side app may already have changed the world. Cache is a
    // pure offline fallback.
    if (isOnline.value) {
      try {
        final data = await _withTimeout(
          _fetchFromSupabase(table, filters, orderBy),
          _readTimeout,
          '$table fetch',
        );
        // Cache write is fire-and-forget: it only matters for the next
        // cold start / offline session, and the encode + SQLite
        // transaction adds 10-50ms on busy payloads. Awaiting it would
        // gate the live data behind cache I/O for no UX benefit.
        unawaited(_cache.cacheData(cacheKey, data).catchError((e, st) {
          dev.log('cache write failed for $cacheKey: $e\n$st',
              name: 'SyncService');
        }));
        return data;
      } catch (e, st) {
        dev.log('FETCH FAILED $table — $e\n$st', name: 'SyncService');
        final cached = await _cache.getCachedData(cacheKey);
        if (cached != null) return _asListOfMap(cached);
        return [];
      }
    }

    final cached = await _cache.getCachedData(cacheKey);
    if (cached != null) return _asListOfMap(cached);
    return [];
  }

  List<Map<String, dynamic>> _asListOfMap(dynamic cached) {
    return List<Map<String, dynamic>>.from(
      (cached as List).map((e) => Map<String, dynamic>.from(e)),
    );
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
        ? query.order(orderBy, ascending: false).limit(500)
        : query.limit(500);
    final rows = await transform;
    return List<Map<String, dynamic>>.from(
      (rows as List).map((r) => Map<String, dynamic>.from(r)),
    );
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
        ? tourQuery.order(orderBy, ascending: false).limit(500)
        : tourQuery.limit(500);
    final tours = List<Map<String, dynamic>>.from(
      (await transform as List).map((r) => Map<String, dynamic>.from(r)),
    );
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
        .limit(2000);
    // Buses are joined by buses.tour_id (one-to-many). A tour can have
    // multiple buses; the legacy single tours.bus_id is no longer used.
    final busesFuture = _client
        .from('buses')
        .select()
        .inFilter('tour_id', tourIds)
        .limit(500);
    // Passenger groups (cross-booking groups) are also keyed by tour_id.
    final groupsFuture = _client
        .from('passenger_groups')
        .select()
        .inFilter('tour_id', tourIds)
        .limit(500);

    final results =
        await Future.wait([passengersFuture, busesFuture, groupsFuture]);
    final passengersRaw = results[0];
    final busesRaw = results[1];
    final groupsRaw = results[2];

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
    for (final g in groupsRaw as List) {
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

  // ── Smart Write (queue + sync) ────────────────────────────

  /// Foreground write when online, offline-queue when not.
  ///
  /// Online path: awaits the actual Supabase response and THROWS on failure
  /// (network error, RLS rejection, validation, etc.) so the caller can
  /// revert any optimistic UI and surface the real error to the user.
  ///
  /// Offline path: queues the op in pending_ops to be drained by
  /// syncPendingOps() when connectivity returns. The caller gets a clean
  /// future-completed signal — there's no server error to surface yet.
  ///
  /// This replaces the previous "always queue + drain in background" model
  /// that made every CRUD look successful even when the server had rejected
  /// it. The drain loop still exists for ops that were queued while offline.
  Future<void> smartInsert({
    required String table,
    required String entityId,
    required Map<String, dynamic> data,
    String? cacheKey,
  }) async {
    if (isOnline.value) {
      try {
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
        return;
      } catch (e, st) {
        if (!_isTransientNetworkError(e)) rethrow;
        dev.log(
          'smartInsert degraded to offline queue for $table/$entityId — $e\n$st',
          name: 'SyncService',
        );
      }
    }
    await _cache.addPendingOp(
      tableName: table,
      operation: 'insert',
      entityId: entityId,
      data: data,
    );
    _updatePendingCount();
  }

  Future<void> smartUpdate({
    required String table,
    required String entityId,
    required Map<String, dynamic> data,
  }) async {
    if (isOnline.value) {
      try {
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
        return;
      } catch (e, st) {
        if (!_isTransientNetworkError(e)) rethrow;
        dev.log(
          'smartUpdate degraded to offline queue for $table/$entityId — $e\n$st',
          name: 'SyncService',
        );
      }
    }
    await _cache.addPendingOp(
      tableName: table,
      operation: 'update',
      entityId: entityId,
      data: data,
    );
    _updatePendingCount();
  }

  Future<void> smartDelete({
    required String table,
    required String entityId,
  }) async {
    if (isOnline.value) {
      try {
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
        return;
      } catch (e, st) {
        if (!_isTransientNetworkError(e)) rethrow;
        dev.log(
          'smartDelete degraded to offline queue for $table/$entityId — $e\n$st',
          name: 'SyncService',
        );
      }
    }
    await _cache.addPendingOp(
      tableName: table,
      operation: 'delete',
      entityId: entityId,
      data: {'id': entityId},
    );
    _updatePendingCount();
  }

  /// Single source of truth for the actual server write. Used by both the
  /// foreground path (smartInsert/Update/Delete) and the offline drain loop
  /// (syncPendingOps). Throws on failure — callers decide whether to revert
  /// optimistic UI, surface an error, or (in the drain loop) bump retries.
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
    // whose RLS requires it. Prevents the "queued without owner_id during
    // a passenger session, retried forever" failure mode.
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

  // ── Sync Engine ───────────────────────────────────────────

  /// Tables whose RLS policies require `owner_id = auth.uid()`.
  /// Ops on these tables can only succeed with a Supabase Auth session;
  /// if `owner_id` is missing on a queued op, we backfill it from the
  /// current authenticated user before sending.
  static const _ownerScopedTables = {'tours', 'buses', 'admin_contacts'};

  /// Drains the pending_ops queue. The queue only fills up while the app
  /// is offline now — online writes go straight through smartInsert/Update/
  /// Delete and never touch this queue. So this loop's job is purely
  /// "I was offline, now I'm back online — flush my buffered work".
  Future<void> syncPendingOps() async {
    if (isSyncing.value || !isOnline.value) return;
    isSyncing.value = true;
    try {
      final ops = await _cache.getPendingOps();
      if (ops.isEmpty) return;
      dev.log('Draining ${ops.length} pending ops...', name: 'SyncService');

      final authUid = _client.auth.currentUser?.id;

      // Group ops by entity_id so per-entity ordering is preserved
      // (insert → update → delete on the same row must run in sequence,
      // otherwise the update could land before the insert and silently
      // drop). Different entities are independent, so we drain groups
      // in parallel via Future.wait — on reconnect this collapses a
      // 20-op queue into ~2 round-trips instead of 20.
      final groups = <String, List<Map<String, dynamic>>>{};
      for (final op in ops) {
        final entityId = op['entity_id'] as String;
        groups.putIfAbsent(entityId, () => []).add(op);
      }

      await Future.wait(groups.values.map((group) async {
        for (final op in group) {
          final id = op['id'] as int;
          final table = op['table_name'] as String;
          final operation = op['operation'] as String;
          final entityId = op['entity_id'] as String;
          final data = Map<String, dynamic>.from(op['data'] as Map);
          final retries = op['retries'] as int;

          if (retries >= 5) {
            await _cache.removePendingOp(id);
            AppSnackBar.error(
              'A $operation on $table could not be saved after 5 retries. '
              'Please re-enter or check your connection.',
              title: 'Sync abandoned',
            );
            continue;
          }

          // Owner-scoped tables need an authenticated session. Skip
          // (don't increment retries) when we have no auth — the op
          // will be picked up on the next drain tick once the user
          // signs in. We `break` out of the per-entity chain because
          // a later op in the same chain depends on this earlier one
          // landing first.
          if (_ownerScopedTables.contains(table) && authUid == null) {
            break;
          }

          try {
            await _writeToServer(
              operation: operation,
              table: table,
              entityId: entityId,
              data: data,
            );
            await _cache.removePendingOp(id);
          } catch (e) {
            dev.log(
              'DRAIN FAILED: $operation on $table/$entityId — $e',
              name: 'SyncService',
            );
            await _cache.incrementRetry(id);
            // Stop draining this entity's chain on failure — running
            // the next op (e.g. an UPDATE) when the INSERT failed
            // would just error and bump retries pointlessly.
            break;
          }
        }
      }));
    } finally {
      isSyncing.value = false;
      _updatePendingCount();
    }
  }

  Future<void> _updatePendingCount() async {
    pendingCount.value = await _cache.pendingOpsCount();
  }

  Future<void> invalidateCache(String key) async {
    await _cache.invalidateCache(key);
  }

  Future<void> forceFullSync() async {
    if (!isOnline.value) return;
    await _cache.clearCache();
    await syncPendingOps();
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

  bool _isTransientNetworkError(Object error) {
    if (error is TimeoutException) return true;
    final message = error.toString().toLowerCase();
    return message.contains('socketexception') ||
        message.contains('clientexception') ||
        message.contains('failed host lookup') ||
        message.contains('network is unreachable') ||
        message.contains('connection closed') ||
        message.contains('connection error') ||
        message.contains('timed out');
  }
}
