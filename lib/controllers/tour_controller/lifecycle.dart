part of '../tour_controller.dart';

/// Tour CRUD, status transitions, leg/tour completion + seat-history
/// snapshots, booking settings and the list queries.
mixin _TourLifecycle on _TourHydration {
  /// Frozen per-leg seat charts, keyed by tourId. Populated lazily by
  /// [loadSeatSnapshots] (when a past-tour seat view opens) and written through
  /// by [_captureSeatSnapshot] so a freshly-captured leg is visible without a
  /// round-trip. Never rides along with the tours-list fetch.
  final RxMap<String, List<TourSeatSnapshot>> _seatSnapshots =
      <String, List<TourSeatSnapshot>>{}.obs;

  // Tour CRUD
  Future<Tour> createTour({
    required String title,
    required String fromCity,
    required String toCity,
    required DateTime departureDate,
    String? departureTime,
    DateTime? returnDate,
    String? returnTime,
    // Tour-level price is no longer collected at creation — pricing is set
    // per-bus during bus creation. Kept (defaulting to 0) so the model field
    // and edit-tour flow stay intact; add_bus only prefills when it's > 0.
    double pricePerSeat = 0,
    String? description,
    String? broadcastMessage,
    String? broadcastImageUrl,
  }) async {
    // RLS on `tours` requires owner_id = auth.uid(). Refuse to queue an
    // insert without an admin session — otherwise we'd write a row with a
    // null owner_id that RLS rejects on every retry until the 5-retry cap.
    final adminId = _auth.currentAdmin.value?.id;
    if (adminId == null) {
      AppSnackBar.error(
        tr('errors.sign_in_to_create_tour'),
        title: tr('errors.sign_in_required'),
      );
      throw StateError('createTour requires an authenticated admin session');
    }

    final tour = Tour(
      title: title,
      fromCity: fromCity,
      toCity: toCity,
      departureDate: departureDate,
      departureTime: departureTime,
      returnDate: returnDate,
      returnTime: returnTime,
      pricePerSeat: pricePerSeat,
      description: description,
      broadcastMessage: broadcastMessage,
      broadcastImageUrl: broadcastImageUrl,
      createdBy: _auth.userPhone.value,
    );

    final tourData = {...tour.toMap(), 'owner_id': adminId};
    await _write(
      // Optimistic add so the UI feels instant; on failure _write snaps back
      // to server truth, which drops the phantom (it was never persisted).
      optimistic: () {
        tours.add(tour);
        // A tour created on this device has no roster to fetch: "no buses"
        // is already the truth, not a hydrate still in flight.
        _hydratedTourIds.add(tour.id);
        tours.refresh();
      },
      persist: () =>
          _sync.smartInsert(table: 'tours', entityId: tour.id, data: tourData),
      failure: tr('errors.create_tour'),
    );
    return tour;
  }

  Future<void> editTour({
    required String tourId,
    required String title,
    required String fromCity,
    required String toCity,
    required DateTime departureDate,
    String? departureTime,
    DateTime? returnDate,
    String? returnTime,
    required double pricePerSeat,
    String? description,
  }) async {
    await _updateTour(
      tourId,
      // copyWith, never a full-constructor rebuild: a hand-rolled Tour(...)
      // silently nulled every field it forgot (owner, bookingMode, advance,
      // UPI payee, broadcast, groups…) — locally AND in the persisted row.
      (t) => t.copyWith(
        title: title,
        fromCity: fromCity,
        toCity: toCity,
        departureDate: departureDate,
        departureTime: departureTime,
        clearDepartureTime: departureTime == null,
        returnDate: returnDate,
        clearReturnDate: returnDate == null,
        returnTime: returnTime,
        clearReturnTime: returnTime == null,
        pricePerSeat: pricePerSeat,
        description: description,
        clearDescription: description == null,
      ),
    );
  }

  Future<void> deleteTour(String id) async {
    // Snapshot returning-customer memory (priority + travel companions) BEFORE
    // the tour — and its cascade-deleted passenger rows — are gone. Best-effort:
    // never block a delete on the memory write.
    final tour = getTour(id);
    if (tour != null && Get.isRegistered<CustomerMemoryController>()) {
      try {
        await Get.find<CustomerMemoryController>().captureFromTour(tour);
      } catch (_) {}
    }

    await _write(
      optimistic: () => tours.removeWhere((t) => t.id == id),
      persist: () => _sync.smartDelete(table: 'tours', entityId: id),
      failure: tr('errors.delete_tour'),
    );
  }

  // Status Transitions
  Future<void> updateStatus(String tourId, TourStatus status) async {
    await _updateTour(tourId, (t) => t.copyWith(status: status));
  }

  Future<void> startCollecting(String tourId) =>
      updateStatus(tourId, TourStatus.collecting);

  Future<void> markBusBooked(String tourId) =>
      updateStatus(tourId, TourStatus.busBooked);

  Future<void> startAssigning(String tourId) =>
      updateStatus(tourId, TourStatus.assigning);

  Future<void> lockTour(String tourId) =>
      updateStatus(tourId, TourStatus.locked);

  /// Mark a tour completed (also the auto-archive path for expired tours).
  ///
  /// Before flipping status we freeze the seat history so a past tour keeps its
  /// chart. Both captures are best-effort (their own try/catch swallows any
  /// failure), so the status transition always proceeds:
  /// - outbound, `overwriteIfExists: false` — covers tours that expire without
  ///   a GO-leg completion (seats still intact) and never clobbers the
  ///   authoritative pre-wipe capture from [completeOutboundLeg].
  /// - return, `overwriteIfExists: true` — round-trip + return-only riders
  ///   (`.ret`); skipped automatically when empty (one-way tours).
  Future<void> completeTour(String tourId) async {
    // The snapshot is built from the IN-MEMORY roster. A tour whose roster was
    // never fetched (served from a header-only cache, or completed from a
    // surface that did not hydrate it) would freeze an EMPTY chart — and the
    // capture is skipped silently when nothing is seated. Load it first.
    // Best-effort: a failed hydrate must not block the status change, and the
    // seats themselves are not freed by completion, so the live-chart fallback
    // in the history view still has them.
    try {
      await ensureTourHydrated(tourId);
    } catch (e, st) {
      dev.log('completeTour hydrate failed for $tourId: $e\n$st',
          name: 'TourController');
    }
    await _captureSeatSnapshot(tourId, SnapshotLeg.outbound,
        overwriteIfExists: false);
    await _captureSeatSnapshot(tourId, SnapshotLeg.return_,
        overwriteIfExists: true);
    await updateStatus(tourId, TourStatus.completed);
  }

  /// Complete the OUTBOUND (GO) leg of a tour: every GO-only (outboundOnly)
  /// passenger has finished their only leg, so free their seats (the return
  /// chart then shows them empty) and mark them [Passenger.journeyDone] — the
  /// record is KEPT, they just drop off the active roster. Round-trip and
  /// return-only passengers are untouched. Returns how many were cleared.
  Future<int> completeOutboundLeg(String tourId) async {
    final tour = getTour(tourId);
    if (tour == null) return 0;

    // Freeze the authoritative GO chart BEFORE the optimistic clear below wipes
    // outbound-only riders' seats. This must run even when there are no
    // outbound-only riders to clear (the loop below adds nothing): completing
    // the leg should always preserve the GO chart. Best-effort & idempotent on
    // the (tour_id, leg) key — overwrite so a re-run reflects the latest state.
    await _captureSeatSnapshot(tourId, SnapshotLeg.outbound,
        overwriteIfExists: true);

    final changed = await _writePassengerEdits(
      tourId,
      [
        for (final p in tour.passengers)
          if (p.tripType == TripType.outboundOnly && !p.journeyDone)
            (
              id: p.id,
              update: (cur) =>
                  cur.copyWith(assignedSeats: const [], journeyDone: true),
            ),
      ],
      failure: tr('errors.save_passenger'),
    );
    return changed.length;
  }

  // ── Seat-history snapshots ────────────────────────────────

  /// Freeze the LIVE per-leg seat chart for [tourId] and upsert it into
  /// `tour_seat_snapshots`. This is the one piece of seat data the live editor
  /// destroys (GO seats are recycled for the return leg), so we capture it at
  /// the leg/tour completion edges and keep it for the past-tour history view.
  ///
  /// The occupant per seat is resolved with [seatOccupantsForBus]: for
  /// [SnapshotLeg.outbound] we take each seat's `.go` rider, for
  /// [SnapshotLeg.return_] its `.ret` rider. Buses with no captured seats are
  /// skipped, and a snapshot with zero seats across all buses is NOT written
  /// (e.g. a one-way tour has no return occupants).
  ///
  /// The natural key is `(tour_id, leg)`, so we use a deterministic entity id
  /// `'<tourId>_<leg.wire>'` to make the upsert idempotent — an existing row is
  /// updated in place, never duplicated. When [overwriteIfExists] is false an
  /// already-present snapshot is left untouched (so a later, lossy re-capture
  /// can't clobber the authoritative pre-wipe chart).
  ///
  /// Best-effort by contract: the whole body is guarded; any failure (including
  /// a missing migration) is swallowed and logged, NEVER rethrown — capturing
  /// history must not break a completion.
  Future<void> _captureSeatSnapshot(String tourId, SnapshotLeg leg,
      {required bool overwriteIfExists}) async {
    try {
      final tour = getTour(tourId);
      if (tour == null) return;

      // Is there already a stored snapshot for this (tourId, leg)? Drives both
      // the don't-clobber guard and the insert-vs-update choice below.
      final existing = await loadSeatSnapshots(tourId);
      final hasExisting = existing.any((s) => s.leg == leg);
      if (hasExisting && !overwriteIfExists) return;

      // Build the per-leg chart from the LIVE tour; null means nothing occupied
      // for this leg (e.g. a one-way tour has no return riders) — skip storing.
      final snapshot = buildSeatSnapshot(
        tourId: tourId,
        leg: leg,
        buses: tour.buses,
        passengers: tour.passengers,
        capturedAt: DateTime.now(),
      );
      if (snapshot == null) return;

      // Deterministic id over the natural (tour_id, leg) key keeps the upsert
      // idempotent; include it in the insert payload so the row id matches.
      final entityId = '${tourId}_${leg.wire}';
      final data = snapshot.toMap();
      if (hasExisting) {
        await _sync.smartUpdate(
          table: 'tour_seat_snapshots',
          entityId: entityId,
          data: data,
        );
      } else {
        await _sync.smartInsert(
          table: 'tour_seat_snapshots',
          entityId: entityId,
          data: {'id': entityId, ...data},
        );
      }

      // Write through to the in-memory cache so a freshly-opened history view
      // sees this leg without waiting on a refetch.
      final cached = List<TourSeatSnapshot>.from(_seatSnapshots[tourId] ?? const [])
        ..removeWhere((s) => s.leg == leg)
        ..add(snapshot);
      _seatSnapshots[tourId] = cached;
    } catch (e, st) {
      // Best-effort: history capture must never break a completion.
      dev.log('seat snapshot capture failed: $e\n$st', name: 'TourController');
    }
  }

  /// Lazy-load the frozen seat charts for [tourId] (used by the past-tour seat
  /// history view). Returns the in-memory cache when present, otherwise fetches
  /// from `tour_seat_snapshots` and caches the result.
  ///
  /// [SyncService.smartFetch] returns `[]` on any error or a missing table, so
  /// an un-applied migration yields an empty list rather than a crash — the
  /// history view degrades to its live-chart fallback.
  Future<List<TourSeatSnapshot>> loadSeatSnapshots(String tourId) async =>
      (await loadSeatSnapshotsResult(tourId)).snapshots;

  /// [loadSeatSnapshots] plus whether the read FAILED.
  ///
  /// Only a successful read is cached. A failed one (2G timeout, offline) used
  /// to be cached as `[]` for the life of the controller, so every later open of
  /// the history screen answered "no snapshot" without ever asking again and
  /// fell back to the LIVE chart — which, for a past tour whose GO seats were
  /// recycled for the return leg, is the wrong chart.
  Future<SeatSnapshotLoad> loadSeatSnapshotsResult(String tourId) async {
    final cached = _seatSnapshots[tourId];
    if (cached != null) return (snapshots: cached, failed: false);

    final result = await _sync.smartFetch(
      table: 'tour_seat_snapshots',
      cacheKey: 'seat_snapshots_$tourId',
      filters: {'tour_id': tourId},
      orderBy: 'captured_at',
      maxAge: 120000,
    );
    final snapshots = result.rows.map(TourSeatSnapshot.fromMap).toList();
    if (result.failed) return (snapshots: snapshots, failed: true);
    _seatSnapshots[tourId] = snapshots;
    return (snapshots: snapshots, failed: false);
  }

  /// GO-only passengers still active (not yet cleared by [completeOutboundLeg]).
  /// Drives whether the "Complete GO leg" action is offered.
  int outboundOnlyActiveCount(String tourId) {
    final tour = getTour(tourId);
    if (tour == null) return 0;
    return tour.passengers
        .where((p) => p.tripType == TripType.outboundOnly && !p.journeyDone)
        .length;
  }

  /// Write ONLY the booking-mode / collection columns (migrations 048–050).
  ///
  /// Deliberately a narrow, hand-rolled update rather than going through
  /// [_updateTour]: those columns are absent from [Tour.toMap] on purpose,
  /// because PostgREST rejects the WHOLE payload when it carries a column the
  /// live schema doesn't have — shipping them in the ordinary tour write would
  /// break every tour save on a server where 048–050 aren't applied yet. Sent
  /// alone, a missing column fails only this call, loudly, with nothing else
  /// affected.
  Future<void> updateBookingSettings(
    String tourId, {
    BookingMode? bookingMode,
    int? advancePerBerthPaise,
    bool clearAdvance = false,
    String? collectVpa,
    String? collectPayeeName,
  }) async {
    final payload = <String, dynamic>{};
    if (bookingMode != null) {
      payload['booking_mode'] = bookingMode.storageKey;
    }
    if (clearAdvance) {
      payload['advance_per_berth_paise'] = null;
    } else if (advancePerBerthPaise != null) {
      payload['advance_per_berth_paise'] = advancePerBerthPaise;
    }
    if (collectVpa != null) {
      payload['collect_vpa'] =
          collectVpa.trim().isEmpty ? null : collectVpa.trim();
    }
    if (collectPayeeName != null) {
      payload['collect_payee_name'] =
          collectPayeeName.trim().isEmpty ? null : collectPayeeName.trim();
    }
    if (payload.isEmpty) return;

    _updateTourLocal(
      tourId,
      (t) => t.copyWith(
        bookingMode: bookingMode,
        advancePerBerthPaise: clearAdvance ? null : advancePerBerthPaise,
        collectVpa: collectVpa,
        collectPayeeName: collectPayeeName,
      ),
    );
    try {
      // Routed through the sync layer so it inherits the same retry/backoff
      // behaviour as every other write.
      await _sync.smartUpdate(
        table: 'tours',
        entityId: tourId,
        data: payload,
      );
    } catch (e) {
      dev.log('updateBookingSettings failed — $e', name: 'TourController');
      AppSnackBar.error(tr('booking_settings.err_save'));
      rethrow;
    }
  }

  // Queries
  List<Tour> toursByStatus(TourStatus status) =>
      tours.where((t) => t.status == status).toList();

  List<Tour> get activeTours =>
      tours.where((t) => t.status != TourStatus.completed).toList();

  List<Tour> get completedTours =>
      tours.where((t) => t.status == TourStatus.completed).toList();

  /// Live count of NEW (un-actioned) booking requests across all active tours.
  ///
  /// Mirrors exactly the "New" filter pill in RequestsScreen: a passenger is
  /// New when their journey isn't done and they are neither waitlisted,
  /// confirmed, nor fully assigned. Derived from the existing `tours`
  /// observable (via [activeTours]) so reading it inside an Obx is reactive;
  /// adds no persisted state. Used to badge the Requests dock-nav tab.
  int get pendingRequestCount {
    var count = 0;
    for (final tour in activeTours) {
      for (final p in tour.passengers) {
        if (p.journeyDone) continue;
        if (!p.isWaitlisted && !p.isConfirmed && !p.isFullyAssigned) {
          count++;
        }
      }
    }
    return count;
  }
}
