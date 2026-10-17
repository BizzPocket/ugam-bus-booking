part of 'board_screen.dart';

// The passenger sheet and the money write of [BoardScreen] (spec §8).
extension _BoardSheetActions on _BoardScreenState {
  // ── The sheet ───────────────────────────────────────────────

  /// One berth, one tap, two meanings.
  ///
  /// Normally the tap opens the sheet. While a relocate is in flight the whole
  /// chart is a target picker instead — the tap PLACES the person in hand, and
  /// opening a sheet about whoever is already there would be the app changing
  /// the subject mid-gesture.
  Future<void> _onBerthTap(
    Tour tour,
    Bus bus,
    BoardBusPage page,
    BoardBerthSlot slot,
  ) async {
    if (_relocate != null) {
      await _relocateOnto(tour, bus, slot);
      return;
    }
    await _openSheet(
      cell: slot.cell,
      tour: tour,
      bus: bus,
      page: page,
      lens: slot.lens,
    );
  }

  /// Opens the one passenger sheet for [cell]. Null when the berth holds
  /// nobody — a vacant berth has no passenger to show, and the assign picker of
  /// spec §7 is not in this wave (see the library doc).
  Future<PassengerSheetResult?> _openSheet({
    required SeatCell cell,
    required Tour tour,
    required Bus bus,
    required BoardBusPage page,
    required BoardLens lens,
  }) async {
    final seatId = cell.seatId;
    if (seatId == null || seatId.isEmpty) return null;

    final riders = occupantListForBus(tour.passengers, bus.id)[seatId];
    if (riders == null || riders.isEmpty) return null;

    final names = _groupNames(tour);
    final occupants = [
      for (final p in riders)
        PassengerSheetOccupant(
          // Per RIDER, not per berth. A split sofa holds two people with
          // genuinely different balances, and showing the berth's combined
          // figure against one of their names is the bug the old sheet had.
          berth: _riderBerth(
            bus: bus,
            rider: p,
            seatId: seatId,
            cell: cell,
            groupNames: names,
          ),
          passenger: p,
        ),
    ];

    if (!mounted) return null;
    return PassengerSheet.show(
      context,
      occupants: occupants,
      lens: lens,
      tourId: tour.id,
      busId: bus.id,
      busName: bus.customerLabel,
      seatId: seatId,
      onCollect: _money == null
          ? null
          : (amount) => _collect(
              tour: tour,
              bus: bus,
              seatId: seatId,
              riders: riders,
              amount: amount,
            ),
      // Without this the sheet's "move or swap" falls back to the LEGACY auto
      // swap-assistant — a flat list of free-seat codes as chips, on a screen
      // whose whole point is that the agent reads the bus and not a list. With
      // it, picking the destination bus swings the Board to that bus and hands
      // the choice back to the thumb (see [_beginRelocate]).
      onRelocateToBus: _beginRelocate,
      // Strike one leg off THIS berth. The Board reads the same shared gate and
      // calls the same controller method as the seat chart, so a leg cancelled
      // from either surface lands identically.
      onCancelSeatLeg: (occ, strike) => unawaited(
        _cancelSeatLeg(tour: tour, bus: bus, seatId: seatId, occ: occ,
            strike: strike),
      ),
    );
  }

  /// Cancel one leg of one berth from the Board, with a confirm first. The
  /// berth the rider actually travelled survives — see [cancelSeatLegTransform].
  Future<void> _cancelSeatLeg({
    required Tour tour,
    required Bus bus,
    required String seatId,
    required Passenger occ,
    required TripType strike,
  }) async {
    final cancellingReturn = strike == TripType.returnOnly;
    final ok = await UgamDialog.confirm(
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
    );
    final ctrl = _tours;
    if (!ok || ctrl == null || !mounted) return;
    await ctrl.cancelSeatLeg(
      tour.id,
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
  }

  BoardBerth _riderBerth({
    required Bus bus,
    required Passenger rider,
    required String seatId,
    required SeatCell cell,
    required Map<String, String> groupNames,
  }) {
    final groupId = rider.groupId;
    return BoardBerth(
      code: seatId,
      isOccupied: true,
      occupantName: rider.displayName,
      fareDue: bus.amountDueForSeat(rider, seatId),
      paid: _money?.collectionFor(rider, bus.id, seatId)?.netCollected ?? 0,
      pickupStopId: rider.pickupLocationId,
      pickupStopName: rider.pickupLocationName,
      groupId: groupId,
      groupName: groupId == null ? null : groupNames[groupId],
      seatTypeLabel: cell.typeLabel,
    );
  }

  // ── Money (spec §8) ─────────────────────────────────────────

  /// Records [amount] against whoever on this berth is owed it, and hands back
  /// the undo.
  ///
  /// **Why the rider is resolved by amount.** `PassengerSheet.onCollect` reports
  /// the figure it collected but not WHICH of a shared berth's occupants it
  /// collected from — the sheet keeps that selection privately. On a solo berth
  /// (every berth on almost every bus) there is nothing to resolve. On a shared
  /// one the rider whose outstanding balance equals the amount is the one the
  /// sheet was showing. Reported upstream: the sheet should pass the occupant.
  Future<PassengerSheetUndo?> _collect({
    required Tour tour,
    required Bus bus,
    required String seatId,
    required List<Passenger> riders,
    required double amount,
  }) async {
    final money = _money;
    if (money == null || riders.isEmpty) return null;

    final rider = riders.length == 1
        ? riders.first
        : riders.firstWhereOrNull((p) {
            final due = bus.amountDueForSeat(p, seatId);
            final held = money.collectionFor(p, bus.id, seatId)?.netCollected ?? 0;
            return (due - held - amount).abs() <= Collection.kMoneyEpsilon;
          }) ??
              riders.first;

    final existing = money.collectionFor(rider, bus.id, seatId);
    final saved = buildCollectionToSave(
      existing: existing,
      tourId: tour.id,
      busId: bus.id,
      passengerId: rider.id,
      seatId: seatId,
      // The LIVE fare, never the amount snapshotted when earlier cash was
      // taken: fares are per-bus and a moved rider is re-priced.
      due: bus.amountDueForSeat(rider, seatId),
      received: (existing?.amountReceived ?? 0) + amount,
      // Only a GENUINE manual return survives; auto-booked change is
      // re-derived from the new received figure, exactly as the collection
      // screen does. Passing the stored refund straight back would freeze
      // stale change as a manual return and invent a shortfall.
      manualReturned: manualReturnToSeed(existing) ?? 0,
      collectedBy: '',
      note: existing?.note ?? '',
    );

    await money.upsertCollection(saved);

    final name = rider.displayName;
    final amountText = Formatters.formatMoneyInr(amount);
    return PassengerSheetUndo(
      message: tr(
        'passenger_sheet.collected_toast',
        namedArgs: {'amount': amountText, 'name': name},
      ),
      semanticLabel: tr(
        'board_screen.undo_collect_semantic',
        namedArgs: {'amount': amountText, 'name': name},
      ),
      // A row that did not exist before is DELETED rather than zeroed: a
      // zeroed row still posts to the ledger and still counts as "collected
      // from", which is not what "undo" means.
      undo: () => existing == null
          ? money.deleteCollection(saved.id)
          : money.upsertCollection(existing),
    );
  }
}
