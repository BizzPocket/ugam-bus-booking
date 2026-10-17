part of '../tour_seat_assignment_screen.dart';

// Cross-bus relocate + the shared placement path ([_placeBerths]) of
// [TourSeatAssignmentScreen].
extension _RelocateFlow on _TourSeatAssignmentScreenState {
  // ── Cross-bus relocate (tap-to-place hand-off) ──────────────────────────
  //
  // The move flow's destination picker calls [_beginRelocate] instead of the
  // auto swap-assistant: the chart switches to the chosen bus and the mover is
  // held "in hand". The next seat tap then MOVES them onto a free seat (after a
  // confirm) or SWAPS them with an occupant — using the cross-bus
  // [TourController.moveSeat] / [swapSeats] under the hood.

  /// Switch the chart to [destination] and enter relocate mode for [mover]
  /// (remembering the seat they currently sit on so the move/swap can be
  /// applied). Triggered from the occupant sheet's "move or swap" → bus picker.
  void _beginRelocate(
    Bus destination,
    Passenger mover,
    String sourceBusId,
    String fromSeatId,
  ) {
    _update(() {
      _selectedBusId = destination.id;
      _selectedPassengerId = mover.id;
      _relocate = (
        mover: mover,
        fromBusId: sourceBusId,
        fromSeatId: fromSeatId,
      );
    });
    AppSnackBar.info(
      tr(
        'tour_seat_assignment.relocate.started',
        namedArgs: {'name': mover.displayName, 'bus': destination.name},
      ),
    );
  }

  void _cancelRelocate() {
    if (_relocate == null) return;
    _update(() => _relocate = null);
  }

  /// A seat was tapped while a relocate is in progress. Route to a move (free
  /// seat) or a swap (occupied seat).
  void _onRelocateSeatTapped(SeatCell cell, Bus bus, Tour tour) {
    final reloc = _relocate;
    if (reloc == null) return;
    final mover =
        tour.passengers.firstWhereOrNull((p) => p.id == reloc.mover.id) ??
        reloc.mover;

    final owners =
        (_assignmentMap(tour, bus.id)[cell.seatId] ?? const <String>[])
            .toList();
    final others = owners.where((id) => id != mover.id).toList();

    // The mover's OWN seat (same-bus tap) — nothing to do.
    if (others.isEmpty && owners.isNotEmpty) return;

    if (others.isNotEmpty) {
      _relocateOntoOccupied(cell, bus, tour, mover, reloc, others);
    } else {
      _relocateOntoFree(cell, bus, tour, mover, reloc);
    }
  }

  /// Berths [mover] holds on their source cell — 2 for a whole double, else 1.
  int _relocateMoverBerths(
    ({Passenger mover, String fromBusId, String fromSeatId}) reloc,
    Passenger mover,
  ) {
    return mover.assignedSeats
        .where(
          (a) => a.busId == reloc.fromBusId && a.seatId == reloc.fromSeatId,
        )
        .length;
  }

  /// Move [mover] onto a FREE [cell] of [bus] after a confirm.
  ///
  /// The write goes through [SeatMoveFlow.moveTo] rather than
  /// [TourController.moveSeat] directly, so this tap-to-place path inherits the
  /// SAME guards the board's move flow has always had: the whole-double seat-size
  /// cap, the "move whole group (N people)?" confirm, and the blocked dialog
  /// naming why a destination cannot take the party. It also gets back what
  /// actually happened — previously the grid announced "moved" and dismissed the
  /// banner unconditionally, so a group the destination could not fit reported
  /// success while nobody moved. On a locked tour that means the family is never
  /// re-notified and shows up at the wrong bus.
  Future<void> _relocateOntoFree(
    SeatCell cell,
    Bus bus,
    Tour tour,
    Passenger mover,
    ({Passenger mover, String fromBusId, String fromSeatId}) reloc,
  ) async {
    final seatId = cell.seatId;
    if (seatId == null) return;
    final moverBerths = _relocateMoverBerths(reloc, mover);

    // Dropping ONE single berth onto a FREE Double Sofa, and the passenger holds
    // another single elsewhere on this bus? Offer to pair BOTH singles onto the
    // double (a double seats two) or just this one. This choice dialog doubles
    // as the move confirmation.
    if (cell.seatType == SeatType.doubleSofa && moverBerths == 1) {
      final otherSeatId = _otherSingleSeatId(tour, bus, mover, reloc.fromSeatId);
      if (otherSeatId != null) {
        final both = await _askMoveBothOrOne(seatId: seatId, name: mover.displayName);
        if (both == null) return; // cancelled
        if (!mounted) return;
        final outcome = await SeatMoveFlow.moveTo(
          context,
          tourId: tour.id,
          sourceBusId: reloc.fromBusId,
          mover: mover,
          fromSeatId: reloc.fromSeatId,
          destination: bus,
          toSeatId: seatId,
        );
        // Only chase the second single when the first berth actually landed on
        // the seat that was picked. A refused move has nothing to pair, and a
        // group cascade already re-seated everyone at berths of its own.
        if (both && outcome == SeatMoveOutcome.moved) {
          await _ctrl.moveSeat(
            tourId: tour.id,
            passengerId: mover.id,
            busId: bus.id,
            fromSeatId: otherSeatId,
            toSeatId: seatId,
            toBusId: bus.id,
          );
        }
        if (!mounted) return;
        _finishRelocate(outcome, mover: mover, bus: bus, seatId: seatId);
        return;
      }
    }

    final confirmed = await _confirmSheet(
      context,
      title: tr('tour_seat_assignment.relocate.move_confirm_title'),
      message: tr(
        'tour_seat_assignment.relocate.move_confirm_body',
        namedArgs: {'name': mover.displayName, 'seat': seatId, 'bus': bus.name},
      ),
      confirmLabel: tr('tour_seat_assignment.relocate.move_confirm_yes'),
    );
    if (!confirmed) return;
    if (!mounted) return;

    final outcome = await SeatMoveFlow.moveTo(
      context,
      tourId: tour.id,
      sourceBusId: reloc.fromBusId,
      mover: mover,
      fromSeatId: reloc.fromSeatId,
      destination: bus,
      toSeatId: seatId,
    );
    if (!mounted) return;
    _finishRelocate(outcome, mover: mover, bus: bus, seatId: seatId);
  }

  /// Close out a relocate according to what the move actually did.
  ///
  /// The banner is the operator's "still holding someone" indicator, so it is
  /// dismissed ONLY when somebody really moved. A refusal leaves it up (with the
  /// reason already on screen from the move flow) so the next tap can try a
  /// different seat or bus, and a group cascade says plainly that the tapped
  /// seat was not the seat used.
  void _finishRelocate(
    SeatMoveOutcome outcome, {
    required Passenger mover,
    required Bus bus,
    required String seatId,
  }) {
    switch (outcome) {
      case SeatMoveOutcome.failed:
      case SeatMoveOutcome.cancelled:
        return;
      case SeatMoveOutcome.groupReseated:
        _update(() => _relocate = null);
        AppSnackBar.info(
          tr(
            'tour_seat_assignment.relocate.group_moved',
            namedArgs: {
              'name': mover.displayName,
              'bus': bus.name,
              'seat': seatId,
            },
          ),
        );
      case SeatMoveOutcome.moved:
        _update(() => _relocate = null);
        AppSnackBar.success(
          tr(
            'tour_seat_assignment.relocate.moved',
            namedArgs: {'name': mover.displayName, 'seat': seatId},
          ),
        );
    }
  }

  /// The seatId of ANOTHER single-sofa berth [mover] holds on [bus] (other than
  /// [fromSeatId]) — the pairing candidate when a single is dropped onto a free
  /// double. Null when the passenger has no second single on this bus.
  String? _otherSingleSeatId(
    Tour tour,
    Bus bus,
    Passenger mover,
    String fromSeatId,
  ) {
    for (final a in mover.assignedSeats) {
      if (a.busId != bus.id) continue;
      if (a.seatId == fromSeatId) continue;
      if (_findCell(tour, bus.id, a.seatId)?.seatType == SeatType.singleSofa) {
        return a.seatId;
      }
    }
    return null;
  }

  /// Ask whether to move BOTH of the passenger's singles onto the double, or
  /// just the dragged one. true = both, false = just this one, null = cancelled.
  Future<bool?> _askMoveBothOrOne({
    required String seatId,
    required String name,
  }) {
    final c = UgamColors.of(context);
    return UgamSheet.show<bool>(
      context,
      title: tr('tour_seat_assignment.relocate.pair_title'),
      builder: (sheetCtx) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            tr(
              'tour_seat_assignment.relocate.pair_body',
              namedArgs: {'name': name, 'seat': seatId},
            ),
            style: UgamText.body.copyWith(color: c.ink2, height: 1.4),
          ),
          const SizedBox(height: UgamSpacing.xl),
          // Two stacked full-width tonal choices — neither is "the" primary, so
          // both stay tonal (gold stays rationed); the agent picks intent.
          UgamButton(
            kind: UgamButtonKind.tonal,
            label: tr('tour_seat_assignment.relocate.pair_both'),
            icon: Icons.group_add_rounded,
            expand: true,
            onPressed: () => Navigator.of(sheetCtx).pop(true),
          ),
          const SizedBox(height: UgamSpacing.sm),
          UgamButton(
            kind: UgamButtonKind.tonal,
            label: tr('tour_seat_assignment.relocate.pair_one'),
            icon: Icons.person_rounded,
            expand: true,
            onPressed: () => Navigator.of(sheetCtx).pop(false),
          ),
        ],
      ),
    );
  }

  /// An occupied seat was tapped while relocating: open the full occupant menu
  /// (manage the occupant) with a "seat [mover] here" action that SWAPS the
  /// mover with the occupant (after a confirm).
  void _relocateOntoOccupied(
    SeatCell cell,
    Bus bus,
    Tour tour,
    Passenger mover,
    ({Passenger mover, String fromBusId, String fromSeatId}) reloc,
    List<String> ownerIds,
  ) {
    final byId = {for (final p in tour.passengers) p.id: p};
    final occupants = <Passenger>[
      for (final id in ownerIds)
        if (byId[id] != null) byId[id]!,
    ];
    if (occupants.isEmpty) return;

    OccupantActionSheet.show(
      context,
      occupants: occupants,
      tourId: tour.id,
      busId: bus.id,
      seatId: cell.seatId!,
      busName: bus.name,
      // "Seat [mover] here" → swap the mover with this occupant.
      placing: mover,
      onSeatHere: () =>
          _relocateSwap(cell, bus, tour, mover, reloc, occupants.first),
    );
  }

  /// Swap [mover] (on their source seat) with [other] (on the tapped [cell]),
  /// across buses, after a confirm.
  Future<void> _relocateSwap(
    SeatCell cell,
    Bus bus,
    Tour tour,
    Passenger mover,
    ({Passenger mover, String fromBusId, String fromSeatId}) reloc,
    Passenger other,
  ) async {
    final seatId = cell.seatId;
    if (seatId == null) return;
    final confirmed = await _confirmSheet(
      context,
      title: tr('tour_seat_assignment.relocate.swap_confirm_title'),
      message: tr(
        'tour_seat_assignment.relocate.swap_confirm_body',
        namedArgs: {
          'mover': mover.displayName,
          'other': other.displayName,
          'seat': seatId,
        },
      ),
      confirmLabel: tr('tour_seat_assignment.relocate.swap_confirm_yes'),
    );
    if (!confirmed) return;
    if (!mounted) return;

    await SeatSwapGuard.run(
      context,
      tourId: tour.id,
      busAId: reloc.fromBusId,
      passengerAId: mover.id,
      seatAId: reloc.fromSeatId,
      passengerBId: other.id,
      seatBId: seatId,
      busBId: bus.id,
    );
    if (!mounted) return;
    _update(() => _relocate = null);
    AppSnackBar.success(
      tr(
        'tour_seat_assignment.relocate.swapped',
        namedArgs: {'mover': mover.displayName, 'other': other.displayName},
      ),
    );
  }

  /// Berths the mid-placement [active] passenger could take on an ALREADY-
  /// occupied [cell] — 0 when no compatible, leg-free room exists. Covers two
  /// cases through one rule:
  ///   * SAME-leg share of a Double Sofa (two singles split the two berths);
  ///   * leg-DISJOINT reuse — an outbound-only seat reused by a return-only
  ///     rider (or vice-versa), so the SAME sofa serves GO and RETURN.
  ///
  /// Capacity is tracked PER LEG: the cell holds [cap] berths on the GO leg and
  /// [cap] on the RETURN leg independently. A one-way occupant fills only its
  /// own leg, leaving the other leg free for an opposite-leg rider; a round-trip
  /// occupant fills BOTH legs and blocks any reuse.
  int _seatHereBerths(
    Tour tour,
    Bus bus,
    SeatCell cell,
    Passenger active,
    List<Passenger> occupants,
  ) {
    final seatId = cell.seatId;
    if (seatId == null) return 0;

    // Build the real per-leg holders on this cell, then defer to the SAME
    // shared rule the free-cell path uses. This unifies "share onto occupied"
    // and "place on free" into one type/position + per-leg gate (symptoms B/C).
    final holders = <SeatLegHolder>[
      for (final o in occupants)
        (
          // Per-SEAT leg (a.leg ?? tripType), NOT the coarse overall trip: a
          // rider who holds THIS seat on only one leg leaves the other leg free
          // to share. Reading o.tripType wrongly treated a mixed-leg rider
          // (stored roundTrip) as occupying BOTH legs and refused the share —
          // aligns this with seat_render, amountDueForSeat and the capacity
          // engine, which all resolve per-seat via legForSeat.
          trip: o.legForSeat(seatId, busId: bus.id),
          berths: o.assignedSeats
              .where((a) => a.busId == bus.id && a.seatId == seatId)
              .length,
        ),
    ];

    return _berthsForCell(active, cell, holders, tour: tour);
  }

  /// Confirm + seat [passenger] onto the already-occupied [cell] — either
  /// sharing a Double Sofa half or reusing the seat on the opposite leg from
  /// [other]. Places [berths] berths (1 for a half/single, 2 for a whole-double
  /// reuse).
  Future<void> _seatHere(
    Passenger passenger,
    Bus bus,
    Tour tour,
    SeatCell cell,
    Passenger other,
    int berths,
  ) async {
    final confirmed = await _confirmSheet(
      context,
      title: tr('tour_seat_assignment.share_confirm_title'),
      message: tr(
        'tour_seat_assignment.share_confirm_body',
        namedArgs: {
          'seat': cell.seatId!,
          'otherName': other.displayName,
          'currentName': passenger.displayName,
        },
      ),
      confirmLabel: tr('tour_seat_assignment.share_confirm_yes'),
    );
    if (!confirmed) return;
    await _placeBerths(passenger, bus, tour, cell, berths);
  }

  /// True when trips [a] and [b] both ride the SAME physical leg — so they
  /// genuinely compete for one berth (vs a GO-only + RET-only pair that can
  /// share a single seat across disjoint legs).
  bool _tripsOverlap(TripType a, TripType b) =>
      (a.usesOutbound && b.usesOutbound) || (a.usesReturn && b.usesReturn);

  /// The single occupant whose leg collides with [active]'s — the one a swap
  /// must bump so [active] can take the berth. Returns null when the collision
  /// is ambiguous (two occupants both overlap, e.g. a round-trip rider onto a
  /// GO+RET leg-shared seat) so we never guess and overbook.
  Passenger? _conflictingOccupant(
    Passenger active,
    List<Passenger> occupants,
    String seatId,
    String busId,
  ) {
    final overlap = occupants
        .where((o) => _tripsOverlap(
            o.legForSeat(seatId, busId: busId), active.effectiveTripType))
        .toList();
    if (overlap.length == 1) return overlap.first;
    if (overlap.isEmpty && occupants.length == 1) return occupants.first;
    return null;
  }

  /// Swap [placing] INTO an occupied [cell] by freeing the leg-conflicting
  /// [occupant] (they return to the pending pool, ready to re-seat) and then
  /// seating [placing] on the [berths] that opens up. Used when the seat is full
  /// on [placing]'s leg so a plain share isn't possible — turning the old
  /// dead-end "no room on this leg" into an actionable swap.
  Future<void> _swapInPlacing(
    Passenger placing,
    Bus bus,
    Tour tour,
    SeatCell cell,
    Passenger occupant,
    int berths,
  ) async {
    final seatId = cell.seatId;
    if (seatId == null) return;
    final confirmed = await _confirmSheet(
      context,
      title: tr('tour_seat_assignment.swap_in_confirm_title'),
      message: tr(
        'tour_seat_assignment.swap_in_confirm_body',
        namedArgs: {
          'placing': placing.displayName,
          'occupant': occupant.displayName,
          'seat': seatId,
        },
      ),
      confirmLabel: tr('tour_seat_assignment.swap_in_confirm_yes'),
    );
    if (!confirmed) return;

    // 1. Free the conflicting occupant's berth(s) on THIS seat only — they keep
    //    their request and drop back into the pending pool.
    final occNext = occupant.assignedSeats
        .where((a) => !(a.busId == bus.id && a.seatId == seatId))
        .toList();
    await _ctrl.assignSeats(tour.id, occupant.id, occNext);

    // 2. Seat the placing passenger on the freed berth(s).
    final freshTour = _ctrl.getTour(tour.id) ?? tour;
    await _placeBerths(placing, bus, freshTour, cell, berths);
  }

  /// Add [berths] berths of [cell] to [passenger], persist, then auto-advance
  /// to the next unassigned passenger when this one is fully seated.
  Future<void> _placeBerths(
    Passenger passenger,
    Bus bus,
    Tour tour,
    SeatCell cell,
    int berths,
  ) async {
    // Hard block over-allocation: a rider may never be assigned MORE berths than
    // requested. Every placement path (free-cell tap, seat-here share, swap-in,
    // seat picker) funnels through here, so this single guard caps them all —
    // e.g. a 2-berth double request can't grab a single + a whole double (3).
    final remaining = passenger.remainingBerths;
    if (berths > remaining) {
      AppSnackBar.warning(
        tr(
          'tour_seat_assignment.over_allocate_body',
          namedArgs: {
            'passengerName': passenger.displayName,
            'remaining': '$remaining',
          },
        ),
        title: tr('tour_seat_assignment.over_allocate_title'),
      );
      return;
    }

    final next = List<SeatAssignment>.from(passenger.assignedSeats);
    for (var i = 0; i < berths; i++) {
      next.add(SeatAssignment(busId: bus.id, seatId: cell.seatId!));
    }
    await _ctrl.assignSeats(tour.id, passenger.id, next);

    final updatedTour = _ctrl.getTour(tour.id);
    final updatedPassenger = updatedTour?.passengers.firstWhere(
      (p) => p.id == passenger.id,
      orElse: () => passenger,
    );

    if (updatedPassenger != null && updatedPassenger.isFullyAssigned) {
      AppSnackBar.success(
        tr(
          'tour_seat_assignment.snack_fully_assigned_body',
          namedArgs: {'passengerName': passenger.displayName},
        ),
        title: tr('tour_seat_assignment.snack_fully_assigned_title'),
      );
      HapticFeedback.lightImpact();

      final nextUnassigned = updatedTour!.passengers
          .where((p) => !p.isFullyAssigned && !p.journeyDone)
          .toList();
      if (nextUnassigned.isNotEmpty) {
        _update(() => _selectedPassengerId = nextUnassigned.first.id);
      } else if (updatedTour.handlerId != null) {
        AppSnackBar.success(
          tr('tour_seat_assignment.snack_all_done_body'),
          title: tr('tour_seat_assignment.snack_all_done_title'),
        );
      } else {
        AppSnackBar.warning(tr('tour_seat_assignment.snack_no_handler'));
      }
    } else {
      AppSnackBar.success(
        tr(
          'tour_seat_assignment.snack_seat_saved',
          namedArgs: {'seatId': cell.seatId!},
        ),
      );
      HapticFeedback.lightImpact();
    }
  }
}
