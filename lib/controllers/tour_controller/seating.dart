part of '../tour_controller.dart';

/// Seat placement: assign / unassign, auto-fill, group cascade, single
/// moves, and carrying a rider's money across a move.
mixin _TourSeating on _TourSeatNotify {
  /// Last seating plan produced by [fillTour], keyed by tourId. The seat
  /// Overview screen reads this to render the "N need your decision" chip
  /// without re-running the engine on every rebuild. Reactive so a fresh
  /// fillTour repaints any observer. Cleared entry is fine — absence just
  /// means "no plan generated yet this session".
  final lastPlanByTour = <String, SeatingPlan>{}.obs;

  /// Exceptions from the most recent [fillTour] for [tourId] (empty when no
  /// plan has been generated this session).
  List<SeatingException> exceptionsForTour(String tourId) =>
      lastPlanByTour[tourId]?.exceptions ?? const <SeatingException>[];

  // Seat Assignment
  //
  // Both methods follow the same shape as the other CRUD operations: stage
  // an optimistic mutation locally, await the server write, and on failure
  // pull fresh state from the server + surface the error. Without the
  // try/refresh path, a silent server reject (RLS, JSON cast, etc.) leaves
  // the user staring at the OLD seats: optimistic mutation flashes the new
  // seats, then the next realtime refetch overwrites local with the
  // unchanged server row — making the change look reverted with no
  // explanation.

  /// Buses a passenger was just UNSEATED from, keyed `'tourId|passengerId'`.
  ///
  /// The natural way to transfer a rider between buses is two taps: free their
  /// seat on bus 1, then place them on bus 2. Step one leaves the money
  /// reconciler nothing to work with (there is no seat left to re-home the
  /// collection row onto), and by step two the passenger row no longer
  /// remembers bus 1 — so the placement looks like a FIRST seating and the
  /// carry-over is skipped. The rider is then billed the full destination fare
  /// while the cash they already handed over stays stranded on bus 1.
  ///
  /// This note is the missing link. It ONLY decides whether the reconcile is
  /// worth an on-demand collections read; when the money tables are already
  /// loaded the reconcile runs regardless, and the amounts it computes never
  /// depend on this map. Cleared the moment the passenger is seated again.
  final Map<String, Set<String>> _vacatedBusIds = {};

  static String _vacatedKey(String tourId, String passengerId) =>
      '$tourId|$passengerId';

  /// Bus ids [passengerId] currently holds a seat on, read BEFORE a write.
  Set<String> _busIdsHeldBy(String tourId, String passengerId) {
    final p = getTour(tourId)
        ?.passengers
        .firstWhereOrNull((x) => x.id == passengerId);
    return {for (final a in p?.assignedSeats ?? const []) a.busId};
  }

  /// Remember that [passengerId] just gave up every seat they held on [buses],
  /// so their next placement knows their money may still be parked there.
  void _rememberVacated(String tourId, String passengerId, Set<String> buses) {
    if (buses.isEmpty) return;
    final key = _vacatedKey(tourId, passengerId);
    _vacatedBusIds.update(
      key,
      (existing) => existing..addAll(buses),
      ifAbsent: () => {...buses},
    );
  }

  Future<void> assignSeats(
    String tourId,
    String passengerId,
    List<SeatAssignment> assignments,
  ) async {
    // F1 group cohesion: never let a manual assignment SPLIT a group across
    // buses. Empty assignments (= unseat) are always allowed; a same-bus
    // placement is allowed; and the FIRST member to be seated (no sibling
    // seated anywhere yet) is allowed. We only block when this write would put
    // a grouped passenger on one bus while a sibling already sits on a
    // DIFFERENT bus. Re-seating the whole group together goes through
    // [moveGroupToBus] instead.
    if (assignments.isNotEmpty &&
        _wouldSplitGroup(tourId, passengerId, assignments)) {
      AppSnackBar.warning(tr('seat.group_locked_msg'));
      return;
    }
    // Buses this passenger sits on RIGHT NOW, read before the write. Together
    // with anything remembered from an earlier unseat, this is what tells the
    // money reconcile whether cash may be parked on a bus the rider is leaving.
    final busesBefore = _busIdsHeldBy(tourId, passengerId);

    // Stamp each berth with the leg of the request line it satisfies, so a
    // booking split across one-way legs (e.g. "1 seater GO + 1 seater RET")
    // keeps the per-seat leg after manual placement / swap-in. Falls back to
    // the raw assignments when the tour/passenger can't be resolved (the empty
    // = unseat case carries no legs anyway).
    final tourForLegs = getTour(tourId);
    final pForLegs =
        tourForLegs?.passengers.firstWhereOrNull((p) => p.id == passengerId);
    final stamped = (tourForLegs != null && pForLegs != null)
        ? resolveAssignmentLegs(
            requestLines: pForLegs.requestLines,
            assigned: assignments,
            cellTypeAt: _cellTypeLookup(tourForLegs),
          )
        : assignments;
    Passenger? updated;
    await _write(
      optimistic: () => _updatePassengerLocal(tourId, passengerId, (p) {
        updated = p.copyWith(assignedSeats: stamped);
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
      failure: tr('errors.save_seat_assignment'),
    );

    // Past this point the write landed (_write rethrows on failure).
    //
    // Everything the rider is walking away from: seats they held a moment ago
    // plus anything an earlier unseat parked in [_vacatedBusIds]. Clearing the
    // note here (and re-arming it below when they end up with no seats at all)
    // keeps it accurate for exactly one hand-off.
    final key = _vacatedKey(tourId, passengerId);
    final leaving = {...busesBefore, ...?_vacatedBusIds.remove(key)};
    final busesAfter = {for (final a in stamped) a.busId};

    if (assignments.isEmpty) {
      // Step one of a free-then-place transfer. There is no seat to re-home the
      // collection row onto yet, so a reconcile here is a guaranteed no-op —
      // remember the vacated bus instead and let the placement do the work.
      _rememberVacated(tourId, passengerId, leaving);
      return;
    }

    // The first real seat placement moves the tour into the "assigning" phase.
    // Without this the status machine stalled at `busBooked` forever, which in
    // turn left the per-tour Lock CTA permanently disabled (it gated on
    // `status == assigning`). Now seating progress is reflected in the
    // lifecycle and the lock gate.
    final tour = getTour(tourId);
    if (tour != null && tour.status == TourStatus.busBooked) {
      await updateStatus(tourId, TourStatus.assigning);
    }
    // A seat placed from the chart on a not-yet-confirmed rider IS the
    // confirmation: flip the flag + fire the WhatsApp greeting, matching the
    // Requests "Confirm" button (which otherwise never runs on this path).
    await _confirmAndNotifyOnSeat(tourId, [passengerId]);

    // Carry the money with the rider. `moveSeat` has always done this; a plain
    // assignment never did, so the very natural "free the seat on bus 1, then
    // place them on bus 2" transfer left the collection row pointing at bus 1
    // and billed the rider the FULL destination fare instead of the difference.
    //
    // [crossedBus] is true only when this write actually takes the rider OFF a
    // bus they were on (directly, or via the unseat remembered above). That
    // keeps the reconcile's on-demand collections read off the common path —
    // a first-time placement can strand nothing, so it never pays for a fetch.
    await _reconcileMoneyAfterMove(
      tourId,
      [passengerId],
      crossedBus: leaving.difference(busesAfter).isNotEmpty,
    );
  }

  /// F1 group cohesion: re-seat [anchorPassengerId] AND every group sibling
  /// onto [destinationBusId] as ONE atomic move, so a group is always wholly on
  /// a single bus (within a bus, arrangement is free). The seat math is
  /// delegated to [GroupCascade.planAssignments], which mirrors the engine on a
  /// single-bus snapshot; each member's ENTIRE `assignedSeats` is REPLACED with
  /// the engine-proposed berths on the destination bus (so nobody is left
  /// behind on the old bus).
  ///
  /// Returns true on success. Returns false (after an
  /// [AppSnackBar.warning]) when the group does not fully fit on the
  /// destination, or when the tour/anchor can't be resolved.
  ///
  /// Mirrors [fillTour]'s persistence: an optimistic local update, then the
  /// atomic `applySeatAssignments` RPC with a per-passenger
  /// [RpcUnavailableException] fallback, snapping back to server truth on a
  /// hard write failure.
  Future<bool> moveGroupToBus({
    required String tourId,
    required String anchorPassengerId,
    required String destinationBusId,
  }) async {
    final tour = getTour(tourId);
    if (tour == null) return false;
    final anchor = tour.passengers.firstWhereOrNull(
      (p) => p.id == anchorPassengerId,
    );
    final destination = tour.buses.firstWhereOrNull(
      (b) => b.id == destinationBusId,
    );
    if (anchor == null || destination == null) {
      AppSnackBar.warning(tr('seat.group_move_failed'));
      return false;
    }

    final plan = GroupCascade.planAssignments(
      mover: anchor,
      destinationBus: destination,
      passengers: tour.passengers,
    );
    if (plan == null) {
      // Does not fully fit on the destination bus. Name the bus and the party
      // size: "the whole group does not fit on this bus" left the operator
      // guessing which bus and how many people the app was talking about.
      final gid = anchor.groupId;
      final count = (gid == null || gid.isEmpty)
          ? 1
          : tour.passengers.where((p) => p.groupId == gid).length;
      AppSnackBar.warning(
        tr(
          'seat.group_move_no_fit_on',
          namedArgs: {'bus': destination.name, 'count': '$count'},
        ),
      );
      return false;
    }

    // Apply every moved member LOCALLY in one pass (one repaint), REPLACING the
    // member's entire assignedSeats — so any berths they held on the OLD bus are
    // dropped, not merged.
    _updateTourLocal(tourId, (t) {
      final list = t.passengers.map((p) {
        final ns = plan[p.id];
        return ns == null ? p : p.copyWith(assignedSeats: ns);
      }).toList();
      return t.copyWith(passengers: list);
    });

    try {
      try {
        await _sync.applySeatAssignments(
          tourId: tourId,
          assignments: [
            for (final entry in plan.entries)
              {
                'id': entry.key,
                'assigned_seats': entry.value
                    .map((s) => s.toMap())
                    .toList(),
              },
          ],
        );
      } on RpcUnavailableException {
        // Migration 011 not deployed yet — fall back to per-passenger writes.
        final updated = getTour(tourId);
        for (final id in plan.keys) {
          final p = updated?.passengers.firstWhereOrNull((x) => x.id == id);
          if (p == null) continue;
          await _sync.smartUpdate(
            table: 'passengers',
            entityId: id,
            data: p.toMap(),
          );
        }
      }
    } catch (e) {
      await refreshTours();
      AppSnackBar.error(
        tr('seat.group_move_save', namedArgs: {'e': '$e'}),
        title: tr('errors.save_failed'),
      );
      return false;
    }

    // A group move is a real seat placement: advance the lifecycle the same way
    // assignSeats / fillTour do, so the Lock CTA unlocks.
    final t = getTour(tourId);
    if (t != null && t.status == TourStatus.busBooked) {
      await updateStatus(tourId, TourStatus.assigning);
    }
    // A group move can seat a previously-unseated sibling: confirm + notify any
    // moved rider who was never confirmed, same as a single-seat placement.
    await _confirmAndNotifyOnSeat(tourId, plan.keys);
    // Every member just changed bus, so each one's paid-vs-due gap is re-priced
    // at the destination's bands.
    await _reconcileMoneyAfterMove(tourId, plan.keys, crossedBus: true);
    return true;
  }

  /// Auto-fill an entire tour with the deterministic [SeatingEngine].
  ///
  /// Finds the tour, asks the engine to [SeatingEngine.propose] a plan from
  /// its buses + passengers, diffs that against current state via
  /// [SeatingPlanApplier.diff], and persists ONLY the passengers that
  /// actually changed — each through the existing offline-first
  /// [assignSeats] path (no double-writes, no bypassing SyncService). A
  /// passenger whose seats are unchanged is skipped entirely, so a re-run
  /// with nothing to change is a no-op on the wire.
  ///
  /// The returned [SeatingPlan] (also cached in [lastPlanByTour]) carries
  /// the exceptions the UI surfaces as "needs your decision".
  Future<SeatingPlan> fillTour(String tourId) async {
    await ensureTourReadyForSeating(tourId);
    final tour = getTour(tourId);
    if (tour == null) {
      // Nothing to fill — hand back an empty plan so callers don't null-check.
      const empty = SeatingPlan(
        assignmentsByPassenger: {},
        exceptions: [],
        reasons: [],
      );
      lastPlanByTour[tourId] = empty;
      lastPlanByTour.refresh();
      return empty;
    }

    final plan = SeatingEngine.propose(
      buses: tour.buses,
      passengers: tour.passengers,
    );

    // Cache the plan so the Overview screen can render exceptions even if
    // the caller didn't hold the return value.
    lastPlanByTour[tourId] = plan;
    lastPlanByTour.refresh();

    final changes = SeatingPlanApplier.diff(
      plan: plan,
      passengers: tour.passengers,
    );
    if (changes.isEmpty) return plan;

    // Apply every changed passenger LOCALLY in one pass (one repaint), then
    // persist the WHOLE plan in a single atomic transaction (DI-2). If the
    // server write fails it's all-or-nothing, so we just snap back to server
    // truth and ask the agent to re-generate — never a half-applied plan.
    final changeMap = {
      for (final c in changes) c.passengerId: c.newAssignedSeats,
    };
    _updateTourLocal(tourId, (t) {
      final list = t.passengers.map((p) {
        final ns = changeMap[p.id];
        return ns == null ? p : p.copyWith(assignedSeats: ns);
      }).toList();
      return t.copyWith(passengers: list);
    });

    try {
      try {
        await _sync.applySeatAssignments(
          tourId: tourId,
          assignments: [
            for (final c in changes)
              {
                'id': c.passengerId,
                'assigned_seats': c.newAssignedSeats
                    .map((s) => s.toMap())
                    .toList(),
              },
          ],
        );
      } on RpcUnavailableException {
        // Migration 011 not deployed yet — fall back to per-passenger writes,
        // but STOP on the first failure so we never leave a half-applied plan
        // (DI-2). Refresh then surfaces server truth.
        final updated = getTour(tourId);
        for (final c in changes) {
          final p = updated?.passengers.firstWhereOrNull(
            (x) => x.id == c.passengerId,
          );
          if (p == null) continue;
          await _sync.smartUpdate(
            table: 'passengers',
            entityId: c.passengerId,
            data: p.toMap(),
          );
        }
      }
    } catch (e) {
      await refreshTours();
      AppSnackBar.error(
        tr('errors.autofill_save', namedArgs: {'e': '$e'}),
        title: tr('errors.autofill_failed'),
      );
      return plan;
    }

    // First placement moves the tour into the "assigning" phase (once), which
    // unlocks the per-tour Lock CTA. Mirrors the single-seat assignSeats path.
    final t = getTour(tourId);
    if (t != null && t.status == TourStatus.busBooked) {
      await updateStatus(tourId, TourStatus.assigning);
    }

    // Any rider auto-fill just SEATED who was never confirmed is confirmed +
    // notified now — the same implicit confirmation as a manual chart placement.
    await _confirmAndNotifyOnSeat(tourId, changes.map((c) => c.passengerId));

    // F2 priority: surface a warning right after auto-fill (from ANY screen)
    // when an approved-priority passenger was seated but could not get a lower
    // berth — the dedicated alert lives on the seating-exceptions screen, but
    // this snack flags it immediately so it isn't missed.
    if (plan.exceptions.any(
      (e) => e.type == SeatingExceptionType.priorityNoLowerBerth,
    )) {
      AppSnackBar.warning(tr('priority.no_lower_snack'));
    }

    return plan;
  }

  /// Free every seat [passengerId] holds on [tourId].
  ///
  /// No money reconcile runs here, on purpose: with no seat left there is
  /// nothing to re-home a collection row ONTO, so the collection reconciler
  /// would return an empty plan by construction. The cash stays visible as detached
  /// cash on the bus that took it (money is never deleted), and the bus is
  /// noted in [_vacatedBusIds] so the rider's NEXT placement — the second half
  /// of a free-then-place transfer — carries it across and re-prices it.
  Future<void> unassignSeats(String tourId, String passengerId) async {
    final vacating = _busIdsHeldBy(tourId, passengerId);
    Passenger? updated;
    await _write(
      optimistic: () => _updatePassengerLocal(tourId, passengerId, (p) {
        updated = p.copyWith(assignedSeats: []);
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
      failure: tr('errors.clear_seat_assignment'),
    );
    _rememberVacated(tourId, passengerId, vacating);
  }

  /// Free every seat on [busId] across all passengers of [tourId] in one go.
  /// Each passenger keeps any seats they hold on OTHER buses, and their
  /// request lines are left intact — so they reappear as needing assignment
  /// and can be re-seated immediately. Persists only the passengers that
  /// actually changed.
  ///
  /// Emptying a bus is a free-then-place transfer for everyone who was on it,
  /// so each cleared rider is noted in [_vacatedBusIds] — their re-seating on
  /// another bus then carries their money over instead of billing them the full
  /// fare again. See [unassignSeats] for why no reconcile runs here.
  Future<void> unassignBus(String tourId, String busId) async {
    final tour = getTour(tourId);
    if (tour == null) return;

    final changed = <Passenger>[];
    await _write(
      optimistic: () {
        for (final p in tour.passengers) {
          if (!p.assignedSeats.any((a) => a.busId == busId)) continue;
          final remaining = p.assignedSeats
              .where((a) => a.busId != busId)
              .toList();
          Passenger? updated;
          _updatePassengerLocal(tourId, p.id, (cur) {
            updated = cur.copyWith(assignedSeats: remaining);
            return updated!;
          });
          if (updated != null) changed.add(updated!);
        }
      },
      persist: () async {
        for (final p in changed) {
          await _sync.smartUpdate(
            table: 'passengers',
            entityId: p.id,
            data: p.toMap(),
          );
        }
      },
      failure: tr('errors.clear_bus'),
    );
    for (final p in changed) {
      _rememberVacated(tourId, p.id, {busId});
    }
  }

  /// Customer-cancels a single seat — common phone-in flow: "I booked 3
  /// seats but I only need 2 now". The agent picks the seat to drop and
  /// this method does BOTH the unassignment AND the request-line
  /// decrement so the passenger doesn't keep showing up in the Requests
  /// tab as "1 seat outstanding".
  ///
  /// Looks up the seat's type+position from the bus layout to find the
  /// right RequestLine to decrement (prefers exact type+position match,
  /// falls back to seatType-only). If qty drops to 0 the line is removed
  /// from the list entirely. If no matching line exists, only the seat
  /// is freed and the request is left untouched.
  Future<void> cancelOneSeat({
    required String tourId,
    required String passengerId,
    required String busId,
    required String seatId,
  }) async {
    final tour = getTour(tourId);
    final bus = tour?.buses.where((b) => b.id == busId).firstOrNull;
    final layout = bus?.layout;
    SeatCell? cell;
    if (layout != null) {
      for (final c in layout.grid) {
        if (c.seatId == seatId) {
          cell = c;
          break;
        }
      }
    }
    final type = cell?.seatType;
    final pos = cell?.position;

    Passenger? updated;
    await _write(
      optimistic: () => _updatePassengerLocal(tourId, passengerId, (p) {
        final newAssigned = p.assignedSeats
            .where((a) => !(a.busId == busId && a.seatId == seatId))
            .toList();

        List<RequestLine> newRequest = List.of(p.requestLines);
        if (type != null) {
          // First pass: exact (type + position) match.
          var idx = newRequest.indexWhere(
            (l) => l.seatType == type && l.position == pos && l.qty > 0,
          );
          // Second pass: seat-type-only match (handles requests that came
          // in without an explicit upper/lower preference).
          if (idx < 0) {
            idx = newRequest.indexWhere((l) => l.seatType == type && l.qty > 0);
          }
          if (idx >= 0) {
            final line = newRequest[idx];
            if (line.qty > 1) {
              newRequest[idx] = line.copyWith(qty: line.qty - 1);
            } else {
              newRequest.removeAt(idx);
            }
          }
        }

        updated = p.copyWith(
          assignedSeats: newAssigned,
          requestLines: newRequest,
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
      failure: tr('errors.cancel_seat'),
    );
  }

  /// Consolidate a set of source seats (typically two single sofas
  /// previously cross-filled to satisfy a `doubleSofa` request) into
  /// a single whole Double Sofa for the same passenger. The drag-drop
  /// overview tab calls this when the admin drags one of those singles
  /// onto a free Double Sofa — the partner single is released in the
  /// same atomic write and the passenger ends up owning both berths
  /// on the target double.
  ///
  /// All [sourceSeatIds] on [busId] are removed from the passenger's
  /// `assignedSeats`; exactly 2 entries are added at [targetSeatId].
  /// Assignments on other buses or other seats are untouched.
  Future<void> consolidateOntoDouble({
    required String tourId,
    required String passengerId,
    required String busId,
    required String targetSeatId,
    required List<String> sourceSeatIds,
  }) async {
    // A Double Sofa holds exactly two berths, so consolidation always folds
    // EXACTLY two source singles into the one target cell. This guards the
    // contract: it adds two target berths below regardless of how many
    // sources it removed, so a single-source call would over-assign the
    // passenger (remove 1, add 2). Catch that in debug/tests.
    assert(
      sourceSeatIds.length == 2,
      'consolidateOntoDouble expects exactly 2 source seats, got '
      '${sourceSeatIds.length}',
    );
    final tour = getTour(tourId);
    Passenger? updated;
    await _write(
      optimistic: () => _updatePassengerLocal(tourId, passengerId, (p) {
        final next =
            p.assignedSeats
                .where(
                  (a) =>
                      !(a.busId == busId && sourceSeatIds.contains(a.seatId)),
                )
                .toList()
              ..add(SeatAssignment(busId: busId, seatId: targetSeatId))
              ..add(SeatAssignment(busId: busId, seatId: targetSeatId));
        // Re-stamp per-seat legs: the leg multiset is unchanged by folding two
        // singles into a whole double, but the seatIds changed.
        final stamped = tour == null
            ? next
            : resolveAssignmentLegs(
                requestLines: p.requestLines,
                assigned: next,
                cellTypeAt: _cellTypeLookup(tour),
              );
        updated = p.copyWith(assignedSeats: stamped);
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
      failure: tr('errors.consolidate_double'),
    );
  }

  /// Carry the money with the people who just moved.
  ///
  /// Collections are keyed `(passenger_id, bus_id, seat_id)` and every fare is
  /// resolved from the bus the rider currently sits on, so a seat move that is
  /// not mirrored onto the collection rows leaves a rider who ALREADY PAID
  /// billed the full fare again on the destination bus while their cash sits
  /// stranded on the old one. [MoneyController.reconcileAfterSeatMove] re-homes
  /// the row and re-prices it to the destination bus's band; the deltas it
  /// returns are what is left to collect (or hand back) at the new price.
  ///
  /// Best-effort on purpose. The seat move is already persisted and on screen
  /// by the time this runs, so a money failure must not unwind it — the money
  /// controller surfaces its own error and refetches.
  Future<void> _reconcileMoneyAfterMove(
    String tourId,
    Iterable<String> passengerIds, {
    required bool crossedBus,
  }) async {
    if (!Get.isRegistered<MoneyController>()) return;
    final tour = getTour(tourId);
    if (tour == null) return;
    try {
      final deltas = await Get.find<MoneyController>().reconcileAfterSeatMove(
        tour: tour,
        passengerIds: passengerIds,
        crossedBus: crossedBus,
      );
      await SeatMoveMoneyNotice.show(deltas, tour: tour);
    } catch (e, st) {
      // Best-effort really is best-effort: the seat move is already persisted
      // and drawn, so nothing here may propagate and unwind it. The money
      // controller raises its own toast for write failures; anything reaching
      // this point (a missing dependency, no overlay to draw the notice into)
      // is logged and dropped.
      //
      // What happens to the rows then: they stay orphaned until the NEXT write
      // that touches this passenger's seats runs a reconcile — a move, a swap,
      // a group cascade, or a plain (re)assignment. Nothing heals them merely
      // by opening the collection screen; [MoneyController.reconcileAfterSeatMove]
      // is only ever called from here. So an orphan can outlive the session,
      // and until it is re-homed the collection screen shows the cash as
      // detached on the origin bus rather than credited on the destination.
      dev.log(
        'money reconcile after seat move failed — $e\n$st',
        name: 'TourController',
      );
    }
  }

  /// Move a single seat from one slot to another within the same bus for
  /// the same passenger. The drag-and-drop overview tab uses this when
  /// the agent drops an occupied seat onto a free slot.
  ///
  /// Both ends of the swap have to land on the server for the chart to
  /// stay consistent — failure here triggers a server refresh so the UI
  /// snaps back to truth instead of holding a phantom move.
  ///
  /// [toBusId] defaults to [busId] (a same-bus move). Pass a different
  /// [toBusId] to move the passenger onto ANOTHER bus — the source berths are
  /// matched on [busId]/[fromSeatId] and re-created on [toBusId]/[toSeatId], so
  /// a whole-double crosses intact.
  /// [berths] caps how many berths move. Null moves every berth the passenger
  /// holds on [fromSeatId] (the default — a whole-double crosses intact). Pass
  /// 1 to PEEL a single berth off a substitute whole-double (a split): one berth
  /// lands on [toSeatId] and the remainder stays on the source cell.
  ///
  /// Returns what actually happened — see [SeatMoveOutcome]. Callers that show
  /// a "moved" confirmation, clear a relocate banner, or decide whether to
  /// re-notify a rider MUST branch on it: a cross-bus move of a grouped rider
  /// is rerouted into [moveGroupToBus], which can refuse outright.
  Future<SeatMoveOutcome> moveSeat({
    required String tourId,
    required String passengerId,
    required String busId,
    required String fromSeatId,
    required String toSeatId,
    String? toBusId,
    int? berths,
  }) async {
    final targetBusId = toBusId ?? busId;

    // F1 group cohesion: a CROSS-bus move of a grouped passenger whose siblings
    // are not ALL already on the destination bus would split the group — reroute
    // the whole group via moveGroupToBus instead of moving this one berth. (The
    // engine re-seats the group on the destination, so the specific [toSeatId]
    // is intentionally not preserved for grouped movers — which is why this
    // reports [SeatMoveOutcome.groupReseated] and not a plain `moved`.) Same-bus
    // moves and ungrouped movers fall through to the plain per-seat path below.
    if (targetBusId != busId &&
        _groupNotAllOnBus(tourId, passengerId, targetBusId)) {
      final ok = await moveGroupToBus(
        tourId: tourId,
        anchorPassengerId: passengerId,
        destinationBusId: targetBusId,
      );
      // The cascade's verdict is the move's verdict. Dropping it on the floor
      // is what let the app report "moved" while the whole family stayed put.
      return ok ? SeatMoveOutcome.groupReseated : SeatMoveOutcome.failed;
    }

    final tour = getTour(tourId);
    Passenger? updated;
    await _write(
      optimistic: () => _updatePassengerLocal(tourId, passengerId, (p) {
        // Count how many berths this passenger holds on the source cell.
        // 2 happens when they own a whole-double; 1 in every other case.
        // We replicate that count onto the target so a whole-double move
        // doesn't silently downgrade to a half-double — unless [berths] caps it
        // (a split), in which case the surplus stays put on the source cell.
        final held = p.assignedSeats
            .where((a) => a.busId == busId && a.seatId == fromSeatId)
            .length;
        if (held == 0) {
          updated = p;
          return p;
        }
        final moveCount = berths == null
            ? held
            : (berths < held ? berths : held);
        final keepOnSource = held - moveCount;
        final next = p.assignedSeats
            .where((a) => !(a.busId == busId && a.seatId == fromSeatId))
            .toList();
        for (var i = 0; i < keepOnSource; i++) {
          next.add(SeatAssignment(busId: busId, seatId: fromSeatId));
        }
        for (var i = 0; i < moveCount; i++) {
          next.add(SeatAssignment(busId: targetBusId, seatId: toSeatId));
        }
        // Re-stamp per-seat legs: a move keeps the leg multiset (only seatIds
        // change), so resolve against the same request lines on the new cells.
        final stamped = tour == null
            ? next
            : resolveAssignmentLegs(
                requestLines: p.requestLines,
                assigned: next,
                cellTypeAt: _cellTypeLookup(tour),
              );
        updated = p.copyWith(assignedSeats: stamped);
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
      failure: tr('errors.move_seat'),
    );

    // Only reached when the seat write actually landed (_write rethrows), so
    // the money is never carried for a move that snapped back.
    await _reconcileMoneyAfterMove(
      tourId,
      [passengerId],
      crossedBus: targetBusId != busId,
    );
    return SeatMoveOutcome.moved;
  }

  // ── F1 group cohesion guards (shared by moveSeat/assignSeats) ──

  /// True when [passengerId] travels with OTHERS and not every group member
  /// already sits wholly on [busId]. Drives the cross-bus reroute in [moveSeat]:
  /// moving a lone berth to another bus would split the group, so the whole
  /// group must cascade. An ungrouped passenger (or a group already entirely on
  /// [busId]) is never split, so this returns false.
  ///
  /// A ONE-PERSON group is deliberately not a group. Bookings carry a groupId
  /// long after the party shrinks to a single rider, and treating that as a
  /// group sent a solo mover through the engine cascade — which re-seats at
  /// engine-chosen berths and therefore SILENTLY DISCARDED the seat the operator
  /// tapped. Nobody can be split from themselves, so a lone member takes the
  /// plain per-seat path and lands exactly where they were put.
  bool _groupNotAllOnBus(String tourId, String passengerId, String busId) {
    final tour = getTour(tourId);
    if (tour == null) return false;
    final p = tour.passengers.firstWhereOrNull((x) => x.id == passengerId);
    final gid = p?.groupId;
    if (gid == null || gid.isEmpty) return false;
    final members = tour.passengers.where((x) => x.groupId == gid).toList();
    if (members.length < 2) return false;
    // A member "splits" if they hold any seat on a bus OTHER than [busId].
    return members.any(
      (m) => m.assignedSeats.any((a) => a.busId != busId),
    );
  }

  /// True when writing [assignments] for [passengerId] would SPLIT their group
  /// across buses: the passenger is grouped, the new assignments place them on a
  /// bus, and some sibling already sits on a DIFFERENT bus. Used by
  /// [assignSeats] to block group-splitting manual writes. (The first member to
  /// be seated — no sibling seated anywhere yet — never splits, so returns
  /// false; an ungrouped passenger never splits.)
  bool _wouldSplitGroup(
    String tourId,
    String passengerId,
    List<SeatAssignment> assignments,
  ) {
    final tour = getTour(tourId);
    if (tour == null) return false;
    final p = tour.passengers.firstWhereOrNull((x) => x.id == passengerId);
    final gid = p?.groupId;
    if (gid == null || gid.isEmpty) return false;

    // Buses this write would place the passenger on.
    final newBusIds = assignments.map((a) => a.busId).toSet();
    if (newBusIds.isEmpty) return false;

    // Buses any OTHER group member already sits on.
    final siblingBusIds = <String>{};
    for (final m in tour.passengers) {
      if (m.id == passengerId || m.groupId != gid) continue;
      for (final a in m.assignedSeats) {
        siblingBusIds.add(a.busId);
      }
    }
    if (siblingBusIds.isEmpty) return false; // no sibling seated yet — allowed.

    // Split when the new placement lands on any bus a sibling is NOT on.
    return newBusIds.any((b) => !siblingBusIds.contains(b));
  }
}
