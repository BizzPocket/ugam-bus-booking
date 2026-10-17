part of '../tour_controller.dart';

/// Multi-occupant moves and two-passenger seat swaps.
mixin _TourSeatSwaps on _TourSeating {
  /// Move EVERY occupant of [fromSeatId] together onto [toSeatId] on the same
  /// bus — the drag-and-drop grid uses this when a SHARED double (two people on
  /// one sofa) is dropped onto a fully-free double. Each occupant keeps the
  /// berth count and leg they held, so a shared pair lands intact and a
  /// leg-disjoint reuse stays paired. Same-bus only, so no group can be split.
  Future<void> moveSharedPair({
    required String tourId,
    required String busId,
    required String fromSeatId,
    required String toSeatId,
  }) async {
    if (fromSeatId == toSeatId) return;
    final tour = getTour(tourId);
    if (tour == null) return;
    final movers = tour.passengers
        .where(
          (p) => p.assignedSeats
              .any((a) => a.busId == busId && a.seatId == fromSeatId),
        )
        .toList();
    if (movers.isEmpty) return;

    final changed = <Passenger>[];
    await _write(
      optimistic: () {
        for (final m in movers) {
          Passenger? updated;
          _updatePassengerLocal(tourId, m.id, (p) {
            final berths = p.assignedSeats
                .where((a) => a.busId == busId && a.seatId == fromSeatId)
                .length;
            if (berths == 0) {
              updated = p;
              return p;
            }
            final next = p.assignedSeats
                .where((a) => !(a.busId == busId && a.seatId == fromSeatId))
                .toList();
            for (var i = 0; i < berths; i++) {
              next.add(SeatAssignment(busId: busId, seatId: toSeatId));
            }
            // Re-stamp per-seat legs: moving the pair keeps each occupant's leg
            // multiset, only the seatId changes.
            final stamped = resolveAssignmentLegs(
              requestLines: p.requestLines,
              assigned: next,
              cellTypeAt: _cellTypeLookup(tour),
            );
            updated = p.copyWith(assignedSeats: stamped);
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
      failure: tr('errors.move_seat'),
    );
  }

  /// Exchange the FULL contents of two seats on one bus — every occupant of
  /// [seatAId] moves to [seatBId] and vice versa, each keeping their berth count
  /// and leg. Used by the drag grid for a pair-for-pair Double Sofa swap (two
  /// couples exchange sofas) where a one-for-one [swapSeats] can't express the
  /// multi-occupant exchange. Same-bus only, so no group can be split.
  Future<void> swapSeatContents({
    required String tourId,
    required String busId,
    required String seatAId,
    required String seatBId,
  }) async {
    if (seatAId == seatBId) return;
    final tour = getTour(tourId);
    if (tour == null) return;
    // Everyone holding a berth on EITHER seat is affected (a passenger can't be
    // on both distinct cells, so the two sides never overlap on one person).
    final affected = tour.passengers
        .where(
          (p) => p.assignedSeats.any(
            (a) => a.busId == busId && (a.seatId == seatAId || a.seatId == seatBId),
          ),
        )
        .toList();
    if (affected.isEmpty) return;

    final changed = <Passenger>[];
    await _write(
      optimistic: () {
        for (final m in affected) {
          Passenger? updated;
          _updatePassengerLocal(tourId, m.id, (p) {
            final onA = p.assignedSeats
                .where((a) => a.busId == busId && a.seatId == seatAId)
                .length;
            final onB = p.assignedSeats
                .where((a) => a.busId == busId && a.seatId == seatBId)
                .length;
            if (onA == 0 && onB == 0) {
              updated = p;
              return p;
            }
            final next = p.assignedSeats
                .where((a) => !(a.busId == busId &&
                    (a.seatId == seatAId || a.seatId == seatBId)))
                .toList();
            for (var i = 0; i < onA; i++) {
              next.add(SeatAssignment(busId: busId, seatId: seatBId));
            }
            for (var i = 0; i < onB; i++) {
              next.add(SeatAssignment(busId: busId, seatId: seatAId));
            }
            // Re-stamp per-seat legs: a contents swap keeps each occupant's leg
            // multiset, only the seatIds change.
            final stamped = resolveAssignmentLegs(
              requestLines: p.requestLines,
              assigned: next,
              cellTypeAt: _cellTypeLookup(tour),
            );
            updated = p.copyWith(assignedSeats: stamped);
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
      failure: tr('errors.move_seat'),
    );
  }

  /// Exchange seats between two passengers on the same bus. Used by the
  /// drag-and-drop overview when one occupied seat is dropped onto
  /// another occupied seat.
  ///
  /// Local state is mutated in one synchronous pass so the UI never
  /// shows a halfway state where both passengers appear to hold the
  /// same seat. Persistence prefers the atomic `swap_passenger_seats`
  /// RPC (migration 011); if that RPC is undeployed we fall back to two
  /// sequential writes and refresh on failure.
  ///
  /// [busBId] defaults to [busId] (both passengers on one bus). Pass a
  /// different [busBId] to swap ACROSS buses: A lands on B's bus/seat and B on
  /// A's bus/seat. Each side keeps its own berth count (whole doubles stay
  /// whole).
  Future<void> swapSeats({
    required String tourId,
    required String busId,
    required String passengerAId,
    required String seatAId,
    required String passengerBId,
    required String seatBId,
    String? busBId,
    List<({String passengerId, String busId, String seatId})> bump = const [],
  }) async {
    if (passengerAId == passengerBId) return;
    final busAId = busId;
    final bBusId = busBId ?? busId;
    if (busAId == bBusId && seatAId == seatBId) return;

    // F1 group cohesion: a CROSS-bus swap where either side belongs to a group
    // would split that group. A plain berth-for-berth swap can't keep a group
    // whole, so reroute the grouped side(s) through moveGroupToBus — A's group
    // re-seats onto B's bus and/or B's group onto A's bus. (If both are grouped,
    // each group moves to the other's bus.) Same-bus swaps and all-ungrouped
    // swaps fall through to the plain two-row swap below.
    if (busAId != bBusId) {
      final tour = getTour(tourId);
      final pA = tour?.passengers.firstWhereOrNull((p) => p.id == passengerAId);
      final pB = tour?.passengers.firstWhereOrNull((p) => p.id == passengerBId);
      final aGid = pA?.groupId;
      final bGid = pB?.groupId;
      final aGrouped = aGid != null && aGid.isNotEmpty;
      final bGrouped = bGid != null && bGid.isNotEmpty;
      if (aGrouped || bGrouped) {
        if (aGrouped) {
          await moveGroupToBus(
            tourId: tourId,
            anchorPassengerId: passengerAId,
            destinationBusId: bBusId,
          );
        }
        // Only move B's group separately when it is a DIFFERENT group than A's.
        // If A and B share one group, moving A's group to B's bus already pulls
        // B along — a second move would just undo it.
        if (bGrouped && bGid != aGid) {
          await moveGroupToBus(
            tourId: tourId,
            anchorPassengerId: passengerBId,
            destinationBusId: busAId,
          );
        }
        return;
      }
    }

    // Capacity backstop (defense-in-depth): never write more berths onto a cell
    // than it can hold. A whole double (2 berths) must not land on a single, nor
    // vice-versa — that silently over-books the cell and corrupts the chart.
    // Callers SHOULD already gate this (the drag engine and SwapCandidateFinder
    // both do), but this is the last line before persistence — and the only one
    // that also covers cross-bus swaps.
    {
      final tour = getTour(tourId);
      if (tour != null) {
        int capOf(String bId, String sId) {
          for (final b in tour.buses) {
            if (b.id != bId) continue;
            for (final cl in b.layout?.grid ?? const <SeatCell>[]) {
              if (cl.seatId == sId) {
                return cl.seatType == SeatType.doubleSofa ? 2 : 1;
              }
            }
          }
          return 1;
        }

        int berthsOn(String pid, String bId, String sId) =>
            tour.passengers
                .firstWhereOrNull((x) => x.id == pid)
                ?.assignedSeats
                .where((a) => a.busId == bId && a.seatId == sId)
                .length ??
            0;

        final bA = berthsOn(passengerAId, busAId, seatAId);
        final bB = berthsOn(passengerBId, bBusId, seatBId);
        if (bB > capOf(busAId, seatAId) || bA > capOf(bBusId, seatBId)) {
          AppSnackBar.error(tr('errors.move_seat'));
          return;
        }
      }
    }

    // Leg-conflict resolution (set by the UI guard): occupants to bump OFF a
    // seat so the incoming passenger doesn't over-book a shared leg. Each is
    // cleared from its (busId, seatId) — requestLines are kept, so they return
    // to the unseated pool rather than losing their booking. Keyed by passenger
    // → the set of "busId|seatId" berths to drop.
    final bumpBySeat = <String, Set<String>>{};
    for (final x in bump) {
      (bumpBySeat[x.passengerId] ??= <String>{}).add('${x.busId}|${x.seatId}');
    }
    final updatedBumped = <Passenger>[];

    Passenger? updatedA;
    Passenger? updatedB;
    _updateTourLocal(tourId, (t) {
      // Berth counts on each side. The swap preserves each passenger's
      // berth count: A's berths on seatA → A's berths on seatB, and
      // vice versa. Whole-double swaps still carry both berths.
      final pA = t.passengers.firstWhere(
        (p) => p.id == passengerAId,
        orElse: () => t.passengers.first,
      );
      final pB = t.passengers.firstWhere(
        (p) => p.id == passengerBId,
        orElse: () => t.passengers.first,
      );
      final berthsA = pA.assignedSeats
          .where((a) => a.busId == busAId && a.seatId == seatAId)
          .length;
      final berthsB = pB.assignedSeats
          .where((a) => a.busId == bBusId && a.seatId == seatBId)
          .length;

      // Re-stamp per-seat legs after the swap: each side keeps its leg multiset
      // (only seatIds change), so resolve against that passenger's own request
      // lines on the new cells. [t] is the tour, so its layouts feed the lookup.
      final cellTypeAt = _cellTypeLookup(t);

      final newPassengers = t.passengers.map((p) {
        if (p.id == passengerAId) {
          final next = p.assignedSeats
              .where((a) => !(a.busId == busAId && a.seatId == seatAId))
              .toList();
          for (var i = 0; i < berthsA; i++) {
            next.add(SeatAssignment(busId: bBusId, seatId: seatBId));
          }
          updatedA = p.copyWith(
            assignedSeats: resolveAssignmentLegs(
              requestLines: p.requestLines,
              assigned: next,
              cellTypeAt: cellTypeAt,
            ),
          );
          return updatedA!;
        }
        if (p.id == passengerBId) {
          final next = p.assignedSeats
              .where((a) => !(a.busId == bBusId && a.seatId == seatBId))
              .toList();
          for (var i = 0; i < berthsB; i++) {
            next.add(SeatAssignment(busId: busAId, seatId: seatAId));
          }
          updatedB = p.copyWith(
            assignedSeats: resolveAssignmentLegs(
              requestLines: p.requestLines,
              assigned: next,
              cellTypeAt: cellTypeAt,
            ),
          );
          return updatedB!;
        }
        final dropSeats = bumpBySeat[p.id];
        if (dropSeats != null && dropSeats.isNotEmpty) {
          final next = p.assignedSeats
              .where((a) => !dropSeats.contains('${a.busId}|${a.seatId}'))
              .toList();
          final u = p.copyWith(
            assignedSeats: resolveAssignmentLegs(
              requestLines: p.requestLines,
              assigned: next,
              cellTypeAt: cellTypeAt,
            ),
          );
          updatedBumped.add(u);
          return u;
        }
        return p;
      }).toList();
      return t.copyWith(passengers: newPassengers);
    });

    final a = updatedA;
    final b = updatedB;
    if (a == null || b == null) return;

    try {
      // Persist any bumped occupants first so the freed leg is real before the
      // incoming passenger lands on it.
      for (final u in updatedBumped) {
        await _sync.smartUpdate(
          table: 'passengers',
          entityId: u.id,
          data: u.toMap(),
        );
      }
      try {
        // Atomic: both rows move in one server transaction (no double-booked
        // berth window). DI-1.
        await _sync.swapPassengerSeats(
          passengerAId: passengerAId,
          seatsA: a.assignedSeats.map((s) => s.toMap()).toList(),
          passengerBId: passengerBId,
          seatsB: b.assignedSeats.map((s) => s.toMap()).toList(),
        );
      } on RpcUnavailableException {
        // Migration 011 not deployed yet — fall back to the two-step write.
        await _sync.smartUpdate(
          table: 'passengers',
          entityId: passengerAId,
          data: a.toMap(),
        );
        await _sync.smartUpdate(
          table: 'passengers',
          entityId: passengerBId,
          data: b.toMap(),
        );
      }
    } catch (e) {
      await refreshTours();
      AppSnackBar.error(
        tr('errors.swap_seats', namedArgs: {'e': '$e'}),
        title: tr('errors.swap_failed'),
      );
      rethrow;
    }

    // Both sides of a cross-bus swap change price band, and a bumped occupant
    // loses berths — re-price all three groups so nobody keeps a fare from a
    // bus they no longer sit on.
    await _reconcileMoneyAfterMove(
      tourId,
      [passengerAId, passengerBId, for (final u in updatedBumped) u.id],
      crossedBus: busAId != bBusId,
    );
  }
}
