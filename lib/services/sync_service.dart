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
      isOnline.value = results.any((r) => r != ConnectivityResult.none);
    });
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
    final cached = await _cache.getCachedData(cacheKey);
    final cacheAge = await _cache.getCacheAge(cacheKey);

    if (cached != null && cacheAge != null && cacheAge < maxAge) {
      if (isOnline.value) {
        _backgroundFetch(table, cacheKey, filters, orderBy);
      }
      return _asListOfMap(cached);
    }

    if (isOnline.value) {
      try {
        final data = await _fetchFromSupabase(table, filters, orderBy);
        await _cache.cacheData(cacheKey, data);
        return data;
      } catch (e, st) {
        dev.log('FETCH FAILED $table — $e\n$st', name: 'SyncService');
        if (cached != null) return _asListOfMap(cached);
        return [];
      }
    }

    if (cached != null) return _asListOfMap(cached);
    return [];
  }

  List<Map<String, dynamic>> _asListOfMap(dynamic cached) {
    return List<Map<String, dynamic>>.from(
      (cached as List).map((e) => Map<String, dynamic>.from(e)),
    );
  }

  Future<void> _backgroundFetch(
    String table,
    String cacheKey,
    Map<String, String>? filters,
    String? orderBy,
  ) async {
    try {
      final data = await _fetchFromSupabase(table, filters, orderBy);
      await _cache.cacheData(cacheKey, data);
    } catch (_) {
      // Silent fail for background refresh
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
    final busIds = tours
        .map((t) => t['bus_id'])
        .whereType<String>()
        .toSet()
        .toList();

    final passengersRaw = await _client
        .from('passengers')
        .select()
        .inFilter('tour_id', tourIds)
        .limit(2000);
    final passengersByTour = <String, List<Map<String, dynamic>>>{};
    for (final p in passengersRaw as List) {
      final m = Map<String, dynamic>.from(p as Map);
      final tId = m['tour_id'] as String?;
      if (tId != null) passengersByTour.putIfAbsent(tId, () => []).add(m);
    }

    final busesByTour = <String, List<Map<String, dynamic>>>{};
    if (busIds.isNotEmpty) {
      final busesRaw = await _client
          .from('buses')
          .select()
          .inFilter('id', busIds)
          .limit(500);
      final busesById = <String, Map<String, dynamic>>{
        for (final b in busesRaw as List)
          (b as Map)['id'] as String: Map<String, dynamic>.from(b),
      };
      for (final t in tours) {
        final bId = t['bus_id'] as String?;
        if (bId != null && busesById.containsKey(bId)) {
          busesByTour[t['id'] as String] = [busesById[bId]!];
        }
      }
    }

    return tours.map((t) {
      final tId = t['id'] as String;
      return {
        ...t,
        'passengers': passengersByTour[tId] ?? const [],
        'buses': busesByTour[tId] ?? const [],
      };
    }).toList();
  }

  // ── Smart Write (queue + sync) ────────────────────────────

  Future<void> smartInsert({
    required String table,
    required String entityId,
    required Map<String, dynamic> data,
    String? cacheKey,
  }) async {
    await _cache.addPendingOp(
      tableName: table,
      operation: 'insert',
      entityId: entityId,
      data: data,
    );
    _updatePendingCount();
    if (isOnline.value) await syncPendingOps();
  }

  Future<void> smartUpdate({
    required String table,
    required String entityId,
    required Map<String, dynamic> data,
  }) async {
    await _cache.addPendingOp(
      tableName: table,
      operation: 'update',
      entityId: entityId,
      data: data,
    );
    _updatePendingCount();
    if (isOnline.value) await syncPendingOps();
  }

  Future<void> smartDelete({
    required String table,
    required String entityId,
  }) async {
    await _cache.addPendingOp(
      tableName: table,
      operation: 'delete',
      entityId: entityId,
      data: {'id': entityId},
    );
    _updatePendingCount();
    if (isOnline.value) await syncPendingOps();
  }

  // ── Sync Engine ───────────────────────────────────────────

  Future<void> syncPendingOps() async {
    if (isSyncing.value || !isOnline.value) return;
    isSyncing.value = true;
    try {
      final ops = await _cache.getPendingOps();
      if (ops.isEmpty) return;
      dev.log('Syncing ${ops.length} pending ops...', name: 'SyncService');

      for (final op in ops) {
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

        try {
          // Strip stale Appwrite system fields the cache may have stored.
          data.remove(r'$id');
          data.remove(r'$createdAt');
          data.remove(r'$updatedAt');
          // Ensure the row carries `id` matching entityId for inserts.
          data['id'] = entityId;

          switch (operation) {
            case 'insert':
              try {
                await _client.from(table).insert(data);
              } on PostgrestException catch (e) {
                // 23505 = unique_violation (already exists) → upsert
                if (e.code == '23505') {
                  final updateData = Map<String, dynamic>.from(data)
                    ..remove('id');
                  await _client
                      .from(table)
                      .update(updateData)
                      .eq('id', entityId);
                } else {
                  rethrow;
                }
              }
              break;
            case 'update':
              final updateData = Map<String, dynamic>.from(data)..remove('id');
              final res = await _client
                  .from(table)
                  .update(updateData)
                  .eq('id', entityId)
                  .select();
              if ((res as List).isEmpty) {
                // Row missing — fall back to insert
                await _client.from(table).insert(data);
              }
              break;
            case 'delete':
              await _client.from(table).delete().eq('id', entityId);
              break;
          }
          await _cache.removePendingOp(id);
        } catch (e) {
          dev.log(
            'SYNC FAILED: $operation on $table/$entityId — $e',
            name: 'SyncService',
          );
          await _cache.incrementRetry(id);
        }
      }
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
}
