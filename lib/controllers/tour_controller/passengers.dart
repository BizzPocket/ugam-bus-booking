part of '../tour_controller.dart';

/// Passenger rows: add / edit / remove, leg cancels, payment, waitlist,
/// confirmation and priority flags.
mixin _TourPassengers on _TourLifecycle {
  /// Strike ONE leg from ONE seat a rider holds, so the freed half can be
  /// resold. [strike] is [TripType.returnOnly] to cancel the ride home or
  /// [TripType.outboundOnly] to cancel the ride out.
  ///
  /// The berth SURVIVES whenever the rider still travels the other leg on it —
  /// a round-trip berth is re-stamped one-way rather than deleted, so the seat
  /// keeps showing who is on it and only the struck leg's half of the tile
  /// becomes sellable. See [cancelSeatLegTransform] for the full rule.
  ///
  /// Scoped to one seat on purpose: a party holding a Double Sofa plus a Single
  /// can now cancel the return on just one of them. Cancelling for the whole
  /// party is [cancelReturnSeat], which walks each of their seats in turn.
  Future<void> cancelSeatLeg(
    String tourId,
    String passengerId, {
    required String busId,
    required String seatId,
    required TripType strike,
  }) async {
    final tour = getTour(tourId);
    if (tour == null) return;
    final p = tour.passengers.firstWhereOrNull((x) => x.id == passengerId);
    if (p == null) return;

    final updated = cancelSeatLegTransform(
      p,
      busId: busId,
      seatId: seatId,
      strike: strike,
      cellTypeAt: _cellTypeLookup(tour),
    );
    if (updated == null) {
      // Nothing of this rider survives (a return-only rider whose return is
      // struck never rode any leg) → remove them outright.
      await removePassenger(tourId, passengerId);
      return;
    }
    // The tapped seat carried no travel on the struck leg — nothing to write.
    if (identical(updated, p)) return;

    await _write(
      optimistic: () =>
          _updatePassengerLocal(tourId, passengerId, (_) => updated),
      persist: () => _sync.smartUpdate(
        table: 'passengers',
        entityId: passengerId,
        data: updated.toMap(),
      ),
      failure: tr('errors.save_passenger'),
    );
  }

  /// Cancel the RETURN leg across EVERY seat a rider holds — the whole-party
  /// version of [cancelSeatLeg], kept for callers that act on a person rather
  /// than a seat.
  ///
  /// A return-only rider never rode, so they are removed outright. Everyone else
  /// keeps the berths they actually travelled on, re-stamped outbound-only.
  Future<void> cancelReturnSeat(String tourId, String passengerId) async {
    final tour = getTour(tourId);
    if (tour == null) return;
    final p = tour.passengers.firstWhereOrNull((x) => x.id == passengerId);
    if (p == null) return;

    // Distinct seats, in held order. Snapshotted before the loop because each
    // pass rewrites the rider's assignments.
    final seen = <String>{};
    final targets = <({String busId, String seatId})>[
      for (final a in p.assignedSeats)
        if (seen.add('${a.busId}:${a.seatId}'))
          (busId: a.busId, seatId: a.seatId),
    ];

    for (final t in targets) {
      await cancelSeatLeg(
        tourId,
        passengerId,
        busId: t.busId,
        seatId: t.seatId,
        strike: TripType.returnOnly,
      );
      // The rider may have been removed outright by the pass above.
      if (getTour(tourId)?.passengers.firstWhereOrNull(
                (x) => x.id == passengerId,
              ) ==
          null) {
        return;
      }
    }

    // A rider holding NO seat still has a return booking to cancel — strike it
    // straight off the request lines so the demand goes away with the berth.
    if (targets.isEmpty) {
      final updated = cancelReturnSeatTransform(p);
      if (updated == null) {
        await removePassenger(tourId, passengerId);
        return;
      }
      await _write(
        optimistic: () =>
            _updatePassengerLocal(tourId, passengerId, (_) => updated),
        persist: () => _sync.smartUpdate(
          table: 'passengers',
          entityId: passengerId,
          data: updated.toMap(),
        ),
        failure: tr('errors.save_passenger'),
      );
    }
  }

  // Passenger Management
  Future<void> addPassenger(
    String tourId,
    Passenger passenger, {
    bool overrideLock = false,
  }) async {
    // Bookings close to CUSTOMERS once the tour is locked/completed — but that
    // gate lives on the anonymous submit_booking_request RPC (migration 026/030),
    // the ONLY path a customer can create a request through. This controller
    // method is reached exclusively by admin/handler surfaces (Requests
    // "Add request", the return-ticket sheet), so its acceptsBookings check is a
    // soft default, not the customer gate — the organiser must still be able to
    // manage a locked tour by hand.
    //
    // [overrideLock] is the organiser's deliberate "add anyway", passed by every
    // real admin add path: the manual Add-request form (a late walk-in/phone
    // booking on a locked tour) and booking a new RETURN-only ticket into a freed
    // seat during the return phase. It skips ONLY the acceptsBookings gate;
    // everything else is identical.
    final existing = getTour(tourId);
    if (!overrideLock && existing != null && !existing.acceptsBookings) {
      AppSnackBar.error(tr('errors.bookings_closed'));
      return;
    }
    await _write(
      optimistic: () => _updateTourLocal(
        tourId,
        (t) => t.copyWith(passengers: [...t.passengers, passenger]),
      ),
      persist: () => _sync.smartInsert(
        table: 'passengers',
        entityId: passenger.id,
        data: passenger.toMap(),
      ),
      failure: tr('errors.save_passenger'),
    );
    final tour = getTour(tourId);
    if (tour != null && tour.status == TourStatus.planning) {
      await updateStatus(tourId, TourStatus.collecting);
    }
  }

  Future<void> removePassenger(String tourId, String passengerId) => _write(
    optimistic: () => _updateTourLocal(
      tourId,
      (t) => t.copyWith(
        passengers: t.passengers.where((p) => p.id != passengerId).toList(),
      ),
    ),
    persist: () =>
        _sync.smartDelete(table: 'passengers', entityId: passengerId),
    failure: tr('errors.remove_passenger'),
  );

  Future<void> updatePassenger(String tourId, Passenger passenger) => _write(
    optimistic: () =>
        _updatePassengerLocal(tourId, passenger.id, (p) => passenger),
    persist: () => _sync.smartUpdate(
      table: 'passengers',
      entityId: passenger.id,
      data: passenger.toMap(),
    ),
    failure: tr('errors.update_passenger'),
  );

  /// Persist a passenger whose REQUEST LINES were just edited (e.g. a trip-leg
  /// change on the edit-request sheet). A leg edit must repropagate to money,
  /// capacity and tint — all of which read the per-seat [SeatAssignment.leg] —
  /// so re-derive every held seat's leg from the NEW request lines. The stored
  /// legs are NULLED first so the preserve-branch in [resolveAssignmentLegs]
  /// (which keeps an already-stamped leg) can't pin the STALE one; they are then
  /// re-stamped in request order. Without this, editing a rider's leg after
  /// their seats were assigned left the seats on their old leg and money/
  /// capacity read that stale leg (regression from the per-seat-leg pricing).
  Future<void> updatePassengerFromRequestEdit(
    String tourId,
    Passenger passenger,
  ) {
    final tour = getTour(tourId);
    var restamped = passenger;
    if (tour != null && passenger.assignedSeats.isNotEmpty) {
      final bare = [
        for (final a in passenger.assignedSeats)
          SeatAssignment(busId: a.busId, seatId: a.seatId, locked: a.locked),
      ];
      restamped = passenger.copyWith(
        assignedSeats: resolveAssignmentLegs(
          requestLines: passenger.requestLines,
          assigned: bare,
          cellTypeAt: _cellTypeLookup(tour),
        ),
      );
    }
    return updatePassenger(tourId, restamped);
  }

  /// Organiser DISMISSES a customer's cancellation request (migration 036) —
  /// keeps the passenger on the tour and clears the `cancel_requested_at` marker
  /// on BOTH the passenger row (this roster's badge/CTA) and the linked
  /// booking_request (the customer's pending-cancellation banner + re-request
  /// gate). The counterpart to approving (which removes the passenger). Routes
  /// through the SECURITY DEFINER RPC because the booking_request marker is not
  /// admin-writable directly; a server refusal reverts the optimistic clear.
  Future<void> dismissCancellationRequest(String tourId, String passengerId) =>
      _write(
        optimistic: () => _updatePassengerLocal(
          tourId,
          passengerId,
          (p) => p.copyWith(clearCancelRequested: true),
        ),
        persist: () async {
          final ok = await _sync.callRpcResult(
            'booking_request_admin_dismiss_cancel',
            {'p_passenger_id': passengerId},
          );
          if (ok != true) throw Exception('dismiss cancellation refused');
        },
        failure: tr('errors.dismiss_cancel'),
      );

  Future<void> updatePassengerPayment(
    String tourId,
    String passengerId,
    PaymentStatus status,
  ) async {
    Passenger? updated;
    await _write(
      optimistic: () => _updatePassengerLocal(tourId, passengerId, (p) {
        updated = p.copyWith(paymentStatus: status);
        return updated!;
      }),
      persist: () async {
        if (updated == null) return;
        await _sync.smartUpdate(
          table: 'passengers',
          entityId: passengerId,
          data: updated!.toMap(),
        );
      },
      failure: tr('errors.update_payment'),
    );
  }

  /// Toggles a passenger's waitlist flag. Moving onto the waitlist
  /// also clears any seat assignments — they should not hold seats
  /// while waitlisted.
  Future<void> setWaitlisted(
    String tourId,
    String passengerId,
    bool waitlisted,
  ) async {
    Passenger? updated;
    await _write(
      optimistic: () => _updatePassengerLocal(tourId, passengerId, (p) {
        updated = p.copyWith(
          isWaitlisted: waitlisted,
          assignedSeats: waitlisted
              ? const <SeatAssignment>[]
              : p.assignedSeats,
        );
        return updated!;
      }),
      persist: () async {
        if (updated == null) return;
        await _sync.smartUpdate(
          table: 'passengers',
          entityId: passengerId,
          data: updated!.toMap(),
        );
      },
      failure: tr('errors.update_waitlist'),
    );
  }

  /// Confirm (or un-confirm) a request: a confirmed passenger is eligible for
  /// seat allotment and moves to the Confirmed list. Confirming also clears any
  /// waitlist hold. Mirrors [setWaitlisted].
  Future<void> setConfirmed(
    String tourId,
    String passengerId,
    bool confirmed,
  ) async {
    Passenger? updated;
    await _write(
      optimistic: () => _updatePassengerLocal(tourId, passengerId, (p) {
        updated = p.copyWith(
          isConfirmed: confirmed,
          // A confirmed passenger leaves the waitlist.
          isWaitlisted: confirmed ? false : p.isWaitlisted,
        );
        return updated!;
      }),
      persist: () async {
        if (updated == null) return;
        await _sync.smartUpdate(
          table: 'passengers',
          entityId: passengerId,
          data: updated!.toMap(),
        );
      },
      failure: tr('errors.update_confirmed'),
    );
  }

  // Priority

  /// Approve or clear a passenger's priority (front/sofa) status. `approved`
  /// maps to [PriorityStatus.approved]; otherwise [PriorityStatus.none].
  Future<void> setPassengerPriority(
    String tourId,
    String passengerId,
    bool approved,
  ) async {
    Passenger? updated;
    await _write(
      optimistic: () => _updatePassengerLocal(tourId, passengerId, (p) {
        updated = p.copyWith(
          priorityStatus: approved
              ? PriorityStatus.approved
              : PriorityStatus.none,
        );
        return updated!;
      }),
      persist: () async {
        if (updated == null) return;
        await _sync.smartUpdate(
          table: 'passengers',
          entityId: passengerId,
          data: updated!.toMap(),
        );
      },
      failure: tr('errors.update_priority'),
    );
  }
}
