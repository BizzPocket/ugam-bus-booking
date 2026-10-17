part of 'sync_service.dart';

/// The live-read plumbing behind [SyncService.smartFetch] and the cold-start
/// tour load: paginated table reads, tour rows + their relations, and the
/// nesting of those relations onto each tour.
extension _SyncReads on SyncService {
  /// One round trip of a paginated read, bounded by its own [readTimeout]
  /// budget (X-5 — per page, never one aggregate cap over the whole read),
  /// answered as fresh row maps.
  Future<List<Map<String, dynamic>>> _timedRows(
    Future<dynamic> query,
    String label,
  ) async => _rowMaps(await _withTimeout(query, readTimeout, label));

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
    var filtered = SyncService._liveOnly(
      table,
      _client.from(table).select(columns),
    );
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
      return _timedRows(transform, '$table page fetch');
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

  Future<
    ({
      List<Map<String, dynamic>> passengers,
      List<Map<String, dynamic>> buses,
      List<Map<String, dynamic>> groups,
    })
  >
  _fetchRelations(List<String> tourIds) async {
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
    })
  >
  _fetchRelationsUnlocked(List<String> tourIds) async {
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
    final passengersFuture = paginateRows<Map<String, dynamic>>((
      from,
      to,
    ) async {
      return _timedRows(
        SyncService._liveOnly(
          'passengers',
          _client
              .from('passengers')
              .select(SyncReadProjections.passengerSelect),
        ).inFilter('tour_id', tourIds).order('id').range(from, to),
        'passengers page fetch',
      );
    });
    // Buses are joined by buses.tour_id (one-to-many). A tour can have
    // multiple buses; the legacy single tours.bus_id is no longer used.
    // Cold start omits `layout` jsonb (measured ~71% of bus payload).
    final busesFuture = paginateRows<Map<String, dynamic>>((from, to) async {
      return _timedRows(
        SyncService._liveOnly(
          'buses',
          _client.from('buses').select(SyncReadProjections.busListSelect),
        ).inFilter('tour_id', tourIds).order('id').range(from, to),
        'buses page fetch',
      );
    });
    // Passenger groups (cross-booking groups) are also keyed by tour_id.
    final groupsFuture = paginateRows<Map<String, dynamic>>((from, to) async {
      return _timedRows(
        _client
            .from('passenger_groups')
            .select()
            .inFilter('tour_id', tourIds)
            .order('id')
            .range(from, to),
        'passenger_groups page fetch',
      );
    });

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
    })
    relations,
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
}

/// Every row of a PostgREST list answer as a fresh `Map<String, dynamic>`.
List<Map<String, dynamic>> _rowMaps(dynamic rows) =>
    List<Map<String, dynamic>>.from(
      (rows as List).map((r) => Map<String, dynamic>.from(r)),
    );
