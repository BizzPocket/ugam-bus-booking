part of '../tour_controller.dart';

/// On-demand roster + seat-layout loading for tours cold start skipped.
mixin _TourHydration on _TourDiskCache {
  /// In-flight hydrations, so two widgets opening the same tour at once
  /// share one request instead of racing two down a 2G link.
  final _hydrationsInFlight = <String, Future<void>>{};
  final _layoutFetchesInFlight = <String, Future<void>>{};

  /// True once [tourId]'s roster has actually been fetched. A screen can use
  /// this to show a loading state instead of an empty roster.
  bool isTourHydrated(String tourId) => _hydratedTourIds.contains(tourId);

  /// Loads passengers/buses/groups for [tourId] if cold start skipped them.
  ///
  /// Cold start deliberately fetches rosters only for RUNNING tours, because
  /// pulling every archived tour's roster on every launch is what breaks 2G
  /// (measured: 105 kB → 10.7s on EDGE, vs 10 kB → 1.0s when scoped). Opening
  /// an archived tour pays its own small cost, once, at the moment the user
  /// actually asks for it.
  ///
  /// Idempotent and race-safe: already-hydrated tours return immediately, and
  /// concurrent callers share a single in-flight request. On failure the tour
  /// is NOT marked hydrated, so a later open retries rather than showing an
  /// empty roster forever.
  Future<void> ensureTourHydrated(String tourId) {
    if (tourId.isEmpty || _hydratedTourIds.contains(tourId)) {
      return Future<void>.value();
    }
    // Local roster already present (test seed, optimistic write, or a prior
    // session that painted passengers/buses before the hydrate set was marked).
    // Cold-start headers always land with BOTH lists empty, so an empty tour
    // still pays the network hydrate when opened from archive.
    final local = getTour(tourId);
    if (local != null &&
        (local.passengers.isNotEmpty || local.buses.isNotEmpty)) {
      _hydratedTourIds.add(tourId);
      return Future<void>.value();
    }
    final existing = _hydrationsInFlight[tourId];
    if (existing != null) return existing;

    final future = _hydrateTour(tourId).whenComplete(() {
      _hydrationsInFlight.remove(tourId);
    });
    _hydrationsInFlight[tourId] = future;
    return future;
  }

  Future<void> _hydrateTour(String tourId) async {
    // ignore: invalid_use_of_protected_member
    final raw = tours.value;
    final idx = raw.indexWhere((t) => t.id == tourId);
    if (idx < 0) return;

    final rel = await _sync.fetchRelationsForTours([tourId]);

    // Mirror the cold-start read: a customer-cancelled passenger stays in the
    // DB for history but must never enter the active roster.
    final passengers = rel.passengers
        .where((m) => m['cancelled_at'] == null)
        .map(Passenger.fromMap)
        .toList();
    final buses = rel.buses.map(Bus.fromMap).toList();
    final groups = rel.groups.map(PassengerGroup.fromMap).toList();

    // Preserve layouts already paid for — hydrate must never throw away a
    // chart the agent is looking at just because the roster refresh omitted
    // the jsonb column.
    //
    // Read from the LIVE buses, not from `priorBuses`. That snapshot is taken
    // before the `await` above, and a realtime full row or a concurrent layout
    // merge writes grids into `tours` the whole time the relations request is in
    // flight. Re-attaching from the snapshot put the pre-fetch null back while
    // the layout-fetched mark survived, so `need` stayed empty, the grid was
    // never re-requested, and the chart declared "no seat plan" on a bus that
    // has one. Same race, same fix, as the cold-start merge in [_loadTours].
    //
    // The flag and the data must agree here too. A bus that leaves this merge
    // WITHOUT a grid, and which the server never answered `layout: null` for, is
    // not resolved — and a latched mark next to a null grid is now worse than a
    // wrong label: `charts_screen` offers "Restore seat map" on it, which
    // rebuilds a grid from the surviving seat ids and writes it over the live
    // one. Dropping the mark costs one cheap id+jsonb request instead.
    final withLayouts = _mergeLiveLayouts(buses, raw[idx].buses);

    raw[idx] = raw[idx].copyWith(
      passengers: passengers,
      buses: withLayouts,
      groups: groups,
    );
    _hydratedTourIds.add(tourId);
    _scheduleNotify();
    // An archived tour's roster is fetched exactly once, when it is first
    // opened. Persist it so opening it again — on a bus, with no signal — does
    // not have to.
    _scheduleDiskCacheSave();

    // Chart / capacity screens usually open next — pull layouts immediately
    // for this one tour rather than waiting on the background prefetch queue.
    await ensureBusLayoutsForTour(tourId);
  }

  /// Re-attach the grids already held in [live] onto [fresh] bus rows (which
  /// never carry the layout jsonb), then drop the layout-fetched mark of every
  /// merged bus left WITHOUT a grid — unless the server itself answered
  /// `layout: null` for it. Shared by the cold-start merge in [_loadTours] and
  /// [_hydrateTour]; see the call sites for the races this closes.
  List<Bus> _mergeLiveLayouts(List<Bus> fresh, List<Bus> live) {
    final liveById = {for (final b in live) b.id: b};
    final withLayouts = [
      for (final b in fresh)
        if (liveById[b.id]?.layout case final live?)
          b.copyWith(layout: live)
        else
          b,
    ];
    for (final b in withLayouts) {
      if (b.layout == null && !_layoutKnownNullBusIds.contains(b.id)) {
        _layoutFetchedBusIds.remove(b.id);
      }
    }
    return withLayouts;
  }

  /// Ensures every bus on [tourId] has had its `layout` jsonb fetched (or
  /// confirmed absent). Idempotent and coalesces concurrent callers.
  ///
  /// Cold start deliberately omits layouts (~71% of bus payload on a live
  /// probe). Call this before seating engine, seat charts, or manage-buses.
  Future<void> ensureBusLayoutsForTour(String tourId) {
    if (tourId.isEmpty) return Future<void>.value();
    final existing = _layoutFetchesInFlight[tourId];
    if (existing != null) return existing;
    final future = _fetchLayoutsForTour(tourId).whenComplete(() {
      _layoutFetchesInFlight.remove(tourId);
    });
    _layoutFetchesInFlight[tourId] = future;
    return future;
  }

  Future<void> _fetchLayoutsForTour(String tourId) async {
    final tour = getTour(tourId);
    if (tour == null || tour.buses.isEmpty) return;

    // Layouts already in memory (seed / prior prefetch / realtime full row)
    // count as fetched — never re-pay the 2G cost for jsonb we hold.
    for (final b in tour.buses) {
      if (b.layout != null) {
        _layoutFetchedBusIds.add(b.id);
        // Holding a grid outranks any earlier "server said null": this is how a
        // bus repaired by `recoverBusLayoutFor` (or re-generated by the wizard)
        // stops being treated as known-empty.
        _layoutKnownNullBusIds.remove(b.id);
      }
    }

    final need = tour.buses
        .where((b) => !_layoutFetchedBusIds.contains(b.id))
        .map((b) => b.id)
        .toList();
    if (need.isEmpty) return;

    final rows = await _sync.fetchBusLayouts(need);
    final byId = {
      for (final r in rows) r['id'] as String: r['layout'],
    };

    // ignore: invalid_use_of_protected_member
    final raw = tours.value;
    final idx = raw.indexWhere((t) => t.id == tourId);
    if (idx < 0) return;

    final updatedBuses = raw[idx].buses.map((b) {
      // Mark fetched only for a bus the server actually ANSWERED for.
      //
      // This used to be unconditional and ran before the two checks below, so a
      // bus the response simply did not carry — a partial page, a row filtered
      // by RLS, an id that raced a concurrent insert — was latched as "already
      // fetched" anyway. `need` then came back empty on every later call and the
      // grid was never re-requested for the life of the controller: one thin
      // response and the chart said "no seat layout" until the app restarted.
      //
      // A row that comes back with a NULL layout still counts as answered. That
      // is the server stating the grid is genuinely gone (the wipe this file's
      // `recoverBusLayoutFor` repairs), not a fetch that failed, and re-asking
      // would just burn the request on every rebuild.
      if (!byId.containsKey(b.id)) return b;
      _layoutFetchedBusIds.add(b.id);
      final layoutVal = byId[b.id];
      if (layoutVal == null) {
        // The server answered, and the answer is "there is no grid". Record it
        // so a later merge does not mistake this for a layout we merely failed
        // to hold and re-ask on every refresh.
        _layoutKnownNullBusIds.add(b.id);
        return b;
      }
      _layoutKnownNullBusIds.remove(b.id);
      return Bus.fromMap({
        ...b.toMap(),
        'layout': layoutVal,
      });
    }).toList();

    raw[idx] = raw[idx].copyWith(buses: updatedBuses);
    _capacityCache.remove(tourId);
    _actualCapacityCache.remove(tourId);
    _scheduleNotify();
    // The grids are the expensive half of the payload and the half a seat chart
    // cannot be drawn without — this is the save that makes the chart readable
    // offline at all. `_layoutKnownNullBusIds` is written above and rides along
    // in the same snapshot, so the "server said null" answer survives too.
    _scheduleDiskCacheSave();
  }

  /// Roster + layouts — what chart / fill / manage-buses need before work.
  Future<void> ensureTourReadyForSeating(String tourId) async {
    await ensureTourHydrated(tourId);
    await ensureBusLayoutsForTour(tourId);
  }
}
