part of '../tour_controller.dart';

/// Server load pipeline, realtime apply, and the post-load sweeps.
mixin _TourSync on _TourGroups {
  StreamSubscription<DataChangedEvent>? _realtimeSub;

  Timer? _refreshDebounce;

  /// Cold-start entry: wait for [AuthController.whenRestored] so the first
  /// fetch runs with JWT + admin owner scope, then load. If that still fails
  /// with an empty list, automatically retry once — the same action the user
  /// was forced to take on every launch when connectivity/auth raced.
  Future<void> _bootstrapLoad() async {
    // Disk BEFORE network. The cached graph paints in the time one file read
    // takes, so Home and every seat chart are readable while the fetch is still
    // opening its socket — and stay readable if it never lands. Nothing here
    // suppresses the fetch that follows.
    await hydrateFromDiskCache();
    await _awaitAuthRestored();
    await _loadTours();
    if (hasError.value && tours.isEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 700));
      if (hasError.value && tours.isEmpty) {
        await _loadTours();
      }
    }
  }

  Future<void> _awaitAuthRestored() async {
    if (!Get.isRegistered<AuthController>()) return;
    try {
      await Get.find<AuthController>().whenRestored.timeout(
        const Duration(seconds: 12),
      );
    } on TimeoutException {
      // Same bound as splash — proceed with whatever auth state we have.
    }
  }

  void _subscribeToChanges() {
    // Refresh whenever we come back online — covers offline → online edges
    // where realtime might have missed events while the socket was down.
    ever(_sync.isOnline, (online) {
      if (online) _scheduleRefresh();
    });

    // Live updates: apply each Postgres change directly to local state.
    // The previous implementation triggered a full debounced refetch
    // (3 round-trips: tours + passengers + buses) on every event, which
    // thrashes hard when two devices are writing at the same time. Now
    // we mutate the matching row in place; we only fall back to a full
    // refetch when the payload lacks information we need (e.g. a
    // passenger event arrived before its parent tour) or anything in
    // the incremental path throws.
    _realtimeSub = _realtime.events.listen(_applyRealtimeEvent);
  }

  /// Coalesce bursts of realtime events into a single fetch — used by
  /// connectivity-recovery edges and as the safety net when an
  /// incremental apply can't resolve a parent row locally.
  void _scheduleRefresh() {
    _refreshDebounce?.cancel();
    _refreshDebounce = Timer(const Duration(milliseconds: 300), _loadTours);
  }

  void _applyRealtimeEvent(DataChangedEvent event) {
    try {
      switch (event.table) {
        case LiveTable.tours:
          _applyTourEvent(event);
        case LiveTable.passengers:
          _applyPassengerEvent(event);
        case LiveTable.buses:
          _applyBusEvent(event);
        case LiveTable.bookingRequests:
          // Customer-side audit row. The companion passenger row's own
          // realtime event is what carries the data we render, so we
          // can ignore this stream entirely from the tour controller.
          return;
      }
    } catch (e, st) {
      // Defensive: if a payload has an unexpected shape, drop back to
      // the old behaviour rather than leaving the local cache out of
      // sync with the server.
      dev.log('realtime apply failed: $e\n$st', name: 'TourController');
      _scheduleRefresh();
    }
  }

  void _applyTourEvent(DataChangedEvent event) {
    // ignore: invalid_use_of_protected_member
    final raw = tours.value;
    if (event.eventType == PostgresChangeEvent.delete) {
      final id = event.oldRow?['id']?.toString();
      if (id == null) return;
      final before = raw.length;
      raw.removeWhere((t) => t.id == id);
      if (raw.length != before) _scheduleNotify();
      return;
    }
    final row = event.newRow;
    if (row == null) return;
    final id = row['id']?.toString();
    if (id == null) return;

    final idx = raw.indexWhere((t) => t.id == id);
    if (idx < 0) {
      // Brand-new tour. Nested passengers/buses arrive via their own
      // realtime events; in the meantime we render the tour with empty
      // lists, which is what the server actually has at this instant.
      raw.add(Tour.fromMap(row));
      _scheduleNotify();
      return;
    }
    // Update — preserve the nested passengers/buses we already hold so
    // we don't drop them just because they're not in the top-level
    // tours payload.
    final existing = raw[idx];
    raw[idx] = Tour.fromMap(
      row,
    ).copyWith(buses: existing.buses, passengers: existing.passengers);
    _scheduleNotify();
  }

  void _applyPassengerEvent(DataChangedEvent event) {
    // ignore: invalid_use_of_protected_member
    final raw = tours.value;
    if (event.eventType == PostgresChangeEvent.delete) {
      final tourId = event.oldRow?['tour_id']?.toString();
      final passengerId = event.oldRow?['id']?.toString();
      if (tourId == null || passengerId == null) return;
      final idx = raw.indexWhere((t) => t.id == tourId);
      if (idx < 0) return;
      final t = raw[idx];
      final next = t.passengers.where((p) => p.id != passengerId).toList();
      if (next.length == t.passengers.length) return;
      raw[idx] = t.copyWith(passengers: next);
      _scheduleNotify();
      return;
    }
    final row = event.newRow;
    if (row == null) return;
    final tourId = row['tour_id']?.toString();
    final pid = row['id']?.toString();
    if (tourId == null || pid == null) return;
    final idx = raw.indexWhere((t) => t.id == tourId);
    if (idx < 0) {
      // Parent tour not loaded yet — likely racing its own INSERT. Fall
      // back to a debounced refetch so we don't drop the passenger.
      _scheduleRefresh();
      return;
    }
    final t = raw[idx];
    final newPassenger = Passenger.fromMap(row);
    final next = List<Passenger>.from(t.passengers);
    final pIdx = next.indexWhere((p) => p.id == pid);
    // A customer-cancelled passenger (migration 034) is kept in the DB but must
    // leave the active roster — treat a cancel like a delete for the in-memory
    // tour so capacity/roster stop counting it. Nothing to do if it was never
    // in the active list.
    if (newPassenger.isCancelled) {
      if (pIdx < 0) return;
      next.removeAt(pIdx);
      raw[idx] = t.copyWith(passengers: next);
      _scheduleNotify();
      return;
    }
    if (pIdx < 0) {
      next.add(newPassenger);
    } else {
      next[pIdx] = newPassenger;
    }
    raw[idx] = t.copyWith(passengers: next);
    _scheduleNotify();
  }

  void _applyBusEvent(DataChangedEvent event) {
    // ignore: invalid_use_of_protected_member
    final raw = tours.value;
    if (event.eventType == PostgresChangeEvent.delete) {
      final tourId = event.oldRow?['tour_id']?.toString();
      final busId = event.oldRow?['id']?.toString();
      if (tourId == null || busId == null) return;
      final idx = raw.indexWhere((t) => t.id == tourId);
      if (idx < 0) return;
      final t = raw[idx];
      final next = t.buses.where((b) => b.id != busId).toList();
      if (next.length == t.buses.length) return;
      raw[idx] = t.copyWith(buses: next);
      _scheduleNotify();
      return;
    }
    final row = event.newRow;
    if (row == null) return;
    final tourId = row['tour_id']?.toString();
    final bid = row['id']?.toString();
    if (tourId == null || bid == null) return;
    final idx = raw.indexWhere((t) => t.id == tourId);
    if (idx < 0) {
      _scheduleRefresh();
      return;
    }
    final t = raw[idx];
    final newBus = Bus.fromMap(row);
    final next = List<Bus>.from(t.buses);
    final bIdx = next.indexWhere((b) => b.id == bid);
    if (bIdx < 0) {
      next.add(newBus);
    } else {
      next[bIdx] = newBus;
    }
    raw[idx] = t.copyWith(buses: next);
    _scheduleNotify();
  }

  /// Tour visibility scope for the current viewer:
  /// - An authenticated admin sees ONLY their own tours (an explicit `owner_id`
  ///   filter on top of RLS), under a per-admin cache key so an earlier
  ///   anonymous "all public tours" fetch (done at app start, before login)
  ///   can't bleed into the admin's list.
  /// - A customer / anonymous viewer sees ALL public tours
  ///   (RLS `tours_public_read`).
  String get _tourCacheKey {
    final adminId = _auth.currentAdmin.value?.id;
    return _auth.isAdmin && adminId != null
        ? 'tours_admin_$adminId'
        : 'tours_public';
  }

  Map<String, String>? get _tourFilters {
    final adminId = _auth.currentAdmin.value?.id;
    return _auth.isAdmin && adminId != null ? {'owner_id': adminId} : null;
  }

  Future<void> _loadTours() async {
    final gen = ++_loadGeneration;
    isLoading.value = true;
    hasError.value = false;
    // Flipped the instant the roster merge lands. Read by every failure path
    // below to answer one question honestly: is what the agent is looking at
    // right now from the server, or off the disk?
    var reachedServer = false;
    try {
      // ── Phase 1: tour headers only ─────────────────────────────────
      // On 2G the roster+layout payload dwarfs the tour list. Paint titles
      // as soon as headers arrive so Home is never a blank spinner for the
      // full relation round-trip.
      List<Map<String, dynamic>> tourRows;
      try {
        tourRows = await _withTourReadRetry(
          () => _sync.fetchTourRows(
            filters: _tourFilters,
            orderBy: 'created_at',
          ),
        );
      } catch (e) {
        if (gen != _loadGeneration) return;
        if (tours.isEmpty) {
          hasError.value = true;
          errorMessage.value = SyncService.describeReadError(e);
        } else {
          // Content on screen + a fetch that did not land = the agent is
          // reading saved data. Say so persistently, not just in a toast that
          // is gone in three seconds.
          isShowingCachedData.value = true;
          AppSnackBar.warning(tr('errors.refresh_showing_cached'));
        }
        isLoading.value = false;
        return;
      }
      if (gen != _loadGeneration) return;

      final pendingIds = await _sync.pendingEntityIdsForTable('tours');
      if (gen != _loadGeneration) return;

      final headerTours = tourRows.map(Tour.fromMap).toList();
      final serverIds = headerTours.map((t) => t.id).toSet();
      final preserved = tours
          .where((t) => !serverIds.contains(t.id) && pendingIds.contains(t.id))
          .toList();

      // Keep already-loaded rosters for tours that are still on the server so a
      // refresh doesn't blank the dashboard while Phase 2 runs.
      final priorById = {for (final t in tours) t.id: t};
      final mergedHeaders = [
        for (final t in headerTours)
          if (priorById[t.id] case final prior?)
            t.copyWith(
              passengers: prior.passengers,
              buses: prior.buses,
              groups: prior.groups,
            )
          else
            t,
        ...preserved,
      ];
      tours.assignAll(mergedHeaders);
      // Headers are enough to leave the error/empty state — roster follows.
      isLoading.value = false;

      // ── Phase 2: passengers + buses (NO layout jsonb) ──────────────
      final scope = coldStartHydrationScope(tourRows);
      final rel = await _sync.fetchRelationsForTours(scope);
      if (gen != _loadGeneration) return;

      // ignore: invalid_use_of_protected_member
      final raw = tours.value;
      for (final tourId in scope) {
        final idx = raw.indexWhere((t) => t.id == tourId);
        if (idx < 0) continue;
        final passengers = rel.passengers
            .where((m) => m['tour_id'] == tourId && m['cancelled_at'] == null)
            .map(Passenger.fromMap)
            .toList();
        final buses = rel.buses
            .where((m) => m['tour_id'] == tourId)
            .map(Bus.fromMap)
            .toList();
        final groups = rel.groups
            .where((m) => m['tour_id'] == tourId)
            .map(PassengerGroup.fromMap)
            .toList();
        // New bus rows from the server replace prior ones; clear layout-fetched
        // marks for buses that disappeared so ids don't leak forever.
        for (final b in raw[idx].buses) {
          if (!buses.any((n) => n.id == b.id)) {
            _layoutFetchedBusIds.remove(b.id);
            _layoutKnownNullBusIds.remove(b.id);
          }
        }
        // Preserve layouts we already paid for — read from the LIVE list, not
        // from `priorById`.
        //
        // `priorById` is snapshotted before this method's `await` on
        // `fetchRelationsForTours`, and `_prefetchLayoutsForHydratedTours` is
        // writing grids into `tours` the whole time that request is in flight.
        // Re-attaching from the snapshot therefore threw away any layout that
        // landed during the window and put back the null the snapshot held —
        // while `_layoutFetchedBusIds` kept the id, so `need` stayed empty and
        // it was never re-fetched. That is the intermittent "no seat plan" on a
        // bus that had rendered a moment earlier: not a fetch failure, a race
        // between a background prefetch and a foreground refresh.
        final liveById = {for (final b in raw[idx].buses) b.id: b};
        final withLayouts = [
          for (final b in buses)
            if (liveById[b.id]?.layout case final live?)
              b.copyWith(layout: live)
            else
              b,
        ];
        // The flag and the data must agree, always.
        //
        // `layoutsLoadedFor` — which decides "skeleton" vs "no seat plan" on
        // every chart surface — answers from `_layoutFetchedBusIds` alone, so a
        // latched id next to a null layout renders the hard, wrong conclusion
        // and never recovers. Any bus that comes out of this merge WITHOUT a
        // grid gets its mark dropped, so the worst case is one more cheap
        // id+jsonb request rather than a chart that is stuck until app restart.
        //
        // Except when the SERVER is the one that said null: that bus has no
        // grid to fetch (it was wiped — `recoverBusLayoutFor` repairs it), and
        // dropping its mark would send the chart back to a skeleton that can
        // never resolve, and re-ask on every single refresh forever.
        for (final b in withLayouts) {
          if (b.layout == null && !_layoutKnownNullBusIds.contains(b.id)) {
            _layoutFetchedBusIds.remove(b.id);
          }
        }
        raw[idx] = raw[idx].copyWith(
          passengers: passengers,
          buses: withLayouts,
          groups: groups,
        );
      }
      _scheduleNotify();

      _hydratedTourIds
        ..clear()
        ..addAll(scope);

      // The roster IS the server's answer now. Everything after this point
      // (archive sweep, remembered priority, layout prefetch) is follow-up
      // work — if one of those throws, the graph on screen is still live and
      // must not be re-labelled as saved data.
      reachedServer = true;
      _markFresh();
      _scheduleDiskCacheSave();

      // GO first: a tour whose whole trip lapsed unattended still releases its
      // outbound-only seats (and snapshots the GO chart) before it is archived.
      await _autoCompleteOutboundLegs();
      await _archiveExpiredTours();
      await _applyRememberedPriority();

      // ── Phase 3: layout jsonb in the background ────────────────────
      // Dashboard capacity / charts need grids, but they must not gate first
      // paint. Prefetch for hydrated (running) tours only.
      // ignore: unawaited_futures
      _prefetchLayoutsForHydratedTours();
    } catch (e) {
      if (gen != _loadGeneration) return;
      if (tours.isEmpty) {
        hasError.value = true;
        errorMessage.value = SyncService.describeReadError(e);
      } else {
        if (!reachedServer) isShowingCachedData.value = true;
        AppSnackBar.warning(tr('errors.refresh_showing_cached'));
      }
    }
    if (gen == _loadGeneration) isLoading.value = false;
  }

  /// Transient-safe wrapper around a single tour-header read (mirrors
  /// smartFetch retry policy without the relations payload). Never retries
  /// auth / missing-table / permanent PostgREST errors — those only burn the
  /// 2G radio and delay the error UI.
  Future<List<Map<String, dynamic>>> _withTourReadRetry(
    Future<List<Map<String, dynamic>>> Function() action,
  ) async {
    Object? last;
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        return await action();
      } catch (e) {
        last = e;
        if (attempt == 2 ||
            !retry.isRetryable(e, retryOnTimeout: true)) {
          break;
        }
        await Future<void>.delayed(
          Duration(milliseconds: (400 * math.pow(3, attempt)).round()),
        );
      }
    }
    Error.throwWithStackTrace(last!, StackTrace.current);
  }

  Future<void> _prefetchLayoutsForHydratedTours() async {
    for (final id in _hydratedTourIds.toList()) {
      try {
        await ensureBusLayoutsForTour(id);
      } catch (e, st) {
        dev.log('layout prefetch failed for $id: $e\n$st', name: 'TourController');
      }
    }
  }

  /// Auto-ARCHIVES tours whose trip has been over for more than a day so the
  /// active list stays clean — without ever destroying data. The cutoff is
  /// `(returnDate ?? departureDate) + 1 day` (compared at local midnight): a
  /// tour returning on the 5th drops out of "active" from the 6th onward but
  /// stays fully viewable in the archive (chart, money, passengers intact).
  ///
  /// Only the signed-in admin owner archives; a customer/anonymous viewer
  /// never writes (RLS would reject it anyway). Each archive reuses
  /// [completeTour], so a failure surfaces its own snackbar and the loop keeps
  /// sweeping the rest rather than aborting.
  Future<void> _archiveExpiredTours() async {
    if (!_auth.isAdmin) return;
    final now = DateTime.now();
    // ARCHIVE (soft), never hard-delete. Auto-deleting a tour on load would
    // permanently destroy its passengers, seat assignments and money records
    // with no undo on the first app open after the return date — a clock skew
    // or a mistyped date would silently wipe real financial data. Instead we
    // flip expired-but-still-active tours to `completed` so they drop out of
    // the active list while every record stays viewable in the archive.
    // The cutoff is the shared calendar rule (utils/trip_auto_complete.dart),
    // which also ignores a return date typed BEFORE the departure — taken
    // literally, that archived a tour (and closed its live-location window)
    // before the bus had even left.
    final expiredIds = tours
        .where((t) {
          if (t.status == TourStatus.completed) return false;
          return isTripAutoComplete(
            now: now,
            departure: t.departureDate,
            returnDate: t.returnDate,
          );
        })
        .map((t) => t.id)
        .toList();
    for (final id in expiredIds) {
      try {
        await completeTour(id);
      } catch (_) {
        // completeTour surfaces its own error; keep sweeping the rest.
      }
    }
  }

  /// Auto-completes the OUTBOUND leg by the calendar: once the return day has
  /// started (the day after departure for a one-way tour — see
  /// `goLegAutoCompleteAt`), every still-active outbound-only rider is done,
  /// so [completeOutboundLeg] frees their seats exactly as the handler's
  /// "We've arrived" would have. Handlers stamp "departed" and then forget the
  /// rest, so without this those seats stayed held for the return chart.
  ///
  /// Idempotent: [completeOutboundLeg] marks each rider `journeyDone`, so a
  /// tour drops out of this sweep the moment it has run once. Admin-only and
  /// best-effort; a completed tour is never touched; a tour whose roster has
  /// not been hydrated (no passengers in memory) is skipped rather than judged
  /// on missing data.
  bool _autoCompletingOutbound = false;

  Future<void> _autoCompleteOutboundLegs() async {
    if (_autoCompletingOutbound) return;
    if (!_auth.isAdmin) return;
    final now = DateTime.now();
    final due = tours
        .where((t) {
          if (t.status == TourStatus.completed) return false;
          if (!isGoLegAutoComplete(
            now: now,
            departure: t.departureDate,
            returnDate: t.returnDate,
          )) {
            return false;
          }
          // Only a rider still HOLDING a GO seat makes the sweep worth a write.
          return t.passengers.any(
            (p) =>
                p.tripType == TripType.outboundOnly &&
                !p.journeyDone &&
                p.assignedSeats.isNotEmpty,
          );
        })
        .map((t) => t.id)
        .toList();
    if (due.isEmpty) return;
    _autoCompletingOutbound = true;
    try {
      for (final id in due) {
        try {
          await completeOutboundLeg(id);
        } catch (e, st) {
          // completeOutboundLeg surfaces its own failure; keep sweeping.
          dev.log('auto GO-leg completion failed for $id: $e\n$st',
              name: 'TourController');
        }
      }
    } finally {
      _autoCompletingOutbound = false;
    }
  }

  /// Auto-restores priority for returning customers: if a passenger has no
  /// explicit decision yet (status `none`/`requested`) but their phone is
  /// remembered as `approved` from a past tour, approve them. Idempotent —
  /// once approved the row is skipped on later loads — and never overrides an
  /// explicit `approved`/`declined` the agent set on THIS tour. Admin-only;
  /// no-op until [CustomerMemoryController] has loaded.
  /// Guards against re-entry: [setPassengerPriority] calls `refreshTours()` on
  /// a write failure, which would loop back into this sweep.
  bool _applyingRememberedPriority = false;

  Future<void> _applyRememberedPriority() async {
    if (_applyingRememberedPriority) return;
    if (!_auth.isAdmin) return;
    if (!Get.isRegistered<CustomerMemoryController>()) return;
    final memory = Get.find<CustomerMemoryController>();
    _applyingRememberedPriority = true;
    try {
      for (final tour in tours.toList()) {
        if (tour.status == TourStatus.completed) continue;
        for (final p in tour.passengers) {
          if (p.priorityStatus == PriorityStatus.approved ||
              p.priorityStatus == PriorityStatus.declined) {
            continue;
          }
          if (memory.forPhone(p.phone)?.priorityStatus ==
              PriorityStatus.approved) {
            try {
              await setPassengerPriority(tour.id, p.id, true);
            } catch (_) {
              // Best-effort; a failed write retries on the next load.
            }
          }
        }
      }
    } finally {
      _applyingRememberedPriority = false;
    }
  }

  /// Force a fresh fetch from Supabase. Used by pull-to-refresh and
  /// by callers that just wrote data and want it reflected in the UI.
  /// Bypasses the 2-minute smartFetch cache by invalidating it first.
  @override
  Future<void> refreshTours() async {
    await _sync.invalidateCache(_tourCacheKey);
    await _loadTours();
  }
}
