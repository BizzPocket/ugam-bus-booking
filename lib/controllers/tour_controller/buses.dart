part of '../tour_controller.dart';

/// Bus rows, tour/bus handlers, seat-cell flags and layout recovery.
mixin _TourBuses on _TourSeatSwaps {
  // Handler
  Future<void> setHandler(String tourId, String passengerId) async {
    // Remember who held the flag before, so we persist only the rows that
    // actually flip — not every passenger.
    final previousHandlerId = getTour(tourId)?.handlerId;
    await _write(
      optimistic: () => _updateTourLocal(tourId, (t) {
        final updatedPassengers = t.passengers.map((p) {
          if (p.isHandler) return p.copyWith(isHandler: false);
          if (p.id == passengerId) return p.copyWith(isHandler: true);
          return p;
        }).toList();
        return t.copyWith(
          handlerId: passengerId,
          passengers: updatedPassengers,
        );
      }),
      persist: () async {
        final tour = getTour(tourId);
        if (tour == null) return;
        // The tour row's handlerId is authoritative; write it once.
        await _sync.smartUpdate(
          table: 'tours',
          entityId: tourId,
          data: tour.toMap(),
        );
        // Only the new handler and the one it replaced changed isHandler — a
        // 60-passenger tour no longer means 60 sequential writes.
        final changedIds = <String>{passengerId, ?previousHandlerId};
        for (final id in changedIds) {
          final p = tour.passengers.firstWhereOrNull((x) => x.id == id);
          if (p == null) continue;
          await _sync.smartUpdate(
            table: 'passengers',
            entityId: p.id,
            data: p.toMap(),
          );
        }
      },
      failure: tr('errors.set_handler'),
    );
  }

  Future<void> removeHandler(String tourId) => _write(
    optimistic: () => _updateTourLocal(tourId, (t) {
      final updatedPassengers = t.passengers
          .map((p) => p.isHandler ? p.copyWith(isHandler: false) : p)
          .toList();
      return t.copyWith(handlerId: null, passengers: updatedPassengers);
    }),
    persist: () async {
      final tour = getTour(tourId);
      if (tour == null) return;
      await _sync.smartUpdate(
        table: 'tours',
        entityId: tourId,
        data: tour.toMap(),
      );
    },
    failure: tr('errors.remove_handler'),
  );

  // Per-bus handler (F3)
  //
  // The handler is now PER BUS (a per-bus handler later sees ONLY their own
  // bus). The bus row owns the pointer via `handler_passenger_id`; the
  // passenger's `is_handler` flag is kept in sync (true while they handle ANY
  // bus); and the legacy tour-wide `tours.handler_id` pointer is maintained so
  // older "tour has a handler" reads keep working.

  /// Assign [passengerId] as the handler of [busId] on [tourId].
  ///
  /// Sets `bus.handlerPassengerId = passengerId` and `passenger.isHandler =
  /// true`. If a DIFFERENT passenger previously handled this bus and handles no
  /// OTHER bus, their `isHandler` is cleared. Also points the legacy
  /// `tours.handler_id` at [passengerId]. Persists only the rows that change.
  Future<void> setBusHandler(
    String tourId,
    String busId,
    String passengerId,
  ) async {
    final tour = getTour(tourId);
    if (tour == null) return;
    final bus = tour.buses.firstWhereOrNull((b) => b.id == busId);
    if (bus == null) return;

    // The passenger this bus pointed at before (if any), so we can clear their
    // flag when they no longer handle any bus.
    final previousHandlerId = bus.handlerPassengerId;
    // Whether the previous handler still handles some OTHER bus after this
    // change — if so, keep their is_handler flag.
    final prevStillHandlesOther = previousHandlerId != null &&
        previousHandlerId != passengerId &&
        tour.buses
            .any((b) => b.id != busId && b.handlerPassengerId == previousHandlerId);

    await _write(
      optimistic: () => _updateTourLocal(tourId, (t) {
        final nextBuses = t.buses
            .map((b) => b.id == busId
                ? b.copyWith(handlerPassengerId: passengerId)
                : b)
            .toList();
        final nextPassengers = t.passengers.map((p) {
          if (p.id == passengerId && !p.isHandler) {
            return p.copyWith(isHandler: true);
          }
          if (p.id == previousHandlerId &&
              previousHandlerId != passengerId &&
              !prevStillHandlesOther &&
              p.isHandler) {
            return p.copyWith(isHandler: false);
          }
          return p;
        }).toList();
        return t.copyWith(
          handlerId: passengerId,
          buses: nextBuses,
          passengers: nextPassengers,
        );
      }),
      persist: () async {
        final t = getTour(tourId);
        if (t == null) return;
        // The bus row owns the per-bus pointer. Patch ONLY that column: a whole
        // -row write here used to ship `layout: null` for any bus whose grid had
        // not been fetched yet (cold start omits the jsonb), erasing the seat
        // chart as a side effect of naming a handler.
        final bus = t.buses.firstWhereOrNull((b) => b.id == busId);
        if (bus != null) {
          await _sync.updatePatch(
            table: 'buses',
            entityId: busId,
            fields: {'handler_passenger_id': bus.handlerPassengerId},
          );
        }
        // The tour row carries the legacy handler_id pointer.
        await _sync.smartUpdate(
          table: 'tours',
          entityId: tourId,
          data: t.toMap(),
        );
        // Only the new handler and the one it replaced changed is_handler.
        final changedIds = <String>{passengerId, ?previousHandlerId};
        for (final id in changedIds) {
          final p = t.passengers.firstWhereOrNull((x) => x.id == id);
          if (p == null) continue;
          await _sync.smartUpdate(
            table: 'passengers',
            entityId: p.id,
            data: p.toMap(),
          );
        }
      },
      failure: tr('errors.set_handler'),
    );
  }

  /// Remove the handler from [busId] on [tourId].
  ///
  /// Clears `bus.handlerPassengerId`. The removed passenger keeps `isHandler`
  /// only if they still handle some OTHER bus. The legacy `tours.handler_id` is
  /// recomputed to another bus's handler (deterministically, by bus id) or null.
  Future<void> removeBusHandler(String tourId, String busId) async {
    final tour = getTour(tourId);
    if (tour == null) return;
    final bus = tour.buses.firstWhereOrNull((b) => b.id == busId);
    if (bus == null) return;
    final removedHandlerId = bus.handlerPassengerId;
    if (removedHandlerId == null) return; // nothing to clear.

    // Does the removed handler still handle any OTHER bus?
    final stillHandlesOther = tour.buses.any(
      (b) => b.id != busId && b.handlerPassengerId == removedHandlerId,
    );

    // Recompute the legacy tour-wide pointer: another bus's handler (lowest bus
    // id for determinism), or null when no bus has a handler anymore.
    final remainingHandlerBuses = tour.buses
        .where((b) => b.id != busId && b.handlerPassengerId != null)
        .toList()
      ..sort((a, b) => a.id.compareTo(b.id));
    final nextTourHandlerId =
        remainingHandlerBuses.firstOrNull?.handlerPassengerId;

    await _write(
      optimistic: () => _updateTourLocal(tourId, (t) {
        final nextBuses = t.buses
            .map((b) => b.id == busId ? _busWithHandler(b, null) : b)
            .toList();
        final nextPassengers = t.passengers.map((p) {
          if (p.id == removedHandlerId && !stillHandlesOther && p.isHandler) {
            return p.copyWith(isHandler: false);
          }
          return p;
        }).toList();
        return t.copyWith(
          handlerId: nextTourHandlerId,
          buses: nextBuses,
          passengers: nextPassengers,
        );
      }),
      persist: () async {
        final t = getTour(tourId);
        if (t == null) return;
        // Clearing the pointer is the same one-column write as setting it.
        final bus = t.buses.firstWhereOrNull((b) => b.id == busId);
        if (bus != null) {
          await _sync.updatePatch(
            table: 'buses',
            entityId: busId,
            fields: {'handler_passenger_id': bus.handlerPassengerId},
          );
        }
        await _sync.smartUpdate(
          table: 'tours',
          entityId: tourId,
          data: t.toMap(),
        );
        if (!stillHandlesOther) {
          final p =
              t.passengers.firstWhereOrNull((x) => x.id == removedHandlerId);
          if (p != null) {
            await _sync.smartUpdate(
              table: 'passengers',
              entityId: p.id,
              data: p.toMap(),
            );
          }
        }
      },
      failure: tr('errors.remove_handler'),
    );
  }

  /// Rebuild [Bus] with an explicit (possibly null) handler passenger id.
  /// Needed because [Bus.copyWith] uses `??`, so it can't clear
  /// `handlerPassengerId` back to null when a bus's handler is removed. Every
  /// other field is preserved verbatim.
  Bus _busWithHandler(Bus b, String? handlerPassengerId) {
    return Bus(
      id: b.id,
      ownerId: b.ownerId,
      tourId: b.tourId,
      handlerPassengerId: handlerPassengerId,
      name: b.name,
      busNumber: b.busNumber,
      driverName: b.driverName,
      driverPhone: b.driverPhone,
      ownerName: b.ownerName,
      ownerPhone: b.ownerPhone,
      isAC: b.isAC,
      busType: b.busType,
      totalSeatsLegacy: b.totalSeatsLegacy,
      pricePerSeat: b.pricePerSeat,
      busPrice: b.busPrice,
      boardingPoint: b.boardingPoint,
      departureTime: b.departureTime,
      singleSofaPrice: b.singleSofaPrice,
      doubleSofaPrice: b.doubleSofaPrice,
      seaterPrice: b.seaterPrice,
      rearRows: b.rearRows,
      rearPrice: b.rearPrice,
      priceBands: b.priceBands,
      notes: b.notes,
      layout: b.layout,
      createdAt: b.createdAt,
      updatedAt: DateTime.now(),
    );
  }

  // Bus Management

  /// True (after telling the operator why) when [tourId]'s status no longer
  /// allows the seat layout to change. An unknown tour is never blocked.
  bool _layoutEditBlocked(String tourId) {
    final tourGate = getTour(tourId);
    if (tourGate != null && !tourGate.status.allowsLayoutEdit) {
      AppSnackBar.info(tr('manage_buses.layout_locked_body'),
          title: tr('manage_buses.layout_locked_title'));
      return true;
    }
    return false;
  }

  Future<void> addBus(String tourId, Bus bus) async {
    if (_layoutEditBlocked(tourId)) return;
    final boundBus = bus.copyWith(tourId: tourId);
    final busData = {
      ...boundBus.toMap(),
      'owner_id': _auth.currentAdmin.value?.id,
    };
    await _write(
      optimistic: () => _updateTourLocal(
        tourId,
        (t) => t.copyWith(buses: [...t.buses, boundBus]),
      ),
      persist: () => _sync.smartInsert(
        table: 'buses',
        entityId: boundBus.id,
        data: busData,
      ),
      failure: tr('errors.add_bus'),
    );
    final tour = getTour(tourId);
    if (tour != null && tour.status == TourStatus.collecting) {
      await updateStatus(tourId, TourStatus.busBooked);
    }
  }

  /// Persist edits to [bus].
  ///
  /// [layoutChanged] MUST be true only when the caller actually built a new seat
  /// layout in this operation. It is a caller declaration, never inferred from
  /// `bus.layout != null` — an unloaded layout and a real one are
  /// indistinguishable in memory, and guessing wrong erases the seat chart.
  /// When false the `layout` column is left out of the write entirely, so the
  /// grid on the server survives untouched.
  Future<void> updateBus(
    String tourId,
    Bus bus, {
    required bool layoutChanged,
  }) async {
    // The lock freezes the CHART, not the bus record.
    //
    // This gate used to fire on `!allowsLayoutEdit` alone, which meant a locked
    // tour refused the whole update — driver name, driver phone, boarding point,
    // departure time, prices and owner details included — under a toast that
    // said "layout locked" and therefore explained nothing. Those are exactly
    // the fields that change on departure day: the owner sends a different
    // driver, a number is wrong, a pickup moves. Refusing them is also at odds
    // with the rule the rest of the app follows, that the lock is the CUSTOMER
    // gate and the agent keeps managing a locked tour.
    //
    // [layoutChanged] is already the caller's declaration that it built a fresh
    // grid this save, so gate on that instead: a re-layout after lock still
    // stops (the notified chart must not silently change shape), and a plain
    // detail edit goes through.
    if (layoutChanged && _layoutEditBlocked(tourId)) return;
    await _write(
      optimistic: () => _updateTourLocal(
        tourId,
        (t) => t.copyWith(
          buses: t.buses.map((b) => b.id == bus.id ? bus : b).toList(),
        ),
      ),
      persist: () => _sync.updatePatch(
        table: 'buses',
        entityId: bus.id,
        fields: bus.toPatch(includeLayout: layoutChanged),
      ),
      failure: tr('errors.update_bus'),
    );
  }

  Future<void> removeBus(String tourId, String busId) async {
    if (_layoutEditBlocked(tourId)) return;
    await _write(
      optimistic: () => _updateTourLocal(
        tourId,
        (t) => t.copyWith(
          buses: t.buses.where((b) => b.id != busId).toList(),
          busId: t.busId == busId ? null : t.busId,
        ),
      ),
      persist: () async {
        await _sync.smartDelete(table: 'buses', entityId: busId);
        // Persist the tour's busId clear in the SAME guarded write, so a
        // failure here also rolls back (was previously an unguarded trailing
        // write — audit M3).
        final tour = getTour(tourId);
        if (tour != null) {
          await _sync.smartUpdate(
            table: 'tours',
            entityId: tourId,
            data: tour.toMap(),
          );
        }
      },
      failure: tr('errors.remove_bus'),
    );
  }

  // Seat flags (forward / reserved)
  //
  // Both flags live on individual SeatCells inside the bus layout grid, so
  // toggling one means rebuilding that bus's layout and persisting the whole
  // bus row — the same shape updateBus uses.

  /// Toggle the "forward / premium" flag on a single seat of [busId].
  Future<void> setSeatForward(
    String tourId,
    String busId,
    String seatId,
    bool forward,
  ) => _updateSeatFlag(
    tourId,
    busId,
    seatId,
    (cell) => cell.copyWith(forward: forward),
  );

  /// Toggle the "reserved / held back" flag on a single seat of [busId].
  Future<void> setSeatReserved(
    String tourId,
    String busId,
    String seatId,
    bool reserved,
  ) => _updateSeatFlag(
    tourId,
    busId,
    seatId,
    (cell) => cell.copyWith(reserved: reserved),
  );

  /// Shared seat-flag toggler used by [setSeatForward] / [setSeatReserved].
  /// Finds the seat cell on [busId] by [seatId], applies [transform], rebuilds
  /// the layout (preserving every other cell), optimistically updates local
  /// state, and persists the whole bus row.
  Future<void> _updateSeatFlag(
    String tourId,
    String busId,
    String seatId,
    SeatCell Function(SeatCell) transform,
  ) async {
    final tour = getTour(tourId);
    final bus = tour?.buses.where((b) => b.id == busId).firstOrNull;
    final layout = bus?.layout;
    if (bus == null || layout == null) return;

    final target = layout.grid.where((c) => c.seatId == seatId).firstOrNull;
    if (target == null) return;

    final updatedBus = bus.copyWith(
      layout: layout.updateCell(transform(target)),
    );

    await _write(
      optimistic: () => _updateTourLocal(
        tourId,
        (t) => t.copyWith(
          buses: t.buses.map((b) => b.id == busId ? updatedBus : b).toList(),
        ),
      ),
      // Seat-cell edits change exactly one column. `layout` is non-null here —
      // the guard above returned early otherwise — so this is the one write that
      // legitimately carries a grid.
      persist: () => _sync.updatePatch(
        table: 'buses',
        entityId: busId,
        fields: {'layout': updatedBus.layout?.toMap()},
      ),
      failure: tr('errors.update_seat'),
    );
  }

  /// Rebuild the seat layout of a bus whose `layout` jsonb was lost, inferring
  /// the original grid from the seat ids its riders are still assigned to.
  ///
  /// Repairs the damage described in migration 065. Safe by construction: the
  /// rebuilt grid is only written when [recoverBusLayout] identifies EXACTLY one
  /// candidate, and that candidate contains every surviving seat id, so no
  /// passenger moves — unlike regenerating through the bus editor, which
  /// renumbers seats and calls [unassignBus] to clear everyone first.
  ///
  /// Returns the outcome so a caller can report ambiguity or an inconsistency
  /// instead of silently doing nothing. Refuses on a bus that still HAS a
  /// layout — this only ever fills a hole, never overwrites a live grid.
  Future<LayoutRecovery> recoverBusLayoutFor(String tourId, String busId) async {
    await ensureBusLayoutsForTour(tourId);

    final tour = getTour(tourId);
    final bus = tour?.buses.where((b) => b.id == busId).firstOrNull;
    if (tour == null || bus == null) {
      return const LayoutRecovery(reason: 'bus not found');
    }
    if (busBerths(bus).fromGrid) {
      return const LayoutRecovery(
        reason: 'bus already has a seat layout — nothing to recover',
      );
    }

    final survivors = <String>{};
    for (final p in tour.passengers) {
      for (final a in p.assignedSeats) {
        if (a.busId == busId) survivors.add(a.seatId);
      }
    }

    final result = recoverBusLayout(
      totalSeats: bus.totalSeatsLegacy,
      busType: BusType.fromString(bus.busType),
      assignedSeatIds: survivors,
    );
    final rebuilt = result.layout;
    if (rebuilt == null) return result;

    final updatedBus = bus.copyWith(layout: rebuilt);
    await _write(
      optimistic: () => _updateTourLocal(
        tourId,
        (t) => t.copyWith(
          buses: t.buses.map((b) => b.id == busId ? updatedBus : b).toList(),
        ),
      ),
      persist: () => _sync.updatePatch(
        table: 'buses',
        entityId: busId,
        fields: {'layout': rebuilt.toMap()},
      ),
      failure: tr('errors.update_bus'),
    );
    return result;
  }
}
