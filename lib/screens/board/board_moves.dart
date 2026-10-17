part of 'board_screen.dart';

// Drag-to-move and tap-to-place relocate of [BoardScreen] (spec §7).
extension _BoardMoves on _BoardScreenState {
  // ── Moving a rider (spec §7) ────────────────────────────────
  //
  // Two gestures land here — a berth DRAGGED onto another berth, and a berth
  // TAPPED while somebody is held in hand by the relocate flow — and both are
  // resolved by the same two pieces the seat grid uses:
  //
  //  * [decideSeatDrop] says what a drop MEANS (move / peel a berth / share a
  //    sofa / swap / refuse, and why). It is pure, so the Board and the grid
  //    cannot drift into two different answers for one drop — which would show
  //    a green ring here on a drop the grid would refuse.
  //  * [SeatMoveFlow.moveTo] and [SeatSwapGuard.run] do the WRITE. Nothing on
  //    this screen touches `assignedSeats`: the flow owns the whole-double peel,
  //    the cross-bus group cascade confirm and the blocked-destination dialog,
  //    and the guard owns the "this over-books a leg — bump the one-leg
  //    occupant?" prompt. Every seat write in the app goes through one of them.
  //
  // Not gated on the tour lock: the lock is a CUSTOMER gate, and the agent
  // re-seating a locked tour on departure morning is the whole reason the Board
  // exists. That is exactly what the seat grid does (`enableDrag: true`).

  /// The layout cell for [seatId] on [bus]. Null when the bus has no plan, or
  /// when the seat is not on THIS bus — which is also the guard that keeps a
  /// callback captured for the page on screen from acting on another bus.
  SeatCell? _cellOf(Bus bus, String? seatId) {
    if (seatId == null || seatId.isEmpty) return null;
    for (final cell in bus.layout?.grid ?? const <SeatCell>[]) {
      if (cell.seatId == seatId) return cell;
    }
    return null;
  }

  /// The drop engine's view of whoever holds [seatId] on [bus].
  ///
  /// A port of the seat grid's `_occupantsOn` / `_occupantFor`, deliberately
  /// fact-for-fact: the engine tells a SUBSTITUTE whole-double (two singles
  /// parked on one sofa, splittable) from a genuine one by comparing the doubles
  /// held against the doubles requested, so dropping either of those two facts
  /// would quietly change what a drop does.
  List<SeatOccupant> _engineOccupants(Tour tour, Bus bus, String seatId) {
    final riders = occupantListForBus(tour.passengers, bus.id)[seatId];
    if (riders == null || riders.isEmpty) return const <SeatOccupant>[];
    return [for (final p in riders) _engineOccupant(bus, p, seatId)];
  }

  SeatOccupant _engineOccupant(Bus bus, Passenger p, String seatId) {
    final perCell = <String, int>{};
    for (final a in p.assignedSeats) {
      if (a.busId != bus.id) continue;
      perCell[a.seatId] = (perCell[a.seatId] ?? 0) + 1;
    }
    var wholeDoubles = 0;
    perCell.forEach((sid, n) {
      if (n < 2) return;
      if (_cellOf(bus, sid)?.seatType == SeatType.doubleSofa) wholeDoubles++;
    });
    final requestedDoubles = p.requestLines
        .where((l) => l.seatType == SeatType.doubleSofa)
        .fold<int>(0, (sum, l) => sum + l.qty);
    return (
      passengerId: p.id,
      // The PER-SEAT leg, never the rider's coarse `tripType`: the leg stamped
      // on the berth is canonical, and it is what decides whether a GO-only
      // rider may reuse a berth a RET-only rider already holds.
      trip: p.legForSeat(seatId, busId: bus.id),
      berthsHere: perCell[seatId] ?? 0,
      wholeDoublesHeld: wholeDoubles,
      requestedDoubleQty: requestedDoubles,
    );
  }

  /// What dropping [payload] on [target] would do. Null when either end cannot
  /// be resolved on this bus.
  SeatDropDecision? _decideDrop(
    Tour tour,
    Bus bus,
    BoardDragPayload payload,
    BoardBerthSlot target,
  ) {
    final fromSeatId = payload.fromSeatId;
    final fromCell = _cellOf(bus, fromSeatId);
    final targetCell = _cellOf(bus, target.seatId);
    if (fromSeatId == null || fromCell == null || targetCell == null) {
      return null;
    }
    final toSeatId = targetCell.seatId;
    if (toSeatId == null || toSeatId.isEmpty) return null;
    return decideSeatDrop(
      fromCell: (
        seatId: fromCell.seatId,
        seatType: fromCell.seatType,
        reserved: fromCell.reserved,
      ),
      targetCell: (
        seatId: toSeatId,
        seatType: targetCell.seatType,
        reserved: targetCell.reserved,
      ),
      fromOccupants: _engineOccupants(tour, bus, fromSeatId),
      targetOccupants: _engineOccupants(tour, bus, toSeatId),
    );
  }

  /// How many riders hold [seatId] on [bus] RIGHT NOW. The live roster, not the
  /// slot the tile was built from — see [_dropIsSupported] for why the
  /// difference matters at drop time.
  int _ridersOn(Tour tour, Bus bus, String? seatId) {
    if (seatId == null || seatId.isEmpty) return 0;
    return occupantListForBus(tour.passengers, bus.id)[seatId]?.length ?? 0;
  }

  /// Whether this verdict is one the Board can actually carry out, given that
  /// [sourceRiders] people hold the berth being dragged.
  ///
  /// Two doors, and the source count is the lock on both:
  ///
  ///  * The engine also answers for a SHARED source — move both sharers, swap
  ///    two sofas' full contents, ask which sharer peels off — and those need
  ///    writes ([TourController.moveSharedPair], [swapSeatContents]) that are
  ///    NOT behind the move flow or the swap guard.
  ///  * [SeatDropAction.fillPairInto] is the one verdict the engine returns for
  ///    a single-rider source AND for a two-rider one (seat_drop_engine.dart
  ///    :282 and :304 reach it from the shared-source branch). The Board's write
  ///    moves ONE rider, so on a shared source it would merge the first sharer
  ///    onto the target, leave the second behind, and announce the whole thing
  ///    as done. Refusing on the count rather than on the action is what makes
  ///    the guarantee hold for every verdict at once.
  ///
  /// [_canDragBerth] refuses to LIFT a shared berth, but it is read when the
  /// tile builds, whereas this is read at hover and at drop against a roster
  /// that realtime sync may have changed under the finger. That gap is exactly
  /// what this is here to cover.
  bool _dropIsSupported(SeatDropDecision decision, int sourceRiders) {
    if (sourceRiders != 1) return false;
    return switch (decision.action) {
      SeatDropAction.move ||
      SeatDropAction.splitToSingle ||
      SeatDropAction.fill ||
      SeatDropAction.swap ||
      SeatDropAction.fillPairInto => true,
      _ => false,
    };
  }

  /// Whether this berth can be picked up at all.
  bool _canDragBerth(Tour tour, Bus bus, BoardBerthSlot slot) {
    final seatId = slot.seatId;
    if (seatId == null || seatId.isEmpty) return false;
    // A held berth guards its occupant at the ORIGIN too — the grid refuses to
    // lift one (`_canDragSeat`) and so does this.
    if (slot.cell.reserved) return false;
    // EXACTLY one rider. [BoardDragPayload] carries a SEAT, not a person, so a
    // berth two people share — a split sofa, or a GO rider and a RET rider
    // reusing one berth — cannot say which of them the thumb picked up. The
    // grid resolves that with a "which sharer moves?" picker; the Board sends
    // them to the sheet instead of guessing.
    return _ridersOn(tour, bus, seatId) == 1;
  }

  bool _canDropOnBerth(
    Tour tour,
    Bus bus,
    BoardDragPayload payload,
    BoardBerthSlot target,
  ) {
    // Berth→berth only. The Board has no rail to drag an unseated rider from
    // (that is the seat grid's dock), so a rail payload has no meaning here.
    if (!payload.isBerthMove) return false;
    final decision = _decideDrop(tour, bus, payload, target);
    if (decision == null || !decision.isValid) return false;
    return _dropIsSupported(
      decision,
      _ridersOn(tour, bus, payload.fromSeatId),
    );
  }

  /// A released drop. Dispatches the engine's verdict through the guarded write
  /// paths and reports what actually happened — never "moved" on a move that was
  /// refused, which on a locked tour is how a family ends up at the wrong bus.
  Future<void> _handleDrop(
    Tour tour,
    Bus bus,
    BoardDragPayload payload,
    BoardBerthSlot target,
  ) async {
    final decision = _decideDrop(tour, bus, payload, target);
    final fromSeatId = payload.fromSeatId;
    final toSeatId = target.seatId;
    if (decision == null || fromSeatId == null || toSeatId == null) return;

    // The roster as it stands at the RELEASE, which is the only reading the
    // write is entitled to act on. `canDrop` painted the ring from the roster a
    // moment earlier; this is the same question asked again at the last instant,
    // so a sync that landed mid-drag can still veto the write.
    final occupants = occupantListForBus(tour.passengers, bus.id);
    final riders = occupants[fromSeatId] ?? const <Passenger>[];
    if (!decision.isValid || !_dropIsSupported(decision, riders.length)) return;

    final mover = riders.firstOrNull;
    if (mover == null) return;
    final sitting = (occupants[toSeatId] ?? const <Passenger>[]).firstOrNull;

    switch (decision.action) {
      case SeatDropAction.swap:
        if (sitting == null) return;
        await SeatSwapGuard.run(
          context,
          tourId: tour.id,
          busAId: bus.id,
          passengerAId: mover.id,
          seatAId: fromSeatId,
          passengerBId: sitting.id,
          seatBId: toSeatId,
          busBId: bus.id,
        );
        if (!mounted || !_holdsBerth(mover.id, bus.id, toSeatId)) return;
        AppSnackBar.success(
          tr(
            'tour_seat_assignment.drop.swapped_body',
            namedArgs: {'a': mover.displayName, 'b': sitting.displayName},
          ),
          title: tr('tour_seat_assignment.drop.swapped_title'),
        );

      case SeatDropAction.fill:
        // Sharing a sofa with a stranger is asked for, never assumed — the same
        // confirm the grid puts in front of the identical drop.
        if (sitting == null) return;
        final shared = await UgamDialog.confirm(
          context,
          title: tr('tour_seat_assignment.share_confirm_title'),
          message: tr(
            'tour_seat_assignment.share_confirm_body',
            namedArgs: {
              'seat': toSeatId,
              'otherName': sitting.displayName,
              'currentName': mover.displayName,
            },
          ),
          confirmLabel: tr('tour_seat_assignment.share_confirm_yes'),
        );
        if (!shared || !mounted) return;
        await _writeMove(
          tour: tour,
          bus: bus,
          mover: mover,
          fromSeatId: fromSeatId,
          toSeatId: toSeatId,
          success: tr(
            'tour_seat_assignment.drop.filled_body',
            namedArgs: {
              'a': mover.displayName,
              'b': sitting.displayName,
              'seat': toSeatId,
            },
          ),
          successTitle: tr('tour_seat_assignment.drop.filled_title'),
        );

      // move / splitToSingle / fillPairInto are one write with three readings:
      // the flow moves every berth the mover holds on the source cell, capping
      // at what the target can take — which IS the peel a `splitToSingle` means.
      case SeatDropAction.splitToSingle:
        await _writeMove(
          tour: tour,
          bus: bus,
          mover: mover,
          fromSeatId: fromSeatId,
          toSeatId: toSeatId,
          success: tr(
            'tour_seat_assignment.drop.split_body',
            namedArgs: {'name': mover.displayName, 'seat': toSeatId},
          ),
          successTitle: tr('tour_seat_assignment.drop.split_title'),
        );

      case SeatDropAction.move:
      case SeatDropAction.fillPairInto:
        await _writeMove(
          tour: tour,
          bus: bus,
          mover: mover,
          fromSeatId: fromSeatId,
          toSeatId: toSeatId,
          success: tr(
            'tour_seat_assignment.drop.moved_body',
            namedArgs: {'name': mover.displayName, 'seat': toSeatId},
          ),
          successTitle: tr('tour_seat_assignment.drop.moved_title'),
        );

      // Unreachable: _dropIsSupported refused these before the write.
      case SeatDropAction.moveBoth:
      case SeatDropAction.swapPair:
      case SeatDropAction.splitPairChoice:
      case SeatDropAction.blocked:
        return;
    }
  }

  /// The ONE seat-move write on this screen. Reports the outcome honestly: a
  /// group the destination could not fit, or a confirm the agent backed out of,
  /// says nothing rather than claiming a move that never happened.
  Future<SeatMoveOutcome> _writeMove({
    required Tour tour,
    required Bus bus,
    required Passenger mover,
    required String fromSeatId,
    required String toSeatId,
    required String success,
    String? successTitle,
  }) async {
    final outcome = await SeatMoveFlow.moveTo(
      context,
      tourId: tour.id,
      sourceBusId: bus.id,
      mover: mover,
      fromSeatId: fromSeatId,
      destination: bus,
      toSeatId: toSeatId,
    );
    if (!mounted) return outcome;
    switch (outcome) {
      // The reason is already on screen (the flow's blocked dialog), or the
      // agent cancelled — either way, nothing to announce.
      case SeatMoveOutcome.failed:
      case SeatMoveOutcome.cancelled:
        break;
      case SeatMoveOutcome.groupReseated:
        AppSnackBar.info(
          tr(
            'tour_seat_assignment.relocate.group_moved',
            namedArgs: {
              'name': mover.displayName,
              'bus': bus.customerLabel,
              'seat': toSeatId,
            },
          ),
        );
      case SeatMoveOutcome.moved:
        AppSnackBar.success(success, title: successTitle);
    }
    return outcome;
  }

  /// Does [passengerId] hold [seatId] on [busId] RIGHT NOW?
  ///
  /// This is how a swap is confirmed to have happened. [SeatSwapGuard.run]
  /// returns nothing, and it can end in a confirm the agent backs out of (the
  /// "this over-books a leg — bump the occupant?" prompt), so announcing a swap
  /// on the strength of the call having returned is how the grid comes to report
  /// an exchange that never took place. The roster is the only witness.
  bool _holdsBerth(String passengerId, String busId, String seatId) {
    final rider = _tour?.passengers.firstWhereOrNull((p) => p.id == passengerId);
    return rider?.assignedSeats.any(
          (a) => a.busId == busId && a.seatId == seatId,
        ) ??
        false;
  }

  /// A refused drop. Spec §7: never a silent failure — the canvas has already
  /// flashed the berth and buzzed the "no", and this names the reason.
  void _explainRefusedDrop(
    Tour tour,
    Bus bus,
    BoardDragPayload payload,
    BoardBerthSlot target,
  ) {
    final decision = _decideDrop(tour, bus, payload, target);
    final seat = target.seatId ?? target.berth.code;
    final fromSeatId = payload.fromSeatId;
    _toastRefused(
      decision?.block,
      name: payload.label,
      seat: seat,
      sourceIsSeater: _cellOf(bus, fromSeatId)?.seatType == SeatType.seater,
      moverTrip: fromSeatId == null
          ? null
          : _engineOccupants(tour, bus, fromSeatId).firstOrNull?.trip,
    );
  }

  /// The refusal, in words. Same reasons and same strings as the grid's
  /// `_toastBlocked`, so one drop never gets two different explanations
  /// depending on which surface the agent happened to be on.
  void _toastRefused(
    SeatDropBlock? block, {
    required String name,
    required String seat,
    required bool sourceIsSeater,
    TripType? moverTrip,
  }) {
    switch (block) {
      case SeatDropBlock.self:
        return;
      case SeatDropBlock.classMismatch:
        AppSnackBar.warning(
          tr(
            sourceIsSeater
                ? 'tour_seat_assignment.drop.class_mismatch_seater'
                : 'tour_seat_assignment.drop.class_mismatch_sleeper',
          ),
          title: tr('tour_seat_assignment.drop.class_mismatch_title'),
        );
      case SeatDropBlock.tooSmall:
        AppSnackBar.warning(
          tr(
            'tour_seat_assignment.drop.too_small_body',
            namedArgs: {'name': name},
          ),
          title: tr('tour_seat_assignment.drop.too_small_title'),
        );
      case SeatDropBlock.held:
        AppSnackBar.warning(
          tr('tour_seat_assignment.drop.held_body', namedArgs: {'seat': seat}),
          title: tr('tour_seat_assignment.drop.held_title'),
        );
      case SeatDropBlock.sharedTargetAmbiguous:
        AppSnackBar.info(
          tr('tour_seat_assignment.drop.shared_body'),
          title: tr('tour_seat_assignment.drop.shared_title'),
        );
      case SeatDropBlock.sharedNeedsFreeDouble:
        AppSnackBar.info(
          tr('tour_seat_assignment.drop.shared_need_free_double'),
          title: tr('tour_seat_assignment.drop.shared_title'),
        );
      case SeatDropBlock.noLegRoom:
        // Name the SPECIFIC leg for a one-way rider: "already full" is only
        // useful if the agent knows which half of the trip clashed.
        final leg = switch (moverTrip) {
          final t? when t.usesOutbound && !t.usesReturn =>
            'tour_seat_assignment.drop.leg_go',
          final t? when t.usesReturn && !t.usesOutbound =>
            'tour_seat_assignment.drop.leg_ret',
          _ => 'tour_seat_assignment.drop.leg_both',
        };
        AppSnackBar.warning(
          tr(
            'tour_seat_assignment.drop.no_leg_room_body',
            namedArgs: {'seat': seat, 'leg': tr(leg)},
          ),
          title: tr('tour_seat_assignment.drop.no_leg_room_title'),
        );
      // `neutral` (not a real seat) and a verdict the Board cannot carry out
      // both land here. Still a sentence, still names the way out — a shrug is
      // the one answer spec §7 forbids.
      case SeatDropBlock.neutral:
      case null:
        AppSnackBar.info(
          tr(
            'board_screen.drop_unsupported',
            namedArgs: {'name': name, 'seat': seat},
          ),
          title: tr('tour_seat_assignment.drop.blocked_title'),
        );
    }
  }

  // ── Tap-to-place relocate (spec §7) ─────────────────────────

  /// Swing the Board to [destination] and hold [mover] in hand.
  ///
  /// Called by [SeatMoveFlow.start] INSTEAD of its auto swap-assistant, which is
  /// a flat list of free-seat codes: on a screen built so the agent can read the
  /// bus, picking a berth off a list is the one interaction that throws the bus
  /// away. Mirrors the seat grid's `_beginRelocate`.
  void _beginRelocate(
    Bus destination,
    Passenger mover,
    String sourceBusId,
    String fromSeatId,
  ) {
    final index =
        _tour?.buses.indexWhere((b) => b.id == destination.id) ?? -1;
    // Written OUTSIDE build (a callback), so the enclosing Obx is free to be
    // marked dirty by it — see the note at the top of build().
    if (index >= 0) _board.setBusIndex(index);
    _update(() {
      _relocate = (
        mover: mover,
        fromBusId: sourceBusId,
        fromSeatId: fromSeatId,
      );
    });
    AppSnackBar.info(
      tr(
        'tour_seat_assignment.relocate.started',
        namedArgs: {
          'name': mover.displayName,
          'bus': destination.customerLabel,
        },
      ),
    );
  }

  void _cancelRelocate() {
    if (_relocate == null) return;
    _update(() => _relocate = null);
  }

  /// A berth was tapped while somebody is in hand: a free berth MOVES them, an
  /// occupied one SWAPS them with its occupant.
  Future<void> _relocateOnto(Tour tour, Bus bus, BoardBerthSlot slot) async {
    final reloc = _relocate;
    final seatId = slot.seatId;
    if (reloc == null || seatId == null || seatId.isEmpty) return;
    // Re-read the mover from the live roster: the sheet handed them over some
    // taps ago and their seats may have moved since.
    final mover =
        tour.passengers.firstWhereOrNull((p) => p.id == reloc.mover.id) ??
        reloc.mover;

    final riders =
        occupantListForBus(tour.passengers, bus.id)[seatId] ??
        const <Passenger>[];
    final others = riders.where((p) => p.id != mover.id).toList();
    // Their own berth. Nothing to do, and nothing wrong — a tap that lands home
    // is how an agent checks they picked up the right person.
    if (others.isEmpty && riders.isNotEmpty) return;

    if (others.isEmpty) {
      await _relocateOntoFree(tour, bus, mover, reloc, seatId);
      return;
    }
    if (others.length > 1) {
      // Which of the two would the mover be swapping with? The grid asks; the
      // Board sends them somewhere that can.
      AppSnackBar.info(
        tr(
          'board_screen.drop_unsupported',
          namedArgs: {'name': mover.displayName, 'seat': seatId},
        ),
        title: tr('tour_seat_assignment.drop.blocked_title'),
      );
      return;
    }
    await _relocateSwap(tour, bus, mover, reloc, others.first, seatId);
  }

  Future<void> _relocateOntoFree(
    Tour tour,
    Bus bus,
    Passenger mover,
    ({Passenger mover, String fromBusId, String fromSeatId}) reloc,
    String seatId,
  ) async {
    final confirmed = await UgamDialog.confirm(
      context,
      title: tr('tour_seat_assignment.relocate.move_confirm_title'),
      message: tr(
        'tour_seat_assignment.relocate.move_confirm_body',
        namedArgs: {
          'name': mover.displayName,
          'seat': seatId,
          'bus': bus.customerLabel,
        },
      ),
      confirmLabel: tr('tour_seat_assignment.relocate.move_confirm_yes'),
    );
    if (!confirmed || !mounted) return;

    final outcome = await SeatMoveFlow.moveTo(
      context,
      tourId: tour.id,
      // The SOURCE bus, which on a cross-bus relocate is not the bus on screen.
      sourceBusId: reloc.fromBusId,
      mover: mover,
      fromSeatId: reloc.fromSeatId,
      destination: bus,
      toSeatId: seatId,
    );
    if (!mounted) return;
    _finishRelocate(outcome, mover: mover, bus: bus, seatId: seatId);
  }

  Future<void> _relocateSwap(
    Tour tour,
    Bus bus,
    Passenger mover,
    ({Passenger mover, String fromBusId, String fromSeatId}) reloc,
    Passenger other,
    String seatId,
  ) async {
    final confirmed = await UgamDialog.confirm(
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
    if (!confirmed || !mounted) return;

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
    // Same witness as the drag path: a guard the agent backed out of leaves the
    // mover exactly where they were, and the banner must stay up so the next tap
    // can try somewhere else.
    if (!mounted || !_holdsBerth(mover.id, bus.id, seatId)) return;
    _update(() => _relocate = null);
    AppSnackBar.success(
      tr(
        'tour_seat_assignment.relocate.swapped',
        namedArgs: {'mover': mover.displayName, 'other': other.displayName},
      ),
    );
  }

  /// Close out a relocate by what the move ACTUALLY did.
  ///
  /// The banner is the agent's "you are still holding someone" indicator, so it
  /// comes down only when somebody really moved: a refusal leaves it up (the
  /// reason is already on screen) so the next tap can try another berth, and a
  /// group cascade says plainly that the berth they tapped was not the one used.
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
              'bus': bus.customerLabel,
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
}
