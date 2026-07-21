import 'dart:async';
import 'dart:developer' as dev;
import 'dart:math' as math;

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:get/get.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'supabase_service.dart';
import 'sync_retry_policy.dart' as retry;

/// Fetch every row by paging through [fetchPage] (a Supabase `.range(from,to)`
/// closure) until a page shorter than [pageSize] returns (X-5). Replaces the
/// silent `.limit(cap)` truncation so roster/capacity/money never compute on a
/// partial read.
///
/// Termination: each iteration requests exactly [pageSize] rows starting at
/// [from]. Any page whose length is less than [pageSize] — including an empty
/// page — ends the loop immediately, so a backend that eventually runs out of
/// rows always produces a short (or empty) final page and the loop exits. The
/// only way this would not terminate is a page-fetcher that always returns
/// exactly [pageSize] rows forever, which is not possible against a finite
/// table.
@visibleForTesting
Future<List<T>> paginateRows<T>(
  Future<List<T>> Function(int from, int to) fetchPage, {
  int pageSize = SyncService.pageSize,
}) async {
  final all = <T>[];
  var from = 0;
  while (true) {
    final page = await fetchPage(from, from + pageSize - 1);
    all.addAll(page);
    if (page.length < pageSize) break;
    from += pageSize;
  }
  return all;
}

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
  // Read timeout budget. Raised from 8s to 12s: a single slow moment on
  // cellular used to blow the 8s budget and blank the whole screen. Applied
  // PER PAGE (X-5) — each individual .range() round trip inside a paginated
  // read gets its own 12s, rather than one aggregate cap over the whole
  // multi-page read (see smartFetch below). That way a large roster that
  // needs several round trips isn't killed by a budget sized for one, while
  // each round trip is still bounded.
  static const _readTimeout = Duration(seconds: 12);
  // Per-attempt write timeout. Writes are idempotent (keyed by entity id) so a
  // timeout that actually landed converges on retry — no need to inflate this.
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

  /// Page size for range-paginated reads (X-5). Supabase's default max
  /// range window, used as the per-request chunk so every table read pages
  /// through ALL rows instead of silently truncating at a fixed cap.
  static const int pageSize = 1000;

  /// Fetches [table] from Supabase. Returns a record of the fetched [rows]
  /// (`[]` on any failure or when offline) plus a per-call [failed] flag, so a
  /// read never throws into the UI and the caller can tell "refresh failed"
  /// apart from "no data" and keep showing what it already has instead of
  /// blanking the screen.
  ///
  /// [failed] is RETURNED, not stored on the service. That isolation is load-
  /// bearing: the cold-start `tours` and `customer_memory` reads (and the money
  /// board's four reads) run CONCURRENTLY, and a single shared flag let one
  /// read's failure bleed into another's result — a fast `customer_memory`
  /// PGRST205 (missing table) would flip a shared flag and blank a tours load
  /// that had actually succeeded. A per-call result can't be clobbered.
  /// [cacheKey]/[select]/[maxAge] are retained for call-site compatibility and
  /// are unused now.
  Future<({List<Map<String, dynamic>> rows, bool failed})> smartFetch({
    required String table,
    required String cacheKey,
    String? select,
    Map<String, String>? filters,
    String? orderBy,
    int maxAge = 300000,
  }) async {
    if (!isOnline.value) {
      return (rows: const <Map<String, dynamic>>[], failed: true);
    }
    try {
      // Reads are idempotent — retry transient failures (incl. timeout) so one
      // slow moment on cellular no longer blanks the screen. Terminal errors
      // (auth/RLS/missing-table) still surface immediately via [_isRetryable].
      //
      // timeout: null — a paginated read can be several sequential round
      // trips (X-5); each one already carries its own _readTimeout budget
      // (applied inside the .range() closures in _fetchFromSupabase /
      // _fetchToursWithRelations), so wrapping the WHOLE multi-page read in
      // one more _readTimeout here would let a genuinely large roster time
      // out in full even though every individual round trip was healthy.
      final rows = await _withRetry(
        () => _fetchFromSupabase(table, filters, orderBy),
        timeout: null,
        label: '$table fetch',
      );
      return (rows: rows, failed: false);
    } catch (e, st) {
      dev.log('FETCH FAILED $table — $e\n$st', name: 'SyncService');
      return (rows: const <Map<String, dynamic>>[], failed: true);
    }
  }

  Future<List<Map<String, dynamic>>> _fetchFromSupabase(
    String table,
    Map<String, String>? filters,
    String? orderBy,
  ) async {
    if (table == 'tours') return _fetchToursWithRelations(filters, orderBy);

    final base = _client.from(table).select();
    var filtered = base;
    if (filters != null) {
      filters.forEach((k, v) {
        filtered = filtered.eq(k, v);
      });
    }
    return paginateRows<Map<String, dynamic>>((from, to) async {
      // X-5: pagination pages via repeated .range() round trips, which needs
      // a deterministic ORDER BY — without one, Postgres does not guarantee
      // row order between separate requests and a multi-page read can
      // silently drop or duplicate rows at a page boundary. When the caller
      // gave no orderBy, fall back to the primary key ('id') purely for a
      // stable (arbitrary) order; callers re-sort for display so this
      // doesn't need to match any display order.
      final transform = orderBy != null
          ? filtered.order(orderBy, ascending: false).range(from, to)
          : filtered.order('id').range(from, to);
      // Per-page timeout, not an aggregate one over the whole multi-page
      // read — see the comment on smartFetch's _withRetry call.
      final rows =
          await _withTimeout(transform, _readTimeout, '$table page fetch');
      return List<Map<String, dynamic>>.from(
        (rows as List).map((r) => Map<String, dynamic>.from(r)),
      );
    });
  }

  Future<List<Map<String, dynamic>>> _fetchToursWithRelations(
    Map<String, String>? filters,
    String? orderBy,
  ) async {
    final tourBase = _client.from('tours').select();
    var tourQuery = tourBase;
    if (filters != null) {
      filters.forEach((k, v) {
        tourQuery = tourQuery.eq(k, v);
      });
    }
    final tours = await paginateRows<Map<String, dynamic>>((from, to) async {
      // X-5: same stable-order requirement as the generic read above — order
      // by 'id' (tours' PK, migrations/001_initial_schema.sql) when the
      // caller supplied no orderBy.
      final transform = orderBy != null
          ? tourQuery.order(orderBy, ascending: false).range(from, to)
          : tourQuery.order('id').range(from, to);
      final rows = await _withTimeout(transform, _readTimeout, 'tours page fetch');
      return List<Map<String, dynamic>>.from(
        (rows as List).map((r) => Map<String, dynamic>.from(r)),
      );
    });
    if (tours.isEmpty) return [];

    final tourIds = tours.map((t) => t['id'] as String).toList();

    // Passengers + buses are independent once we know tour ids — fetch
    // them in parallel. Previously these awaits ran sequentially, which
    // cost one full extra round-trip per tour load on cellular networks
    // (passenger response gates the bus request for no reason). Each is
    // now fully paginated (X-5) rather than capped, so a large roster or
    // fleet never gets silently truncated.
    // X-5: order by 'id' (each table's PK — passengers/passenger_groups
    // confirmed in supabase/migrations/001_initial_schema.sql and
    // 006_seat_groups_priority.sql; buses' `id` PK is confirmed indirectly —
    // every generic write in this file addresses buses rows by `.eq('id',
    // entityId)`) so repeated .range() round trips see a stable row order
    // instead of an unordered one that can drop/duplicate rows at a page
    // boundary. Each page fetch also gets its own timeout budget (not an
    // aggregate one over the whole multi-page read) — see smartFetch.
    final passengersFuture = paginateRows<Map<String, dynamic>>(
      (from, to) async {
        final rows = await _withTimeout(
          _client
              .from('passengers')
              .select()
              .inFilter('tour_id', tourIds)
              .order('id')
              .range(from, to),
          _readTimeout,
          'passengers page fetch',
        );
        return List<Map<String, dynamic>>.from(
          (rows as List).map((r) => Map<String, dynamic>.from(r)),
        );
      },
    );
    // Buses are joined by buses.tour_id (one-to-many). A tour can have
    // multiple buses; the legacy single tours.bus_id is no longer used.
    final busesFuture = paginateRows<Map<String, dynamic>>(
      (from, to) async {
        final rows = await _withTimeout(
          _client
              .from('buses')
              .select()
              .inFilter('tour_id', tourIds)
              .order('id')
              .range(from, to),
          _readTimeout,
          'buses page fetch',
        );
        return List<Map<String, dynamic>>.from(
          (rows as List).map((r) => Map<String, dynamic>.from(r)),
        );
      },
    );
    // Passenger groups (cross-booking groups) are also keyed by tour_id.
    final groupsFuture = paginateRows<Map<String, dynamic>>(
      (from, to) async {
        final rows = await _withTimeout(
          _client
              .from('passenger_groups')
              .select()
              .inFilter('tour_id', tourIds)
              .order('id')
              .range(from, to),
          _readTimeout,
          'passenger_groups page fetch',
        );
        return List<Map<String, dynamic>>.from(
          (rows as List).map((r) => Map<String, dynamic>.from(r)),
        );
      },
    );

    // passengers + buses are the core relations and MUST load. passenger_groups
    // is new (migration 006) and OPTIONAL — if that table isn't present yet (or
    // its query fails for any reason) it must NOT take down the whole tour load
    // via Future.wait. Degrade to "no groups" instead of breaking every screen.
    final coreResults = await Future.wait([passengersFuture, busesFuture]);
    final passengersRaw = coreResults[0];
    final busesRaw = coreResults[1];
    List<Map<String, dynamic>> groupsRaw;
    try {
      groupsRaw = await groupsFuture;
    } catch (_) {
      groupsRaw = const [];
    }

    final passengersByTour = <String, List<Map<String, dynamic>>>{};
    for (final p in passengersRaw as List) {
      final m = Map<String, dynamic>.from(p as Map);
      // A customer-cancelled passenger (migration 034) is kept in the DB for
      // history but must never enter the active roster — drop it here so every
      // downstream capacity/roster calc is correct without per-site filtering.
      if (m['cancelled_at'] != null) continue;
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
    // Idempotent by entity id (23505 -> update-by-id fallback), so a timeout
    // that actually landed converges to the same row on retry.
    await _withRetry(
      () => _writeToServer(
        operation: 'insert',
        table: table,
        entityId: entityId,
        data: data,
      ),
      timeout: _writeTimeout,
      label: 'insert $table',
    );
  }

  Future<void> smartUpdate({
    required String table,
    required String entityId,
    required Map<String, dynamic> data,
  }) async {
    _ensureOnline();
    // update-by-id (empty result -> insert fallback) is idempotent: re-running
    // with the same data yields the identical row. Safe to retry on timeout.
    await _withRetry(
      () => _writeToServer(
        operation: 'update',
        table: table,
        entityId: entityId,
        data: data,
      ),
      timeout: _writeTimeout,
      label: 'update $table',
    );
  }

  Future<void> smartDelete({
    required String table,
    required String entityId,
  }) async {
    _ensureOnline();
    // delete-by-id is idempotent: deleting an already-deleted row is a no-op
    // (0 rows, no error). Safe to retry after a possibly-landed timeout.
    await _withRetry(
      () => _writeToServer(
        operation: 'delete',
        table: table,
        entityId: entityId,
        data: {'id': entityId},
      ),
      timeout: _writeTimeout,
      label: 'delete $table',
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
    // NON-IDEMPOTENT: running it twice swaps the pair back. A TimeoutException
    // means the request MAY have reached the server, so we must NOT retry on
    // timeout (that risks a silent double-swap / data corruption). Retry only
    // on a pre-send connection error, where we are certain nothing was sent.
    await _withRetry(
      () => _callRpc('swap_passenger_seats', {
        'p_passenger_a': passengerAId,
        'p_seats_a': seatsA,
        'p_passenger_b': passengerBId,
        'p_seats_b': seatsB,
      }),
      timeout: _writeTimeout,
      label: 'swap seats',
      isRetryable: retry.isPreSendConnectionError,
    );
  }

  /// Atomically apply a whole seat plan in one transaction. [assignments] is
  /// `[{"id": <passengerId>, "assigned_seats": [...]}, ...]`.
  Future<void> applySeatAssignments({
    required String tourId,
    required List<Map<String, dynamic>> assignments,
  }) async {
    _ensureOnline();
    // IDEMPOTENT: sets the whole plan absolutely (not a relative delta), so
    // re-applying the same assignments produces the same final seating whether
    // or not the first attempt landed. Safe to retry transient incl. timeout.
    await _withRetry(
      () => _callRpc('apply_seat_assignments', {
        'p_tour_id': tourId,
        'p_assignments': assignments,
      }),
      timeout: _writeTimeout,
      label: 'apply seat plan',
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

  /// Like [_callRpc] but returns the RPC's raw result — for functions that
  /// report a boolean / row outcome the caller must branch on (e.g. the admin
  /// dismiss-cancellation RPC). Same not-deployed signalling as [_callRpc].
  Future<dynamic> callRpcResult(String fn, Map<String, dynamic> params) async {
    try {
      return await _client.rpc(fn, params: params);
    } on PostgrestException catch (e) {
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
          final existing = e.code == '23505'
              ? await _client
                  .from(table)
                  .select('id')
                  .eq('id', entityId)
                  .maybeSingle()
              : null;
          switch (retry.resolveInsertConflict(
            code: e.code,
            rowWithIdExists: existing != null,
          )) {
            case retry.InsertConflictAction.updateById:
              final updateData = Map<String, dynamic>.from(clean)..remove('id');
              await _client.from(table).update(updateData).eq('id', entityId);
            case retry.InsertConflictAction.rethrowError:
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

  // ── Retry / transient-failure policy ────────────────────────────────
  // Single home for resilience. Each attempt is bounded by [_withTimeout];
  // only transient (network/transport/5xx/timeout) failures are re-run.
  // Terminal errors (RLS/auth, unique-violation, missing-function) surface
  // immediately, and the LAST error is rethrown once attempts are exhausted.

  /// Runs [action] up to [maxAttempts] times with exponential backoff
  /// (~400ms, then ~1200ms) between attempts. A retry happens only when the
  /// error is deemed retryable — by [isRetryable] if supplied, otherwise by
  /// [_isRetryable] (which honours [retryOnTimeout]). Idempotent callers pass
  /// nothing (retry transient incl. timeout); the non-idempotent swap RPC
  /// passes a pre-send-only predicate so a timeout never triggers a re-swap.
  ///
  /// [timeout] bounds each ATTEMPT of [action] as a whole. Pass `null` when
  /// [action] already bounds its own latency internally (X-5: a paginated
  /// read applies [_readTimeout] to each individual page round trip) — that
  /// avoids double-bounding a multi-page read with one more aggregate
  /// timeout on top of its own per-page ones.
  Future<T> _withRetry<T>(
    Future<T> Function() action, {
    required Duration? timeout,
    required String label,
    int maxAttempts = 3,
    bool retryOnTimeout = true,
    bool Function(Object error)? isRetryable,
  }) async {
    final predicate = isRetryable ??
        ((Object e) => retry.isRetryable(e, retryOnTimeout: retryOnTimeout));
    Object? lastError;
    StackTrace? lastStack;
    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      try {
        return timeout != null
            ? await _withTimeout(action(), timeout, label)
            : await action();
      } catch (e, st) {
        lastError = e;
        lastStack = st;
        final isLastAttempt = attempt == maxAttempts - 1;
        if (isLastAttempt || !predicate(e)) rethrow;
        final backoffMs = (400 * math.pow(3, attempt)).round();
        dev.log(
          'RETRY $label — attempt ${attempt + 1}/$maxAttempts failed ($e); '
          'waiting ${backoffMs}ms',
          name: 'SyncService',
        );
        await Future<void>.delayed(Duration(milliseconds: backoffMs));
      }
    }
    // Loop always returns or rethrows; this satisfies the analyzer.
    Error.throwWithStackTrace(lastError!, lastStack ?? StackTrace.current);
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
