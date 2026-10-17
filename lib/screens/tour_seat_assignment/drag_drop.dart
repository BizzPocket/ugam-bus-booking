part of '../tour_seat_assignment_screen.dart';

// Drag-to-move / swap / share / split on the [TourSeatAssignmentScreen]
// chart.
extension _DragDropFlow on _TourSeatAssignmentScreenState {
  // ── Drag-to-move / swap / share / split ─────────────────────────────────
  //
  // The canonical [CombinedSeatGrid] owns the gesture; this screen feeds the
  // pure [decideSeatDrop] engine and dispatches its verdict. A seat is pickable
  // when it holds ONE occupant (a normal drag) OR TWO (a shared double that
  // moves as a unit). On release the engine returns move / split / swap / fill /
  // moveBoth / blocked, and the same call drives the live highlight — so what
  // the agent SEES is exactly what a drop will DO. Every drag stays SAME-BUS, so
  // groups are never split; the controller still routes through the group-safe
  // [moveSeat] / [swapSeats] / [moveSharedPair] paths.

  /// The occupants on [cell] of the selected bus, as engine [SeatOccupant]s.
  /// Empty for an empty/aisle cell; one entry for a sole occupant; two for a
  /// shared double (or a leg-disjoint reuse).
  List<SeatOccupant> _occupantsOn(
    Tour tour,
    Bus bus,
    SeatCell cell, {
    String? onlyOccupantId,
  }) {
    final seatId = cell.seatId;
    if (seatId == null) return const [];
    final ids = _assignmentMap(tour, bus.id)[seatId] ?? const <String>[];
    final seen = <String>{};
    final out = <SeatOccupant>[];
    for (final id in ids) {
      if (!seen.add(id)) continue;
      // DRAG-THE-PERSON: when a single sharer of a shared double was grabbed,
      // narrow the SOURCE occupants to just them so the engine's normal 1-berth
      // move / fill / swap path runs and the partner stays put.
      if (onlyOccupantId != null && id != onlyOccupantId) continue;
      final p = tour.passengers.firstWhereOrNull((x) => x.id == id);
      if (p != null) out.add(_occupantFor(tour, bus, p, seatId));
    }
    return out;
  }

  /// Build the engine view of [p] on [seatId]: berths held here, how many WHOLE
  /// doubles they hold on this bus, and how many doubles they actually requested
  /// — the last two let the engine tell a SUBSTITUTE double (splittable) from a
  /// genuine one.
  SeatOccupant _occupantFor(Tour tour, Bus bus, Passenger p, String seatId) {
    final perCell = <String, int>{};
    for (final a in p.assignedSeats) {
      if (a.busId != bus.id) continue;
      perCell[a.seatId] = (perCell[a.seatId] ?? 0) + 1;
    }
    var wholeDoubles = 0;
    perCell.forEach((sid, n) {
      if (n < 2) return;
      if (_findCell(tour, bus.id, sid)?.seatType == SeatType.doubleSofa) {
        wholeDoubles++;
      }
    });
    final reqDoubles = p.requestLines
        .where((l) => l.seatType == SeatType.doubleSofa)
        .fold<int>(0, (s, l) => s + l.qty);
    return (
      passengerId: p.id,
      // Per-seat leg so the drag leg-share path (decideSeatDrop fill/fillPair)
      // reasons on the seat's real leg, not the coarse mixed-leg summary.
      trip: p.legForSeat(seatId, busId: bus.id),
      berthsHere: perCell[seatId] ?? 0,
      wholeDoublesHeld: wholeDoubles,
      requestedDoubleQty: reqDoubles,
    );
  }

  /// Run the drop engine for the in-flight drag onto [target].
  SeatDropDecision _decideDrop(
    Tour tour,
    Bus bus,
    SeatCell fromCell,
    SeatCell target, {
    String? grabbedOccupantId,
  }) {
    return decideSeatDrop(
      fromCell: (
        seatId: fromCell.seatId,
        seatType: fromCell.seatType,
        reserved: fromCell.reserved,
      ),
      targetCell: (
        seatId: target.seatId,
        seatType: target.seatType,
        reserved: target.reserved,
      ),
      fromOccupants: _occupantsOn(
        tour,
        bus,
        fromCell,
        onlyOccupantId: grabbedOccupantId,
      ),
      targetOccupants: _occupantsOn(tour, bus, target),
    );
  }

  /// Whether [cell] can be PICKED UP for a drag. A sole occupant always lifts; a
  /// TWO-occupant cell lifts as a unit when it is a real Double Sofa (a
  /// paired/whole double) OR a single seat reused across disjoint legs (one
  /// GO-only + one RET-only sharing one berth) — that leg-share relocates
  /// together onto a free seat. Any OTHER two-occupant non-double is managed
  /// per-person via the occupant sheet instead.
  bool _canDragSeat(Tour tour, Bus bus, SeatCell cell) {
    if (cell.reserved) {
      return false; // a held seat stays put — can't drag it off
    }
    final occs = _occupantsOn(tour, bus, cell);
    if (occs.isEmpty) return false;
    if (occs.length >= 2 &&
        cell.seatType != SeatType.doubleSofa &&
        !isLegDisjointPair(occs)) {
      return false;
    }
    return true;
  }

  /// Chip label that follows the finger — the occupant's name, or "A + B" for a
  /// shared double moving as a unit.
  String? _dragLabelFor(Tour tour, Bus bus, SeatCell cell) {
    final ids =
        (cell.seatId == null
                ? const <String>[]
                : _assignmentMap(tour, bus.id)[cell.seatId] ?? const <String>[])
            .toSet();
    if (ids.isEmpty) return null;
    final names = ids
        .map(
          (id) =>
              tour.passengers.firstWhereOrNull((p) => p.id == id)?.displayName,
        )
        .whereType<String>()
        .where((n) => n.isNotEmpty);
    return names.isEmpty ? null : names.join(' + ');
  }

  /// Live drop-target highlight for [target] against the in-flight drag. Mirrors
  /// the engine verdict used on release so the agent never sees a green ring on
  /// a drop that would be rejected.
  SeatDropHighlight _dropHighlightFor(Tour tour, Bus bus, SeatCell target) {
    // Dragging a PENDING rider from the dock → light up the seats they fit on.
    final pendingId = _pendingDragId;
    if (pendingId != null) {
      return _pendingDropHighlightFor(tour, bus, target, pendingId);
    }
    final fromSeatId = _dragFromSeatId;
    if (fromSeatId == null) return SeatDropHighlight.none;
    final targetSeatId = target.seatId;
    if (targetSeatId == null || target.isEmpty) return SeatDropHighlight.none;
    if (targetSeatId == fromSeatId) return SeatDropHighlight.none;

    final fromCell = _findCell(tour, bus.id, fromSeatId);
    if (fromCell == null) return SeatDropHighlight.none;

    final decision = _decideDrop(tour, bus, fromCell, target);
    if (decision.isValid) return SeatDropHighlight.valid;
    switch (decision.block) {
      case SeatDropBlock.self:
      case SeatDropBlock.neutral:
      case null:
        return SeatDropHighlight.none;
      case SeatDropBlock.held:
        // A reserved/held seat is PROTECTED, not merely a bad fit — paint the
        // distinct red lock so the agent can tell "can't touch this" from the
        // softer "doesn't fit here" dim.
        return SeatDropHighlight.blocked;
      default:
        return SeatDropHighlight.dim;
    }
  }

  /// Highlight for a seat while a PENDING rider is being dragged from the dock:
  /// green when the rider fits here (a free cell with room, or a leg-free
  /// occupied cell to share) AND it stays within their requested berths;
  /// otherwise no overlay. Mirrors the tap/drop placement rules.
  SeatDropHighlight _pendingDropHighlightFor(
    Tour tour,
    Bus bus,
    SeatCell target,
    String passengerId,
  ) {
    final targetSeatId = target.seatId;
    if (targetSeatId == null || target.isEmpty) return SeatDropHighlight.none;
    final passenger =
        tour.passengers.firstWhereOrNull((p) => p.id == passengerId);
    if (passenger == null ||
        passenger.isFullyAssigned ||
        passenger.isWaitlisted) {
      return SeatDropHighlight.none;
    }

    final owners = _assignmentMap(tour, bus.id)[targetSeatId] ?? const <String>[];
    if (owners.contains(passengerId)) return SeatDropHighlight.none;

    final berths = owners.isEmpty
        ? _berthsForFreeCell(passenger, target, tour: tour)
        : _seatHereBerths(
            tour, bus, target, passenger, _resolveOccupants(tour, owners));

    // Respect the hard berth cap — never invite a drop that would over-allocate.
    return (berths > 0 && berths <= passenger.remainingBerths)
        ? SeatDropHighlight.valid
        : SeatDropHighlight.none;
  }

  /// Toast explaining why a drop was rejected.
  void _toastBlocked(
    SeatDropBlock block,
    SeatCell fromCell,
    String toSeatId, {
    TripType? moverTrip,
  }) {
    switch (block) {
      case SeatDropBlock.self:
      case SeatDropBlock.neutral:
        return;
      case SeatDropBlock.classMismatch:
        AppSnackBar.warning(
          fromCell.seatType == SeatType.seater
              ? tr('tour_seat_assignment.drop.class_mismatch_seater')
              : tr('tour_seat_assignment.drop.class_mismatch_sleeper'),
          title: tr('tour_seat_assignment.drop.class_mismatch_title'),
        );
        return;
      case SeatDropBlock.tooSmall:
        AppSnackBar.warning(
          tr(
            'tour_seat_assignment.drop.too_small_body',
            namedArgs: {
              'name':
                  _dragLabelFor(_tour!, _selectedBus(_tour!)!, fromCell) ?? '',
            },
          ),
          title: tr('tour_seat_assignment.drop.too_small_title'),
        );
        return;
      case SeatDropBlock.held:
        AppSnackBar.warning(
          tr(
            'tour_seat_assignment.drop.held_body',
            namedArgs: {'seat': toSeatId},
          ),
          title: tr('tour_seat_assignment.drop.held_title'),
        );
        return;
      case SeatDropBlock.sharedTargetAmbiguous:
        AppSnackBar.info(
          tr('tour_seat_assignment.drop.shared_body'),
          title: tr('tour_seat_assignment.drop.shared_title'),
        );
        return;
      case SeatDropBlock.noLegRoom:
        // Distinct from the ambiguity toast: the mover's LEG is full on the
        // target, not a size mismatch and not a one-finger-ambiguity. Name the
        // SPECIFIC leg when the rider is one-way so the agent knows exactly which
        // leg clashed (round-trip rides both, so it stays generic).
        final legKey = moverTrip == null
            ? 'tour_seat_assignment.drop.leg_both'
            : (moverTrip.usesOutbound && !moverTrip.usesReturn)
                ? 'tour_seat_assignment.drop.leg_go'
                : (moverTrip.usesReturn && !moverTrip.usesOutbound)
                    ? 'tour_seat_assignment.drop.leg_ret'
                    : 'tour_seat_assignment.drop.leg_both';
        AppSnackBar.warning(
          tr(
            'tour_seat_assignment.drop.no_leg_room_body',
            namedArgs: {'seat': toSeatId, 'leg': tr(legKey)},
          ),
          title: tr('tour_seat_assignment.drop.no_leg_room_title'),
        );
        return;
      case SeatDropBlock.sharedNeedsFreeDouble:
        AppSnackBar.info(
          tr('tour_seat_assignment.drop.shared_need_free_double'),
          title: tr('tour_seat_assignment.drop.shared_title'),
        );
        return;
    }
  }

  /// When a SINGLE berth is dragged onto a FREE Double Sofa, decide whether this
  /// should CONSOLIDATE the passenger's two cross-filled singles into the one
  /// double instead of a plain move. Returns the OTHER single seatId to fold in
  /// (so the source pair is `[fromSeatId, otherSeatId]`), or null when this is a
  /// plain move.
  ///
  /// Detected screen-side from the passenger's own state — no new engine action:
  ///   * [target] is a free Double Sofa,
  ///   * the mover holds EXACTLY one berth on [fromSeatId] (a single-berth move),
  ///   * the mover holds EXACTLY one OTHER single-sofa berth on this bus, and
  ///   * the mover has an outstanding `doubleSofa` request line (i.e. they were
  ///     satisfied via two cross-filled singles and now want the real double).
  String? _consolidationPartnerSeat(
    Tour tour,
    Bus bus,
    Passenger mover,
    SeatCell fromCell,
    SeatCell target,
  ) {
    final fromSeatId = fromCell.seatId;
    if (fromSeatId == null) return null;
    if (target.seatType != SeatType.doubleSofa) return null;
    // Free double only — a half-filled/occupied double is a fill/swap, not a
    // consolidation of the mover's own scattered singles.
    if (_occupantsOn(tour, bus, target).isNotEmpty) return null;

    final wantsDouble =
        mover.requestLines
            .where((l) => l.seatType == SeatType.doubleSofa)
            .fold<int>(0, (s, l) => s + l.qty) >
        0;
    if (!wantsDouble) return null;

    // Berths the mover holds per seat on THIS bus.
    final perSeat = <String, int>{};
    for (final a in mover.assignedSeats) {
      if (a.busId != bus.id) continue;
      perSeat[a.seatId] = (perSeat[a.seatId] ?? 0) + 1;
    }
    // The source must be a single-berth hold (a cross-filled single, not a
    // whole double the engine would have routed elsewhere).
    if ((perSeat[fromSeatId] ?? 0) != 1) return null;

    // Find exactly one OTHER single-sofa seat the mover also holds one berth on.
    String? partner;
    for (final entry in perSeat.entries) {
      if (entry.key == fromSeatId) continue;
      if (entry.value != 1) continue;
      final cell = _findCell(tour, bus.id, entry.key);
      if (cell?.seatType != SeatType.singleSofa) continue;
      if (partner != null) return null; // ambiguous — more than one candidate
      partner = entry.key;
    }
    return partner;
  }

  /// Resolve a released drag from [fromSeatId] onto [toSeatId] on [bus] by
  /// dispatching the engine verdict.
  Future<void> _handleSeatDrop(
    Tour tour,
    Bus bus,
    String fromSeatId,
    String toSeatId, {
    String? grabbedOccupantId,
  }) async {
    final fromCell = _findCell(tour, bus.id, fromSeatId);
    final targetCell = _findCell(tour, bus.id, toSeatId);
    if (fromCell == null || targetCell == null) return;
    final fromOccs = _occupantsOn(
      tour,
      bus,
      fromCell,
      onlyOccupantId: grabbedOccupantId,
    );
    if (fromOccs.isEmpty) return;

    final decision = _decideDrop(
      tour,
      bus,
      fromCell,
      targetCell,
      grabbedOccupantId: grabbedOccupantId,
    );
    final mover = tour.passengers.firstWhereOrNull(
      (p) => p.id == fromOccs.first.passengerId,
    );

    switch (decision.action) {
      case SeatDropAction.blocked:
        HapticFeedback.mediumImpact();
        _toastBlocked(
          decision.block!,
          fromCell,
          toSeatId,
          moverTrip: mover?.tripType,
        );
        return;

      case SeatDropAction.splitPairChoice:
        // A paired double dropped onto a single (free or single-occupant). Ask
        // WHICH of the two sharers peels onto the single; the other keeps the
        // double. The engine surfaces this as a VALID (green) target, so the
        // highlight matches what release does.
        await _promptSplitPairOntoSingle(tour, bus, fromCell, targetCell);
        return;

      case SeatDropAction.swapPair:
        // Two occupied doubles exchange their full contents (two couples swap
        // sofas). Both seats are cap-2, so the exchange is always seat-safe.
        await _ctrl.swapSeatContents(
          tourId: tour.id,
          busId: bus.id,
          seatAId: fromSeatId,
          seatBId: toSeatId,
        );
        AppSnackBar.success(
          tr(
            'tour_seat_assignment.drop.swapped_body',
            namedArgs: {
              'a': _dragLabelFor(tour, bus, fromCell) ?? fromSeatId,
              'b': _dragLabelFor(tour, bus, targetCell) ?? toSeatId,
            },
          ),
          title: tr('tour_seat_assignment.drop.swapped_title'),
        );
        return;

      case SeatDropAction.move:
        if (mover == null) return;
        // CONSOLIDATION: a single berth dragged onto a free Double Sofa while the
        // mover also holds another cross-filled single AND still wants a double →
        // fold BOTH singles into the one double instead of a plain move.
        final partnerSeat = _consolidationPartnerSeat(
          tour,
          bus,
          mover,
          fromCell,
          targetCell,
        );
        if (partnerSeat != null) {
          await _ctrl.consolidateOntoDouble(
            tourId: tour.id,
            passengerId: mover.id,
            busId: bus.id,
            targetSeatId: toSeatId,
            sourceSeatIds: [fromSeatId, partnerSeat],
          );
          AppSnackBar.success(
            tr(
              'tour_seat_assignment.drop.consolidated_body',
              namedArgs: {'name': mover.displayName, 'seat': toSeatId},
            ),
            title: tr('tour_seat_assignment.drop.consolidated_title'),
          );
          return;
        }
        await _ctrl.moveSeat(
          tourId: tour.id,
          passengerId: mover.id,
          busId: bus.id,
          fromSeatId: fromSeatId,
          toSeatId: toSeatId,
          toBusId: bus.id,
        );
        AppSnackBar.success(
          tr(
            'tour_seat_assignment.drop.moved_body',
            namedArgs: {'name': mover.displayName, 'seat': toSeatId},
          ),
          title: tr('tour_seat_assignment.drop.moved_title'),
        );
        return;

      case SeatDropAction.splitToSingle:
        if (mover == null) return;
        await _ctrl.moveSeat(
          tourId: tour.id,
          passengerId: mover.id,
          busId: bus.id,
          fromSeatId: fromSeatId,
          toSeatId: toSeatId,
          toBusId: bus.id,
          berths: 1,
        );
        AppSnackBar.success(
          tr(
            'tour_seat_assignment.drop.split_body',
            namedArgs: {'name': mover.displayName, 'seat': toSeatId},
          ),
          title: tr('tour_seat_assignment.drop.split_title'),
        );
        return;

      case SeatDropAction.fill:
        if (mover == null) return;
        final occ = tour.passengers.firstWhereOrNull(
          (p) =>
              p.id ==
              _occupantsOn(tour, bus, targetCell).firstOrNull?.passengerId,
        );
        if (occ == null) return;
        if (!mounted) return;
        final confirmed = await _confirmSheet(
          context,
          title: tr('tour_seat_assignment.share_confirm_title'),
          message: tr(
            'tour_seat_assignment.share_confirm_body',
            namedArgs: {
              'seat': toSeatId,
              'otherName': occ.displayName,
              'currentName': mover.displayName,
            },
          ),
          confirmLabel: tr('tour_seat_assignment.share_confirm_yes'),
        );
        if (!confirmed) return;
        await _ctrl.moveSeat(
          tourId: tour.id,
          passengerId: mover.id,
          busId: bus.id,
          fromSeatId: fromSeatId,
          toSeatId: toSeatId,
          toBusId: bus.id,
          berths: 1,
        );
        AppSnackBar.success(
          tr(
            'tour_seat_assignment.drop.filled_body',
            namedArgs: {
              'a': mover.displayName,
              'b': occ.displayName,
              'seat': toSeatId,
            },
          ),
          title: tr('tour_seat_assignment.drop.filled_title'),
        );
        return;

      case SeatDropAction.swap:
        if (mover == null) return;
        final occ = tour.passengers.firstWhereOrNull(
          (p) => p.id == _occupantsOn(tour, bus, targetCell).first.passengerId,
        );
        if (occ == null) return;
        if (!mounted) return;
        await SeatSwapGuard.run(
          context,
          tourId: tour.id,
          busAId: bus.id,
          passengerAId: mover.id,
          seatAId: fromSeatId,
          passengerBId: occ.id,
          seatBId: toSeatId,
          busBId: bus.id,
        );
        AppSnackBar.success(
          tr(
            'tour_seat_assignment.drop.swapped_body',
            namedArgs: {'a': mover.displayName, 'b': occ.displayName},
          ),
          title: tr('tour_seat_assignment.drop.swapped_title'),
        );
        return;

      case SeatDropAction.moveBoth:
        await _ctrl.moveSharedPair(
          tourId: tour.id,
          busId: bus.id,
          fromSeatId: fromSeatId,
          toSeatId: toSeatId,
        );
        AppSnackBar.success(
          tr(
            'tour_seat_assignment.drop.moved_both_body',
            namedArgs: {
              'names': _dragLabelFor(tour, bus, fromCell) ?? '',
              'seat': toSeatId,
            },
          ),
          title: tr('tour_seat_assignment.drop.moved_both_title'),
        );
        return;

      case SeatDropAction.fillPairInto:
        // Merge the source occupant(s) into the leg-disjoint occupied double: move
        // each mover's OWN berths onto the target (its occupants stay put), so all
        // riders share one double across opposite legs. Moves the actual held
        // berth count per mover — 1 each for a GO+RET pair source, 2 for a WHOLE
        // one-leg double dragged onto an opposite-leg double (the leg-share the
        // agent expects, instead of a silent swap).
        for (final o in fromOccs) {
          await _ctrl.moveSeat(
            tourId: tour.id,
            passengerId: o.passengerId,
            busId: bus.id,
            fromSeatId: fromSeatId,
            toSeatId: toSeatId,
            toBusId: bus.id,
            berths: o.berthsHere,
          );
        }
        AppSnackBar.success(
          tr(
            'tour_seat_assignment.drop.moved_both_body',
            namedArgs: {
              'names': _dragLabelFor(tour, bus, fromCell) ?? '',
              'seat': toSeatId,
            },
          ),
          title: tr('tour_seat_assignment.drop.moved_both_title'),
        );
        return;
    }
  }

  /// A paired double was dropped on a single seat. Ask which of the two sharers
  /// moves onto [targetCell] (the other keeps the double), then seat the chosen
  /// one. A FREE single just takes the chosen passenger's berth; an OCCUPIED
  /// single swaps the chosen sharer with whoever sits there (so that occupant
  /// joins the remaining sharer on the double). A single reused across legs (two
  /// occupants) is too ambiguous to resolve with one tap → fall back to a toast.
  Future<void> _promptSplitPairOntoSingle(
    Tour tour,
    Bus bus,
    SeatCell fromCell,
    SeatCell targetCell,
  ) async {
    final fromSeatId = fromCell.seatId!;
    final toSeatId = targetCell.seatId!;
    final pair = _occupantsOn(tour, bus, fromCell);
    final candidates = pair
        .map(
          (o) => tour.passengers.firstWhereOrNull((p) => p.id == o.passengerId),
        )
        .whereType<Passenger>()
        .toList();
    if (candidates.length != 2) return;

    final targetOccs = _occupantsOn(tour, bus, targetCell);
    if (targetOccs.length >= 2) {
      _toastBlocked(SeatDropBlock.sharedNeedsFreeDouble, fromCell, toSeatId);
      return;
    }

    // "Both" is offered only when the two sharers travel on DISJOINT legs (one
    // outbound, one return) AND the target single is fully free — then both
    // riders leg-reuse the single seat and the whole double sofa is released.
    // Any leg overlap (or a round-trip rider) means they can't co-seat a single,
    // so the choice stays one-or-the-other.
    final bothFits =
        targetOccs.isEmpty && _legsDisjoint(candidates[0], candidates[1]);

    UgamSheet.show<void>(
      context,
      title: tr(
        'tour_seat_assignment.split_pair.title',
        namedArgs: {'seat': toSeatId},
      ),
      builder: (sheetCtx) => _SeatPassengerPicker(
        candidates: candidates,
        activeId: null,
        subtitle: tr('tour_seat_assignment.split_pair.subtitle'),
        bothLabel: bothFits
            ? tr('tour_seat_assignment.split_pair.both_label')
            : null,
        bothHint: bothFits
            ? tr(
                'tour_seat_assignment.split_pair.both_hint',
                namedArgs: {'seat': toSeatId},
              )
            : null,
        onPickBoth: bothFits
            ? () {
                Navigator.of(sheetCtx).pop();
                _seatBothSharersOnSingle(
                  tour,
                  bus,
                  fromSeatId,
                  toSeatId,
                  candidates[0],
                  candidates[1],
                );
              }
            : null,
        onPick: (chosen) {
          Navigator.of(sheetCtx).pop();
          _seatChosenSharerOnSingle(
            tour,
            bus,
            fromSeatId,
            toSeatId,
            chosen,
            targetOccs.firstOrNull,
          );
        },
      ),
    );
  }

  /// Whether [a] and [b] travel on non-overlapping legs — one uses the outbound
  /// leg without the return and the other the reverse. Only such a pair can
  /// share a single berth (leg-reuse); any round-trip rider uses both legs and
  /// therefore overlaps.
  bool _legsDisjoint(Passenger a, Passenger b) {
    final la = a.derivedTripType;
    final lb = b.derivedTripType;
    final outboundClash = la.usesOutbound && lb.usesOutbound;
    final returnClash = la.usesReturn && lb.usesReturn;
    return !outboundClash && !returnClash;
  }

  /// Move BOTH leg-disjoint sharers off the source double onto the single
  /// [toSeatId] (each keeps their leg, so they co-seat via leg-reuse) — this
  /// releases the entire double sofa. Only reached when the target single is
  /// free and the pair's legs don't overlap (see [_legsDisjoint]).
  Future<void> _seatBothSharersOnSingle(
    Tour tour,
    Bus bus,
    String fromSeatId,
    String toSeatId,
    Passenger a,
    Passenger b,
  ) async {
    await _ctrl.moveSharedPair(
      tourId: tour.id,
      busId: bus.id,
      fromSeatId: fromSeatId,
      toSeatId: toSeatId,
    );
    AppSnackBar.success(
      tr(
        'tour_seat_assignment.split_pair.both_body',
        namedArgs: {
          'a': a.displayName,
          'b': b.displayName,
          'seat': toSeatId,
        },
      ),
      title: tr('tour_seat_assignment.split_pair.moved_title'),
    );
  }

  /// Seat [chosen] (one sharer of a paired double) onto the single [toSeatId].
  /// When the single is free, move their single berth over; when it already
  /// holds [occupant], swap the two so the displaced occupant takes the freed
  /// half of the double beside the remaining sharer.
  Future<void> _seatChosenSharerOnSingle(
    Tour tour,
    Bus bus,
    String fromSeatId,
    String toSeatId,
    Passenger chosen,
    SeatOccupant? occupant,
  ) async {
    if (occupant == null) {
      await _ctrl.moveSeat(
        tourId: tour.id,
        passengerId: chosen.id,
        busId: bus.id,
        fromSeatId: fromSeatId,
        toSeatId: toSeatId,
        toBusId: bus.id,
        berths: 1,
      );
      AppSnackBar.success(
        tr(
          'tour_seat_assignment.split_pair.moved_body',
          namedArgs: {'name': chosen.displayName, 'seat': toSeatId},
        ),
        title: tr('tour_seat_assignment.split_pair.moved_title'),
      );
      return;
    }

    final occ = tour.passengers.firstWhereOrNull(
      (p) => p.id == occupant.passengerId,
    );
    if (occ == null) return;
    if (!mounted) return;
    await SeatSwapGuard.run(
      context,
      tourId: tour.id,
      busAId: bus.id,
      passengerAId: chosen.id,
      seatAId: fromSeatId,
      passengerBId: occ.id,
      seatBId: toSeatId,
      busBId: bus.id,
    );
    AppSnackBar.success(
      tr(
        'tour_seat_assignment.split_pair.swapped_body',
        namedArgs: {
          'a': chosen.displayName,
          'b': occ.displayName,
          'seat': toSeatId,
        },
      ),
      title: tr('tour_seat_assignment.drop.swapped_title'),
    );
  }
}
