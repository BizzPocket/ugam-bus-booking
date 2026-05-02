import 'dart:async';
import 'package:appwrite/appwrite.dart';
import 'package:appwrite/models.dart' as aw;
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:get/get.dart';
import '../config/appwrite_config.dart';
import 'appwrite_service.dart';
import 'offline_database.dart';

/// Manages offline-first sync between local SQLite cache and Appwrite.
///
/// Strategy:
/// - READ: Local cache first → fetch from Appwrite in background → update cache
/// - WRITE: Write to cache immediately → queue for Appwrite → sync when online
/// - SYNC: On connectivity change, flush pending operations
///
/// Because Appwrite doesn't support joins, the 'tours' fetch is special-cased
/// to assemble tours with their nested passengers and busDetails in memory.
class SyncService extends GetxService {
  final OfflineDatabase _cache = OfflineDatabase();
  final isOnline = true.obs;
  final isSyncing = false.obs;
  final pendingCount = 0.obs;

  StreamSubscription? _connectivitySub;
  Timer? _syncTimer;

  Databases get _db => AppwriteService().databases;

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
      if (connected) {
        syncPendingOps();
      }
    });

    Connectivity().checkConnectivity().then((results) {
      isOnline.value = results.any((r) => r != ConnectivityResult.none);
    });
  }

  // ── Smart Fetch (cache-first) ─────────────────────────────

  /// Fetch with cache-first strategy.
  /// For [table] = 'tours', returns tours with nested passengers/busDetails.
  /// For other tables, returns flat document list.
  Future<List<Map<String, dynamic>>> smartFetch({
    required String table,
    required String cacheKey,
    String? select, // unused in Appwrite — kept for API compatibility
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
        final data = await _fetchFromAppwrite(table, filters, orderBy);
        await _cache.cacheData(cacheKey, data);
        return data;
      } catch (_) {
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
      final data = await _fetchFromAppwrite(table, filters, orderBy);
      await _cache.cacheData(cacheKey, data);
    } catch (_) {
      // Silent fail for background refresh
    }
  }

  Future<List<Map<String, dynamic>>> _fetchFromAppwrite(
    String collection,
    Map<String, String>? filters,
    String? orderBy,
  ) async {
    // Special case: tours needs nested passengers and busDetails.
    if (collection == AppwriteConfig.toursCollection) {
      return _fetchToursWithRelations(filters, orderBy);
    }

    final queries = <String>[];
    if (filters != null) {
      for (final entry in filters.entries) {
        queries.add(Query.equal(entry.key, entry.value));
      }
    }
    if (orderBy != null) {
      queries.add(Query.orderDesc(orderBy));
    }
    queries.add(Query.limit(500));

    final result = await _db.listDocuments(
      databaseId: AppwriteConfig.databaseId,
      collectionId: collection,
      queries: queries,
    );

    return result.documents.map(_documentToMap).toList();
  }

  /// Fetch tours and assemble nested passengers + busDetails in memory
  /// (Appwrite does not support joins).
  Future<List<Map<String, dynamic>>> _fetchToursWithRelations(
    Map<String, String>? filters,
    String? orderBy,
  ) async {
    final tourQueries = <String>[];
    if (filters != null) {
      for (final entry in filters.entries) {
        tourQueries.add(Query.equal(entry.key, entry.value));
      }
    }
    if (orderBy != null) {
      tourQueries.add(Query.orderDesc(orderBy));
    }
    tourQueries.add(Query.limit(500));

    final toursResult = await _db.listDocuments(
      databaseId: AppwriteConfig.databaseId,
      collectionId: AppwriteConfig.toursCollection,
      queries: tourQueries,
    );

    if (toursResult.documents.isEmpty) return [];

    final tourIds = toursResult.documents.map((d) => d.$id).toList();

    // Fetch all passengers and bus details for these tour IDs
    final passengersResult = await _db.listDocuments(
      databaseId: AppwriteConfig.databaseId,
      collectionId: AppwriteConfig.passengersCollection,
      queries: [Query.equal('tourId', tourIds), Query.limit(2000)],
    );

    final busDetailsResult = await _db.listDocuments(
      databaseId: AppwriteConfig.databaseId,
      collectionId: AppwriteConfig.busDetailsCollection,
      queries: [Query.equal('tourId', tourIds), Query.limit(500)],
    );

    // Group passengers and bus details by tourId
    final passengersByTour = <String, List<Map<String, dynamic>>>{};
    for (final doc in passengersResult.documents) {
      final m = _documentToMap(doc);
      final tId = m['tourId'] as String?;
      if (tId != null) {
        passengersByTour.putIfAbsent(tId, () => []).add(m);
      }
    }

    final busDetailsByTour = <String, Map<String, dynamic>>{};
    for (final doc in busDetailsResult.documents) {
      final m = _documentToMap(doc);
      final tId = m['tourId'] as String?;
      if (tId != null) {
        busDetailsByTour[tId] = m;
      }
    }

    // Assemble tours with nested data
    return toursResult.documents.map((doc) {
      final tourMap = _documentToMap(doc);
      tourMap['passengers'] = passengersByTour[doc.$id] ?? [];
      if (busDetailsByTour[doc.$id] != null) {
        tourMap['busDetails'] = busDetailsByTour[doc.$id];
      }
      return tourMap;
    }).toList();
  }

  /// Convert an Appwrite Document to a plain map, preserving $id/$createdAt/$updatedAt.
  Map<String, dynamic> _documentToMap(aw.Document doc) {
    return {
      ...doc.data,
      r'$id': doc.$id,
      r'$createdAt': doc.$createdAt,
      r'$updatedAt': doc.$updatedAt,
    };
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

    if (isOnline.value) {
      await syncPendingOps();
    }
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

    if (isOnline.value) {
      await syncPendingOps();
    }
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

    if (isOnline.value) {
      await syncPendingOps();
    }
  }

  // ── Sync Engine ───────────────────────────────────────────

  /// Flush all pending operations to Appwrite.
  Future<void> syncPendingOps() async {
    if (isSyncing.value || !isOnline.value) return;
    isSyncing.value = true;

    try {
      final ops = await _cache.getPendingOps();
      if (ops.isEmpty) {
        isSyncing.value = false;
        return;
      }

      for (final op in ops) {
        final id = op['id'] as int;
        final collection = op['table_name'] as String;
        final operation = op['operation'] as String;
        final entityId = op['entity_id'] as String;
        final data = Map<String, dynamic>.from(op['data'] as Map);
        final retries = op['retries'] as int;

        if (retries >= 5) {
          await _cache.removePendingOp(id);
          continue;
        }

        try {
          // Strip internal id fields — Appwrite uses $id separately
          data.remove('id');
          data.remove(r'$id');
          data.remove(r'$createdAt');
          data.remove(r'$updatedAt');
          data.remove(r'$collectionId');
          data.remove(r'$databaseId');
          data.remove(r'$permissions');

          switch (operation) {
            case 'insert':
              try {
                await _db.createDocument(
                  databaseId: AppwriteConfig.databaseId,
                  collectionId: collection,
                  documentId: entityId,
                  data: data,
                );
              } on AppwriteException catch (e) {
                // If document already exists, fall back to update (upsert-like)
                if (e.code == 409) {
                  await _db.updateDocument(
                    databaseId: AppwriteConfig.databaseId,
                    collectionId: collection,
                    documentId: entityId,
                    data: data,
                  );
                } else {
                  rethrow;
                }
              }
              break;
            case 'update':
              try {
                await _db.updateDocument(
                  databaseId: AppwriteConfig.databaseId,
                  collectionId: collection,
                  documentId: entityId,
                  data: data,
                );
              } on AppwriteException catch (e) {
                // If document doesn't exist yet, create it
                if (e.code == 404) {
                  await _db.createDocument(
                    databaseId: AppwriteConfig.databaseId,
                    collectionId: collection,
                    documentId: entityId,
                    data: data,
                  );
                } else {
                  rethrow;
                }
              }
              break;
            case 'delete':
              try {
                await _db.deleteDocument(
                  databaseId: AppwriteConfig.databaseId,
                  collectionId: collection,
                  documentId: entityId,
                );
              } on AppwriteException catch (e) {
                // Already gone — treat as success
                if (e.code != 404) rethrow;
              }
              break;
          }
          await _cache.removePendingOp(id);
        } catch (_) {
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

  Future<void> forceFullSync() async {
    if (!isOnline.value) return;
    await _cache.clearCache();
    await syncPendingOps();
  }
}
