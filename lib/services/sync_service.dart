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

part 'sync_service_reads.dart';
part 'sync_service_retry.dart';
part 'sync_service_writes.dart';

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

/// Online-only Supabase access layer.
///
/// The former SQLite offline cache + write-queue (`OfflineDatabase`) was
/// removed: it let stale tours survive logout / reinstall (Android Auto
/// Backup restored the DB) and masked real fetch failures as empty
/// results. Reads now hit Supabase live; writes await the server and
/// throw on failure so callers can revert optimistic UI and surface the
/// real error. [isOnline] still tracks connectivity so writes fail fast
/// with a clear message instead of hanging when there is no network.
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

  /// The signed-in admin's auth uid, or null when nobody is signed in (or the
  /// client isn't initialised, e.g. in tests). RLS only lets an admin change
  /// rows whose `owner_id` is this uid — callers check it up front so a write
  /// the database would silently skip (0 rows, no error) is refused visibly.
  String? get currentUserId {
    try {
      return _client.auth.currentUser?.id;
    } catch (_) {
      return null;
    }
  }

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
    // A failed read never throws into the UI: log it, answer no rows, and carry
    // the server's reason.
    ({List<Map<String, dynamic>> rows, bool failed, String? error}) failure(
      Object e,
      StackTrace st,
    ) {
      dev.log('FETCH FAILED $table — $e\n$st', name: 'SyncService');
      return (
        rows: const <Map<String, dynamic>>[],
        failed: true,
        error: describeReadError(e),
      );
    }

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
            return failure(e2, st2);
          }
        }
        return failure(e, st);
      } catch (e, st) {
        return failure(e, st);
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
        return _timedRows(
          transform,
          'tours page fetch',
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
            return _timedRows(
              _liveOnly(
                'buses',
                _client
                    .from('buses')
                    .select(SyncReadProjections.busLayoutSelect),
              ).inFilter('id', chunk),
              'bus layouts fetch',
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

  /// Live bus count per tour for [tourIds] — `id, tour_id` only, no roster.
  ///
  /// Exists for the archive: cold start skips completed tours' relations
  /// ([coldStartHydrationScope]), so their `Tour.buses` is empty and the P&L
  /// would print "0 buses" for a trip that ran three. Hydrating every archived
  /// roster just to count buses is exactly the payload the scope avoids on 2G;
  /// two short columns per bus is not. Tours with no live bus are absent from
  /// the map (read: 0). Empty [tourIds] → no request.
  Future<Map<String, int>> fetchBusCountsByTour(List<String> tourIds) async {
    final ids = tourIds.where((id) => id.isNotEmpty).toSet().toList();
    if (ids.isEmpty) return const {};

    return _withReadSlot(() async {
      const chunkSize = 40;
      final counts = <String, int>{};
      for (var i = 0; i < ids.length; i += chunkSize) {
        final chunk = ids.sublist(i, math.min(i + chunkSize, ids.length));
        final rows = await paginateRows<Map<String, dynamic>>(
          (from, to) async {
            return _timedRows(
              _liveOnly(
                'buses',
                _client.from('buses').select('id,tour_id'),
              ).inFilter('tour_id', chunk).order('id').range(from, to),
              'bus counts fetch',
            );
          },
        );
        for (final r in rows) {
          final tid = r['tour_id'];
          if (tid is! String || tid.isEmpty) continue;
          counts[tid] = (counts[tid] ?? 0) + 1;
        }
      }
      return counts;
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
    await _retriedWrite('insert', table, entityId, data);
  }

  Future<void> smartUpdate({
    required String table,
    required String entityId,
    required Map<String, dynamic> data,
  }) async {
    _ensureOnline();
    // update-by-id (empty result -> insert fallback) is idempotent: re-running
    // with the same data yields the identical row. Safe to retry on timeout.
    await _retriedWrite('update', table, entityId, data);
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
    await _retriedWrite('patch', table, entityId, fields);
  }

  Future<void> smartDelete({
    required String table,
    required String entityId,
  }) async {
    _ensureOnline();
    // delete-by-id is idempotent: deleting an already-deleted row is a no-op
    // (0 rows, no error). Safe to retry after a possibly-landed timeout.
    await _retriedWrite('delete', table, entityId, {'id': entityId});
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

  /// Like [_callRpc] but returns the RPC's raw result — for functions that
  /// report a boolean / row outcome the caller must branch on (e.g. the admin
  /// dismiss-cancellation RPC). Same not-deployed signalling as [_callRpc].
  Future<dynamic> callRpcResult(String fn, Map<String, dynamic> params) async {
    return await _rpcOrUnavailable(fn, params);
  }
}
