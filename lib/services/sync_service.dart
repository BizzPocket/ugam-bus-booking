import 'dart:async';
import 'dart:developer' as dev;
import 'dart:math' as math;

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:get/get.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'supabase_service.dart';
import 'sync_read_projections.dart';
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

/// The tour ids whose passengers/buses/groups the COLD START should fetch.
///
/// Pure so it can be tested exhaustively — see
/// test/fuzz/cold_start_scope_fuzz_test.dart.
///
/// Rule: hydrate everything EXCEPT tours known to be completed.
///
/// The asymmetry is deliberate and load-bearing. Getting this wrong in the
/// "skip it" direction shows the user an EMPTY roster for a tour that has
/// fifty passengers — silent, and indistinguishable from real data loss.
/// Getting it wrong in the "fetch it" direction costs a few kB. So anything
/// this function does not positively recognise as completed is hydrated:
/// a null status, a missing key, a renamed enum value, a status from a newer
/// client version. Only the exact string `completed` is skipped.
///
/// Rows with an unusable id are dropped — an `in.()` filter containing null
/// or a non-string would fail the whole request rather than one row.
List<String> coldStartHydrationScope(List<Map<String, dynamic>> tourRows) {
  final out = <String>[];
  for (final row in tourRows) {
    final id = row['id'];
    if (id is! String || id.isEmpty) continue;
    if (row['status'] == 'completed') continue;
    out.add(id);
  }
  return out;
}

class SyncService extends GetxService {
  // Read timeout budget. Raised from 8s → 12s (wifi) and 28s (cellular):
  // measured EDGE cold-start of a scoped roster is ~10.7s payload alone before
  // TLS/query; a 12s cap blanks Home on real 2G. Applied PER PAGE (X-5) — each
  // individual .range() round trip inside a paginated read gets its own budget,
  // rather than one aggregate cap over the whole multi-page read (see smartFetch
  // below). That way a large roster that needs several round trips isn't killed
  // by a budget sized for one, while each round trip is still bounded.
  static const _readTimeoutWifi = Duration(seconds: 12);
  static const _readTimeoutCellular = Duration(seconds: 28);
  // Per-attempt write timeout. Writes are idempotent (keyed by entity id) so a
  // timeout that actually landed converges on retry — no need to inflate this.
  static const _writeTimeout = Duration(seconds: 12);

  /// Best-effort connectivity flag (interface up — not a reachability
  /// guarantee). Used to fail writes fast when plainly offline.
  final isOnline = true.obs;

  /// True when the active interface looks cellular (or unknown). Drives the
  /// longer read budget so 2G/3G agents aren't killed by a wifi-sized timeout.
  final isCellular = true.obs;

  /// Caps concurrent live reads so money/memory/inbox can't starve the Home
  /// tour wave on a 2G radio. Wifi allows more parallelism.
  static const _maxCellularReads = 2;
  static const _maxWifiReads = 6;
  int _inflightReads = 0;
  final _readWaiters = <Completer<void>>[];

  StreamSubscription? _connectivitySub;

  SupabaseClient get _client => SupabaseService.instance.client;

  /// Effective per-page read timeout for the current radio.
  @visibleForTesting
  Duration get readTimeout =>
      isCellular.value ? _readTimeoutCellular : _readTimeoutWifi;

  /// Serialises / bounds concurrent reads for the current radio.
  Future<T> _withReadSlot<T>(Future<T> Function() action) async {
    final max = isCellular.value ? _maxCellularReads : _maxWifiReads;
    while (_inflightReads >= max) {
      final gate = Completer<void>();
      _readWaiters.add(gate);
      await gate.future;
    }
    _inflightReads++;
    try {
      return await action();
    } finally {
      _inflightReads--;
      if (_readWaiters.isNotEmpty) {
        _readWaiters.removeAt(0).complete();
      }
    }
  }

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
    void apply(List<ConnectivityResult> results) {
      isOnline.value = results.any((r) => r != ConnectivityResult.none);
      // Prefer a longer budget whenever wifi/ethernet is NOT clearly present.
      // `other` / empty / mobile / vpn-alone all get cellular headroom — better
      // to wait than to blank Home on a flaky EDGE link.
      final hasFastPipe = results.any(
        (r) =>
            r == ConnectivityResult.wifi || r == ConnectivityResult.ethernet,
      );
      isCellular.value = !hasFastPipe;
    }

    _connectivitySub = Connectivity().onConnectivityChanged.listen(apply);
    Connectivity().checkConnectivity().then(apply);
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
  /// [cacheKey]/[maxAge] are retained for call-site compatibility and
  /// are unused now. [select] IS used — pass a column list to avoid `select(*)`
  /// on 2G (see [SyncReadProjections]).
  /// [error] carries the SERVER's reason when [failed] is true, or null when
  /// the failure was simply "offline".
  ///
  /// It exists because losing it cost a full debugging session: a client filter
  /// on a column the live DB did not have made every read 400 with
  /// `column tours.deleted_at does not exist`, and the only thing the user saw
  /// was "check your connection" — on a healthy network. A schema error that
  /// presents as a network error sends you looking in exactly the wrong place.
  Future<({List<Map<String, dynamic>> rows, bool failed, String? error})>
  smartFetch({
    required String table,
    required String cacheKey,
    String? select,
    Map<String, String>? filters,
    String? orderBy,
    int maxAge = 300000,
  }) async {
    // Do NOT short-circuit on [isOnline]. connectivity_plus often reports
    // `none` for a beat on cold start (or never emits a follow-up event after a
    // false-negative checkConnectivity), which used to blank the home screen
    // with "check your connection" even when Wi‑Fi was up — Retry then worked
    // because the flag had corrected by the tap. Writes still fail-fast on
    // [isOnline] below; reads must attempt the network and let a real socket
    // / timeout failure surface instead.
    return _withReadSlot(() async {
      try {
        // Reads are idempotent — retry transient failures (incl. timeout) so one
        // slow moment on cellular no longer blanks the screen. Terminal errors
        // (auth/RLS/missing-table) still surface immediately via [_isRetryable].
        //
        // timeout: null — a paginated read can be several sequential round
        // trips (X-5); each one already carries its own readTimeout budget
        // (applied inside the .range() closures in _fetchFromSupabase /
        // _fetchToursWithRelations), so wrapping the WHOLE multi-page read in
        // one more readTimeout here would let a genuinely large roster time
        // out in full even though every individual round trip was healthy.
        final rows = await _withRetry(
          () => _fetchFromSupabase(table, filters, orderBy, select: select),
          timeout: null,
          label: '$table fetch',
        );
        return (rows: rows, failed: false, error: null);
      } on PostgrestException catch (e, st) {
        // 054 not applied yet: disarm the archive filter and read again, rather
        // than reporting a schema gap to the user as a network failure. Fires at
        // most once per process — see [_isMissingDeletedAt].
        if (_disarmIfMissingDeletedAt(e)) {
          try {
            final rows = await _withRetry(
              () => _fetchFromSupabase(table, filters, orderBy, select: select),
              timeout: null,
              label: '$table fetch (unfiltered)',
            );
            return (rows: rows, failed: false, error: null);
          } catch (e2, st2) {
            dev.log('FETCH FAILED $table — $e2\n$st2', name: 'SyncService');
            return (
              rows: const <Map<String, dynamic>>[],
              failed: true,
              error: describeReadError(e2),
            );
          }
        }
        dev.log('FETCH FAILED $table — $e\n$st', name: 'SyncService');
        return (
          rows: const <Map<String, dynamic>>[],
          failed: true,
          error: describeReadError(e),
        );
      } catch (e, st) {
        dev.log('FETCH FAILED $table — $e\n$st', name: 'SyncService');
        return (
          rows: const <Map<String, dynamic>>[],
          failed: true,
          error: describeReadError(e),
        );
      }
    });
  }

  /// A short, human-readable reason for a failed read.
  ///
  /// PostgrestException carries the useful part (`message`, plus a SQLSTATE in
  /// `code`); everything else falls back to the exception's own toString. The
  /// point is that whatever reaches the user names the ACTUAL fault — a missing
  /// column, an RLS refusal — rather than being flattened into "network error".
  static String describeReadError(Object e) {
    if (e is PostgrestException) {
      final code = e.code;
      return code == null || code.isEmpty
          ? e.message
          : '${e.message} ($code)';
    }
    return e.toString();
  }

  Future<List<Map<String, dynamic>>> _fetchFromSupabase(
    String table,
    Map<String, String>? filters,
    String? orderBy, {
    String? select,
  }) async {
    if (table == 'tours') return _fetchToursWithRelations(filters, orderBy);

    // Archived rows never reach the app (054). Applied before the caller's
    // filters so it can't be dropped by a call site that builds its own.
    // Prefer an explicit column projection when the caller supplies one —
    // `select(*)` is what blew bus payloads on 2G (layout jsonb).
    final columns = (select == null || select.isEmpty) ? '*' : select;
    var filtered = _liveOnly(table, _client.from(table).select(columns));
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
          await _withTimeout(transform, readTimeout, '$table page fetch');
      return List<Map<String, dynamic>>.from(
        (rows as List).map((r) => Map<String, dynamic>.from(r)),
      );
    });
  }

  Future<List<Map<String, dynamic>>> _fetchToursWithRelations(
    Map<String, String>? filters,
    String? orderBy,
  ) async {
    final tours = await fetchTourRows(filters: filters, orderBy: orderBy);
    if (tours.isEmpty) return [];

    // COLD-START SCOPE (2G).
    //
    // Rosters are fetched only for tours that are still RUNNING. A completed
    // tour is archived history: its roster is re-downloaded on every single
    // cold start forever, so the payload grows without bound as the business
    // runs — after a year of trips the launch fetch is several times what it
    // is today, and it is already the thing that breaks 2G.
    //
    // Measured on a realistic 25-tour book (50 passengers each), gzipped as
    // the wire actually carries it:
    //   all tours hydrated  → 105 kB → 10.7s on EDGE, 43s on GPRS
    //   running tours only  →  10 kB →  1.0s on EDGE,  4.1s on GPRS
    // The 12s read budget is what the first one blows once TLS handshake and
    // query time are added on a 2G link.
    //
    // Live admin probe (2026-08-09): bus `layout` jsonb is ~71% of owner-wide
    // bus bytes. Cold start therefore pulls bus METADATA only; charts call
    // [fetchBusLayouts] on demand / via TourController background prefetch.
    //
    // An archived tour's roster is loaded on demand the moment it is opened —
    // see [fetchRelationsForTours] and TourController.ensureTourHydrated.
    final relations = await _fetchRelations(coldStartHydrationScope(tours));
    return _attachRelations(tours, relations);
  }

  /// Tour header rows only — no passengers/buses. Used so the UI can paint
  /// titles on 2G before the heavier roster round-trips finish.
  Future<List<Map<String, dynamic>>> fetchTourRows({
    Map<String, String>? filters,
    String? orderBy,
  }) async {
    return _withReadSlot(() async {
      var tourQuery = _liveOnly('tours', _client.from('tours').select());
      if (filters != null) {
        filters.forEach((k, v) {
          tourQuery = tourQuery.eq(k, v);
        });
      }
      return paginateRows<Map<String, dynamic>>((from, to) async {
        final transform = orderBy != null
            ? tourQuery.order(orderBy, ascending: false).range(from, to)
            : tourQuery.order('id').range(from, to);
        final rows =
            await _withTimeout(transform, readTimeout, 'tours page fetch');
        return List<Map<String, dynamic>>.from(
          (rows as List).map((r) => Map<String, dynamic>.from(r)),
        );
      });
    });
  }

  /// Fetches `layout` jsonb for the given bus ids only. Chunked to keep URLs
  /// short on slow links. Empty [busIds] → no request.
  Future<List<Map<String, dynamic>>> fetchBusLayouts(
    List<String> busIds,
  ) async {
    final ids = busIds.where((id) => id.isNotEmpty).toSet().toList();
    if (ids.isEmpty) return const [];

    return _withReadSlot(() async {
      const chunkSize = 40;
      final out = <Map<String, dynamic>>[];
      for (var i = 0; i < ids.length; i += chunkSize) {
        final chunk = ids.sublist(i, math.min(i + chunkSize, ids.length));
        final page = await _withRetry(
          () async {
            final rows = await _withTimeout(
              _liveOnly(
                'buses',
                _client
                    .from('buses')
                    .select(SyncReadProjections.busLayoutSelect),
              ).inFilter('id', chunk),
              readTimeout,
              'bus layouts fetch',
            );
            return List<Map<String, dynamic>>.from(
              (rows as List).map((r) => Map<String, dynamic>.from(r)),
            );
          },
          timeout: null,
          label: 'bus layouts',
        );
        out.addAll(page);
      }
      return out;
    });
  }

  /// Fetches passengers + buses + groups for [tourIds] and attaches nothing —
  /// callers decide how to merge. Public so an archived tour can be hydrated
  /// on demand when the user actually opens it.
  ///
  /// Returns empty lists for an empty [tourIds] WITHOUT issuing any request:
  /// an `in.()` filter with no values is both a wasted round trip and, on a
  /// 2G link, a wasted handshake.
  Future<
      ({
        List<Map<String, dynamic>> passengers,
        List<Map<String, dynamic>> buses,
        List<Map<String, dynamic>> groups,
      })> fetchRelationsForTours(List<String> tourIds) =>
      _fetchRelations(tourIds);

  Future<
      ({
        List<Map<String, dynamic>> passengers,
        List<Map<String, dynamic>> buses,
        List<Map<String, dynamic>> groups,
      })> _fetchRelations(List<String> tourIds) async {
    if (tourIds.isEmpty) {
      return (
        passengers: const <Map<String, dynamic>>[],
        buses: const <Map<String, dynamic>>[],
        groups: const <Map<String, dynamic>>[],
      );
    }

    return _withReadSlot(() => _fetchRelationsUnlocked(tourIds));
  }

  Future<
      ({
        List<Map<String, dynamic>> passengers,
        List<Map<String, dynamic>> buses,
        List<Map<String, dynamic>> groups,
      })> _fetchRelationsUnlocked(List<String> tourIds) async {
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
          _liveOnly(
            'passengers',
            _client
                .from('passengers')
                .select(SyncReadProjections.passengerSelect),
          )
              .inFilter('tour_id', tourIds)
              .order('id')
              .range(from, to),
          readTimeout,
          'passengers page fetch',
        );
        return List<Map<String, dynamic>>.from(
          (rows as List).map((r) => Map<String, dynamic>.from(r)),
        );
      },
    );
    // Buses are joined by buses.tour_id (one-to-many). A tour can have
    // multiple buses; the legacy single tours.bus_id is no longer used.
    // Cold start omits `layout` jsonb (measured ~71% of bus payload).
    final busesFuture = paginateRows<Map<String, dynamic>>(
      (from, to) async {
        final rows = await _withTimeout(
          _liveOnly(
            'buses',
            _client.from('buses').select(SyncReadProjections.busListSelect),
          )
              .inFilter('tour_id', tourIds)
              .order('id')
              .range(from, to),
          readTimeout,
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
          readTimeout,
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

    return (passengers: passengersRaw, buses: busesRaw, groups: groupsRaw);
  }

  /// Groups [relations] by tour_id and nests them onto each row of [tours].
  ///
  /// A tour with no entry in the relation maps gets empty lists — which is
  /// correct for BOTH "this tour genuinely has no passengers" and "this
  /// archived tour was not hydrated at cold start". The caller distinguishes
  /// the two (TourController tracks which tours it has hydrated); this layer
  /// only shapes data.
  List<Map<String, dynamic>> _attachRelations(
    List<Map<String, dynamic>> tours,
    ({
      List<Map<String, dynamic>> passengers,
      List<Map<String, dynamic>> buses,
      List<Map<String, dynamic>> groups,
    }) relations,
  ) {
    final passengersByTour = <String, List<Map<String, dynamic>>>{};
    for (final p in relations.passengers) {
      final m = Map<String, dynamic>.from(p as Map);
      // A customer-cancelled passenger (migration 034) is kept in the DB for
      // history but must never enter the active roster — drop it here so every
      // downstream capacity/roster calc is correct without per-site filtering.
      if (m['cancelled_at'] != null) continue;
      final tId = m['tour_id'] as String?;
      if (tId != null) passengersByTour.putIfAbsent(tId, () => []).add(m);
    }

    final busesByTour = <String, List<Map<String, dynamic>>>{};
    for (final b in relations.buses) {
      final m = Map<String, dynamic>.from(b);
      final tId = m['tour_id'] as String?;
      if (tId != null) busesByTour.putIfAbsent(tId, () => []).add(m);
    }

    final groupsByTour = <String, List<Map<String, dynamic>>>{};
    for (final g in relations.groups) {
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

  // ── Soft delete (migration 054) ─────────────────────────────────────

  /// Tables that carry `deleted_at` and must therefore NEVER return archived
  /// rows to the app (migration 054).
  ///
  /// The filter is applied HERE, in the one place every generic read passes
  /// through, rather than at ~40 call sites — one missed call site would leak
  /// a deleted tour's rows into a live money total, and the reader would have
  /// no way to tell. Adding a table to this set is the whole opt-in.
  ///
  /// It is deliberately NOT enforced in RLS: the live policy set has diverged
  /// from the migration files before (see the notes on 054), so rewriting
  /// policies blind is the riskier half of the trade. The archive is reached
  /// through explicit RPCs (`deleted_tours()`), never by relaxing this.
  static const softDeletableTables = {
    'tours',
    'buses',
    'passengers',
    'collections',
    'expenses',
    'incomes',
    'bus_handovers',
  };

  /// False once the server has told us `deleted_at` does not exist yet — i.e.
  /// migration 054 has not been applied to this database.
  ///
  /// DEPLOY-ORDER SAFETY. Filtering on a column the live schema lacks makes
  /// EVERY read of these seven tables 400, which presents to the user as a
  /// connection failure on a healthy network. That is the exact trap this
  /// codebase has already paid for once.
  ///
  /// Degrading to an unfiltered read is not a correctness compromise, it is
  /// provably equivalent: with no `deleted_at` column, nothing can ever have
  /// been archived, so "all rows" and "live rows" are the same set. The moment
  /// 054 lands the probe stops firing and the filter is permanent.
  static bool _softDeleteColumnLive = true;

  /// True when the server accepts `deleted_at` filters (054 applied).
  ///
  /// Public because [FinanceController] runs the one money read that does not
  /// pass through [smartFetch] and must arm/disarm its own filter in step —
  /// otherwise the cross-tour P&L would be the single query still 400ing on a
  /// database where 054 is pending.
  static bool get softDeleteFilterActive => _softDeleteColumnLive;

  @visibleForTesting
  static void resetSoftDeleteProbe() => _softDeleteColumnLive = true;

  /// Whether [e] is the server saying `deleted_at` does not exist.
  ///
  /// PURE — no side effects, so it can be tested directly. Both conditions are
  /// required: an undefined-column error AND the column being `deleted_at`.
  /// Matching on "does not exist" alone would let an unrelated schema gap
  /// silently switch the archive filter off for the whole session.
  @visibleForTesting
  static bool isMissingDeletedAtError(Object e) {
    if (e is! PostgrestException) return false;
    final undefined = e.code == '42703' ||
        e.message.toLowerCase().contains('does not exist');
    return undefined && e.message.contains('deleted_at');
  }

  /// Recognises the "054 isn't applied yet" failure and disarms the filter.
  /// Returns true when the caller should retry the read unfiltered.
  static bool _disarmIfMissingDeletedAt(Object e) {
    if (!isMissingDeletedAtError(e)) return false;
    if (_softDeleteColumnLive) {
      _softDeleteColumnLive = false;
      dev.log(
        'deleted_at is missing on the server — migration 054 has NOT been '
        'applied. Falling back to unfiltered reads (safe: nothing can be '
        'archived yet). Apply 054_soft_delete.sql.',
        name: 'SyncService',
      );
    }
    return true;
  }

  /// Restricts [query] to live rows when [table] is soft-deletable.
  ///
  /// Generic over the builder type so it composes with the paginated reads
  /// below without forcing an early `.select()` materialisation.
  static PostgrestFilterBuilder<T> _liveOnly<T>(
    String table,
    PostgrestFilterBuilder<T> query,
  ) =>
      (_softDeleteColumnLive && softDeletableTables.contains(table))
          ? query.isFilter('deleted_at', null)
          : query;

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

  /// Column-scoped update: writes ONLY [fields], leaving every other column on
  /// the row untouched.
  ///
  /// Prefer this over [smartUpdate] whenever a caller changes a few known
  /// columns. [smartUpdate] sends a WHOLE-entity map, so every column it carries
  /// is overwritten with whatever the in-memory model happened to hold. That is
  /// how bus `layout` jsonb was being destroyed: cold start deliberately omits
  /// that column to save 2G bytes, so an unrelated write — setting a handler
  /// pointer — shipped `layout: null` and erased the seat map of a bus that had
  /// riders assigned to it.
  ///
  /// Also far cheaper on a slow link: a one-column patch is tens of bytes where
  /// a full bus row is dominated by its seat grid.
  ///
  /// Unlike [smartUpdate] this NEVER falls back to insert — see the 'patch'
  /// branch of [_writeToServer] for why a partial insert is unacceptable.
  Future<void> updatePatch({
    required String table,
    required String entityId,
    required Map<String, dynamic> fields,
  }) async {
    if (fields.isEmpty) return;
    _ensureOnline();
    // Idempotent: re-applying identical field values yields the identical row,
    // so a timed-out patch that actually landed is safe to re-run.
    await _withRetry(
      () => _writeToServer(
        operation: 'patch',
        table: table,
        entityId: entityId,
        data: fields,
      ),
      timeout: _writeTimeout,
      label: 'patch $table',
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
    //
    // Skipped for 'patch': a patch promises to touch ONLY the caller's columns,
    // and an UPDATE does not need owner_id in the payload anyway — RLS matches
    // the row on its existing owner.
    final authUid = _client.auth.currentUser?.id;
    if (operation != 'patch' &&
        _ownerScopedTables.contains(table) &&
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
      case 'patch':
        // Column-scoped update: writes ONLY the keys the caller supplied and
        // NEVER falls back to insert. The insert fallback above is safe for a
        // whole-entity map but catastrophic for a partial one — it would
        // materialise a row containing just the patched columns and defaults
        // for everything else.
        //
        // A patch that matches no row is therefore a BUG (wrong id, or the row
        // was deleted underneath us), and it surfaces as an error rather than
        // being papered over with a half-built row.
        final patchData = Map<String, dynamic>.from(clean)..remove('id');
        final patched = await _client
            .from(table)
            .update(patchData)
            .eq('id', entityId)
            .select();
        if ((patched as List).isEmpty) {
          throw StateError(
            'patch $table/$entityId matched no row — refusing to insert a '
            'partial row from ${patchData.keys.join(', ')}',
          );
        }
        break;
      case 'delete':
        // SOFT DELETE (054): money-bearing rows are archived, never destroyed.
        // Routed here rather than at the ~8 call sites so no future delete can
        // opt out by accident — the table set is the single switch.
        //
        // Idempotent like the hard delete it replaces: re-stamping deleted_at
        // on an already-archived row is harmless, so a timed-out write that
        // actually landed still converges on retry. `deleted_by` is only
        // stamped when there is a signed-in admin; handler-initiated deletes
        // record their own actor server-side in their RPCs.
        if (softDeletableTables.contains(table)) {
          final archive = <String, dynamic>{
            'deleted_at': DateTime.now().toUtc().toIso8601String(),
          };
          if (authUid != null) archive['deleted_by'] = authUid;
          await _client.from(table).update(archive).eq('id', entityId);
        } else {
          await _client.from(table).delete().eq('id', entityId);
        }
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
  /// read applies [readTimeout] to each individual page round trip) — that
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
