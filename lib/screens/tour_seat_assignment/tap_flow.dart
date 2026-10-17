part of '../tour_seat_assignment_screen.dart';

// Seat-tap flow of [TourSeatAssignmentScreen]: assignment maps, pending
// lines, berth-fit maths, the seat picker and the occupant sheet.
extension _TapFlow on _TourSeatAssignmentScreenState {
  /// All seats assigned to anyone, indexed by bus then seat.
  ///
  /// One pass over `tour.passengers × assignedSeats` produces the maps
  /// for every bus on the tour at once — far cheaper than the previous
  /// per-bus filter, which `build()` invoked N+1 times (once for the
  /// selected bus, plus once per pill in `_BusStrip`'s
  /// `seatsAssignedFor` callback). A `doubleSofa` cell may carry up to
  /// two passenger IDs when the agent has split the sofa between two
  /// unrelated singles; insertion order is preserved so the first
  /// occupant renders on the left half of a split tile.
  Map<String, Map<String, List<String>>> _assignmentsByBus(Tour tour) {
    final out = <String, Map<String, List<String>>>{};
    for (final p in tour.passengers) {
      for (final a in p.assignedSeats) {
        ((out[a.busId] ??= <String, List<String>>{})[a.seatId] ??= <String>[])
            .add(p.id);
      }
    }
    return out;
  }

  /// Backwards-compatible single-bus accessor for code paths (e.g. the
  /// tap handler) that don't have a precomputed `assignmentsByBus`
  /// handy.
  Map<String, List<String>> _assignmentMap(Tour tour, String busId) {
    final map = <String, List<String>>{};
    for (final p in tour.passengers) {
      for (final a in p.assignedSeats) {
        if (a.busId == busId) {
          (map[a.seatId] ??= <String>[]).add(p.id);
        }
      }
    }
    return map;
  }

  /// Pending request lines for the passenger after subtracting what's
  /// already been assigned.
  ///
  /// The draining math (which held berth satisfies which request line,
  /// cross-fill, own-cell double completion, leg-aware reuse) now lives in the
  /// shared, pure [computePendingLines] so the manual screen matches the auto
  /// seating engine BY CONSTRUCTION. This wrapper just adapts the passenger /
  /// tour models into the module's value inputs and maps the module's
  /// aggregated `remaining` back onto the original per-line `_PendingLine`s so
  /// the displayed `X/Y` progress (which needs each line's `totalRequested`)
  /// stays exact.
  List<_PendingLine> _pendingLines(Passenger passenger, {Tour? tour}) {
    // One `_PendingLine` per ORIGINAL request line (preserves order + the
    // per-line totalRequested the progress label renders). `remaining` starts
    // full and is reduced below from the module's verdict.
    final lines = [
      for (final line in passenger.requestLines)
        _PendingLine(
          seatType: line.seatType,
          position: line.position,
          remaining: line.qty,
          totalRequested: line.qty,
        ),
    ];

    final t = tour ?? _tour;
    if (t == null) return lines;

    final result = computePendingLines(
      requestLines: [
        for (final line in passenger.requestLines)
          PendingLineInput(
            seatType: line.seatType,
            position: line.position,
            qty: line.qty,
          ),
      ],
      heldBerths: [
        for (final a in passenger.assignedSeats)
          HeldBerth(busId: a.busId, seatId: a.seatId),
      ],
      ctx: _seatFitContext(t),
      // The own-cell double-completion case the manual screen historically
      // MISSED: a passenger holding ONE berth of a Double Sofa whose partner
      // berth is still leg-free, with a matching pending doubleSofa line. The
      // module decides it and asks here whether the partner berth is actually
      // claimable; we answer with the SAME per-leg rule the engine uses.
      canClaimPartnerBerth: (claim) =>
          _canClaimPartnerBerth(t, passenger, claim),
    );

    // Map the aggregated `remaining` (keyed by seatType+position) back onto the
    // original lines, in order. Each original line keeps its totalRequested;
    // its `remaining` is whatever the module still leaves unsatisfied for that
    // (type, position) bucket, distributed across matching lines first-come.
    final leftover = <(SeatType, SeatPosition?), int>{};
    for (final r in result.remaining) {
      leftover[(r.seatType, r.position)] =
          (leftover[(r.seatType, r.position)] ?? 0) + r.qty;
    }
    for (var i = 0; i < lines.length; i++) {
      final l = lines[i];
      final key = (l.seatType, l.position);
      final pool = leftover[key] ?? 0;
      final keep = pool >= l.totalRequested ? l.totalRequested : pool;
      leftover[key] = pool - keep;
      lines[i] = _PendingLine(
        seatType: l.seatType,
        position: l.position,
        remaining: keep,
        totalRequested: l.totalRequested,
      );
    }
    return lines;
  }

  /// Pure cell-lookup adapter the shared [computePendingLines] /
  /// [berthsForFreeCell] use to resolve a cell's type + position from
  /// (busId, seatId) against the tour layout.
  SeatFitContext _seatFitContext(Tour tour) => SeatFitContext(
    cellTypeAt: (busId, seatId) => _findCell(tour, busId, seatId)?.seatType,
    cellPositionAt: (busId, seatId) => _findCell(tour, busId, seatId)?.position,
  );

  /// Answers the module's own-cell double-completion question with the SAME
  /// per-leg model the auto engine uses: the partner berth of [claim]'s Double
  /// Sofa is claimable when there is still leg room for ONE MORE berth on
  /// [passenger]'s trip after accounting for everyone ALREADY on that cell —
  /// including [passenger]'s OWN already-held berth (which, like the engine's
  /// locked berth, has already consumed a per-leg slot before the partner is
  /// claimed). The engine answers this against its plan state; here we read the
  /// live tour.
  bool _canClaimPartnerBerth(
    Tour tour,
    Passenger passenger,
    PendingClaim claim,
  ) {
    final holders = <SeatLegHolder>[
      for (final p in tour.passengers)
        for (final n in [
          p.assignedSeats
              .where((a) => a.busId == claim.busId && a.seatId == claim.seatId)
              .length,
        ])
          if (n > 0) (trip: p.legForSeat(claim.seatId, busId: claim.busId), berths: n),
    ];
    return seatHasLegRoom(
      // The rider's REAL leg, not the raw stored column — which defaults to
      // round-trip and would claim a one-way rider needs both legs of their own
      // sofa. Same rule the occupant side above and [_berthsForCell] use.
      activeTrip: passenger.effectiveTripType,
      need: 1,
      cap: 2,
      occupants: holders,
    );
  }

  SeatCell? _findCell(Tour tour, String busId, String seatId) {
    final bus = tour.buses.where((b) => b.id == busId).firstOrNull;
    final layout = bus?.layout;
    if (layout == null) return null;
    for (final c in layout.grid) {
      if (c.seatId == seatId) return c;
    }
    return null;
  }

  /// How many berths to claim when this passenger taps an unoccupied
  /// cell. Returns 0 when the cell's type doesn't match anything pending.
  ///
  /// Routes through the shared, pure [berthsForFreeCell] so the type/position
  /// matching matrix AND the per-leg capacity gate are the SAME single rule the
  /// auto engine and the occupied-cell path use. A genuinely free cell has no
  /// occupants, so the leg gate is trivially satisfied; the unified rule means
  /// "what the tap offers" and "what placement accepts" can no longer diverge
  /// (symptoms B & C).
  int _berthsForFreeCell(Passenger passenger, SeatCell cell, {Tour? tour}) {
    return _berthsForCell(passenger, cell, const <SeatLegHolder>[], tour: tour);
  }

  /// Shared core for both the free-cell tap ([_berthsForFreeCell], empty
  /// [occupants]) and the share-onto-occupied path ([_seatHereBerths], real
  /// holders). Drains the passenger's pending lines, then asks the shared
  /// module how many berths the (free or occupied) [cell] can take.
  int _berthsForCell(
    Passenger passenger,
    SeatCell cell,
    List<SeatLegHolder> occupants, {
    Tour? tour,
  }) {
    final cellType = cell.seatType;
    if (cellType == null) return 0; // empty / aisle cell — nothing to claim
    final remaining = [
      for (final l in _pendingLines(passenger, tour: tour))
        if (l.remaining > 0)
          PendingLineInput(
            seatType: l.seatType,
            position: l.position,
            qty: l.remaining,
          ),
    ];
    return berthsForFreeCell(
      remaining: remaining,
      cellType: cellType,
      cellPosition: cell.position,
      // Gate on the per-LINE derived leg, not the coarse stored [tripType]
      // (which defaults to roundTrip). A pure return-only rider whose stored
      // field was never stamped was wrongly treated as needing BOTH legs, so
      // the leg gate refused a GO-occupied but RET-free seat — the exact
      // "can't place my return-only passenger" case. Matches how occupant legs
      // are already resolved per-seat in [_seatHereBerths].
      activeTrip: passenger.derivedTripType,
      cap: cellType == SeatType.doubleSofa ? 2 : 1,
      occupants: occupants,
    );
  }

  void _onSeatTapped(SeatCell cell, Bus bus, Tour tour) {
    HapticFeedback.selectionClick();
    if (cell.isEmpty || cell.seatId == null) return;

    // Relocate mode → the tapped seat is the TARGET for the in-hand mover: a
    // free seat moves them here (after confirm), an occupied seat opens the
    // occupant menu with a "seat [mover] here" swap.
    if (_relocate != null) {
      _onRelocateSeatTapped(cell, bus, tour);
      return;
    }

    final assignmentMap = _assignmentMap(tour, bus.id);
    final owners = assignmentMap[cell.seatId] ?? const <String>[];

    // Occupied seat. Tap-to-place FIRST: with a pending rider in hand who has
    // leg-free room to SHARE this seat (e.g. a return-only rider onto a seat
    // held GO-only), seat them directly with a share-confirm — the same one-tap
    // flow as a free seat, instead of making the agent dig it out of the
    // occupant sheet. This is the missing gesture for placing a one-leg rider
    // onto a leg-free seat. If they don't fit, fall through to the sheet.
    if (owners.isNotEmpty) {
      final activeId = _selectedPassengerId;
      if (activeId != null) {
        final active =
            tour.passengers.firstWhereOrNull((p) => p.id == activeId);
        if (active != null &&
            !active.isFullyAssigned &&
            !active.isWaitlisted &&
            !owners.contains(active.id)) {
          final occupants = _resolveOccupants(tour, owners);
          final berths = _seatHereBerths(tour, bus, cell, active, occupants);
          if (berths > 0 && occupants.isNotEmpty) {
            _seatHere(active, bus, tour, cell, occupants.first, berths);
            return;
          }
        }
      }

      // No pending rider fits here → open the shared occupant action sheet
      // (manage anyone sitting here: call / move / swap / move-to-another-bus /
      // free, with a person toggle for a shared sofa). When a passenger is
      // mid-placement and the seat can be shared, the sheet also offers "seat
      // [name] here" (and swap-in when the leg is full).
      _openOccupantSheet(
        cell,
        bus,
        tour,
        owners,
        active: _selectedPassenger(tour),
      );
      return;
    }

    // Free seat. When a passenger is ALREADY selected (chip / dock / deep-link)
    // and this cell fits them, place them immediately — no picker. The picker
    // only appears when nobody is selected (or the selected passenger doesn't
    // fit this cell but others would), so seat-first assignment still works.
    final activeId = _selectedPassengerId;
    if (activeId != null) {
      final active = tour.passengers.firstWhereOrNull((p) => p.id == activeId);
      if (active != null && !active.isFullyAssigned && !active.isWaitlisted) {
        final berths = _berthsForFreeCell(active, cell, tour: tour);
        if (berths > 0) {
          _placeBerths(active, bus, tour, cell, berths);
          return;
        }
      }
    }

    // Nobody selected (or the selected passenger doesn't fit) → show the picker
    // of pending passengers who can sit here, so the agent assigns seat-first.
    _openSeatPicker(cell, bus, tour);
  }

  /// A PENDING rider was DRAGGED from the dock onto [seatId]. Places them the
  /// same way a tap would: a free cell takes them directly; a leg-free occupied
  /// cell shares them in (a return-only rider onto a GO-held seat); otherwise a
  /// toast explains there is no room. The hard berth cap in [_placeBerths] still
  /// guards over-allocation, so this can never seat more than requested.
  void _handlePendingDropToSeat(
    Tour tour,
    Bus bus,
    String passengerId,
    String seatId,
  ) {
    final passenger =
        tour.passengers.firstWhereOrNull((p) => p.id == passengerId);
    final cell = _findCell(tour, bus.id, seatId);
    if (passenger == null || cell == null) return;
    if (passenger.isFullyAssigned || passenger.isWaitlisted) return;

    // Keep the dropped rider as the active selection so the chart context (and
    // any follow-up placement of their remaining berths) stays on them.
    _selectPassenger(tour, passengerId);

    final owners = _assignmentMap(tour, bus.id)[seatId] ?? const <String>[];

    // Free seat → place directly.
    if (owners.isEmpty) {
      final berths = _berthsForFreeCell(passenger, cell, tour: tour);
      if (berths > 0) {
        _placeBerths(passenger, bus, tour, cell, berths);
      } else {
        AppSnackBar.warning(
          tr('tour_seat_assignment.picker_none', namedArgs: {'seat': seatId}),
        );
      }
      return;
    }

    // Occupied seat → share into the leg-free room if there is any.
    if (owners.contains(passengerId)) return; // already sitting here
    final occupants = _resolveOccupants(tour, owners);
    final berths = _seatHereBerths(tour, bus, cell, passenger, occupants);
    if (berths > 0 && occupants.isNotEmpty) {
      _seatHere(passenger, bus, tour, cell, occupants.first, berths);
    } else {
      AppSnackBar.warning(
        tr('tour_seat_assignment.picker_none', namedArgs: {'seat': seatId}),
      );
    }
  }

  /// Tap an empty seat → list the pending passengers who can take it (their
  /// request still has a matching, unplaced line). Picking one seats them here.
  void _openSeatPicker(SeatCell cell, Bus bus, Tour tour) {
    final activeId = _selectedPassengerId;
    final candidates =
        tour.passengers
            .where(
              (p) =>
                  !p.isFullyAssigned &&
                  !p.isWaitlisted &&
                  _berthsForFreeCell(p, cell, tour: tour) > 0,
            )
            .toList()
          // Surface the currently-selected passenger first.
          ..sort((a, b) {
            if (a.id == activeId) return -1;
            if (b.id == activeId) return 1;
            return 0;
          });

    if (candidates.isEmpty) {
      AppSnackBar.warning(
        tr(
          'tour_seat_assignment.picker_none',
          namedArgs: {'seat': cell.seatId ?? ''},
        ),
      );
      return;
    }

    UgamSheet.show<void>(
      context,
      title: tr(
        'tour_seat_assignment.picker_title',
        namedArgs: {'seat': cell.seatId ?? '', 'bus': bus.name},
      ),
      builder: (sheetCtx) => _SeatPassengerPicker(
        candidates: candidates,
        activeId: activeId,
        onPick: (p) {
          Navigator.of(sheetCtx).pop();
          _placeBerths(
            p,
            bus,
            tour,
            cell,
            _berthsForFreeCell(p, cell, tour: tour),
          );
        },
      ),
    );
  }

  /// Open the shared occupant action sheet for the people on [cell]. When
  /// [active] is a passenger mid-placement and the cell is a doubleSofa that can
  /// still take a half-share (one occupant + a matching pending line), surface
  /// the "seat [active] here" share action inside the sheet.
  /// The distinct [Passenger] models for the ids sitting on a seat, in owner
  /// order (deduped — a whole-double owner appears twice in [owners]).
  List<Passenger> _resolveOccupants(Tour tour, List<String> owners) {
    final byId = {for (final p in tour.passengers) p.id: p};
    final seen = <String>{};
    final occupants = <Passenger>[];
    for (final id in owners) {
      if (seen.add(id)) {
        final p = byId[id];
        if (p != null) occupants.add(p);
      }
    }
    return occupants;
  }

  void _openOccupantSheet(
    SeatCell cell,
    Bus bus,
    Tour tour,
    List<String> owners, {
    Passenger? active,
  }) {
    final occupants = _resolveOccupants(tour, owners);
    if (occupants.isEmpty) return;

    Passenger? placing;
    VoidCallback? onSeatHere;
    VoidCallback? onSwapIn;
    if (active != null && !owners.contains(active.id)) {
      final berths = _seatHereBerths(tour, bus, cell, active, occupants);
      if (berths > 0) {
        placing = active;
        onSeatHere = () =>
            _seatHere(active, bus, tour, cell, occupants.first, berths);
      } else {
        // No leg room to SHARE — but the active passenger may still belong here
        // if we bump the occupant who actually blocks their leg. Pick that one
        // occupant, then confirm the active rider fits once they're gone, so the
        // swap never overbooks the cell (and the other leg-share stays put).
        final conflict =
            _conflictingOccupant(active, occupants, cell.seatId!, bus.id);
        if (conflict != null) {
          final remaining =
              occupants.where((o) => o.id != conflict.id).toList();
          final berthsAfter =
              _seatHereBerths(tour, bus, cell, active, remaining);
          if (berthsAfter > 0) {
            placing = active;
            onSwapIn = () =>
                _swapInPlacing(active, bus, tour, cell, conflict, berthsAfter);
          }
        }
      }
    }

    OccupantActionSheet.show(
      context,
      occupants: occupants,
      tourId: tour.id,
      busId: bus.id,
      seatId: cell.seatId!,
      busName: bus.name,
      placing: placing,
      onSeatHere: onSeatHere,
      onSwapIn: onSwapIn,
      // "Move or swap" → pick a destination bus → hand back here so the agent
      // lands on that bus's chart and taps the exact target seat by hand.
      onRelocateToBus: _beginRelocate,
      // Strike one leg off THIS seat, then offer to rebook the freed half.
      onCancelSeatLeg: (occ, strike) =>
          _cancelSeatLegFlow(occ, strike, bus, cell.seatId!),
      // Seat Hold/Premium flags for this seat — the tap-menu home for the old
      // edit-seats mode (empty seats reach the same sheet via long-press).
      onSeatFlags: () => _showSeatFlagsSheet(cell, bus),
    );
  }

  /// Strike ONE leg off ONE seat for an occupant, then offer to resell the half
  /// that just came free. Seat-scoped, so a party holding a double plus a single
  /// loses only the berth the agent tapped — the rest of the party keeps both
  /// legs. The sheet gates which legs are offerable ([cancellableSeatLegs]).
  ///
  /// The berth the rider DID travel survives the strike: cancelling a return
  /// leaves their GO berth on the chart, re-stamped outbound-only, so the tile
  /// still shows who rode out while its return half becomes sellable.
  Future<void> _cancelSeatLegFlow(
    Passenger occ,
    TripType strike,
    Bus bus,
    String seatId,
  ) async {
    final cancellingReturn = strike == TripType.returnOnly;
    final ok = await _confirmSheet(
      context,
      title: cancellingReturn
          ? tr('tour_detail.cancel_return_confirm_title')
          : tr('tour_detail.cancel_go_confirm_title'),
      message: cancellingReturn
          ? tr('tour_detail.cancel_return_confirm_body',
              namedArgs: {'name': occ.displayName, 'seat': seatId})
          : tr('tour_detail.cancel_go_confirm_body',
              namedArgs: {'name': occ.displayName, 'seat': seatId}),
      confirmLabel: cancellingReturn
          ? tr('tour_detail.cancel_return_cta')
          : tr('tour_detail.cancel_go_cta'),
      destructive: true,
      confirmIcon:
          cancellingReturn ? Icons.event_busy_rounded : Icons.logout_rounded,
    );
    if (!ok) return;
    await _ctrl.cancelSeatLeg(
      widget.tourId,
      occ.id,
      busId: bus.id,
      seatId: seatId,
      strike: strike,
    );
    if (!mounted) return;
    AppSnackBar.success(
      cancellingReturn
          ? tr('tour_detail.cancel_return_done',
              namedArgs: {'name': occ.displayName})
          : tr('tour_detail.cancel_go_done',
              namedArgs: {'name': occ.displayName}),
    );

    // Reselling is a RETURN-leg move: the freed half is a seat home. A struck
    // outbound berth frees a seat on a bus that has not left, which is ordinary
    // assignment work, so no rebook prompt there.
    if (!cancellingReturn) return;
    final rebook = await _confirmSheet(
      context,
      title: tr('tour_detail.cancel_return_rebook_title'),
      message: tr('tour_detail.cancel_return_rebook_body'),
      confirmLabel: tr('tour_detail.add_return_ticket'),
      confirmIcon: Icons.event_seat_rounded,
    );
    if (!rebook || !mounted) return;
    final tour = _tour;
    if (tour != null) AddReturnTicketSheet.show(context, tour);
  }
}
