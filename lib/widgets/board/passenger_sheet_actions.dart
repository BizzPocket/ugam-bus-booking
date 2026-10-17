part of 'passenger_sheet.dart';

// The sheet's writes and navigations — every mutation goes through [_write].
extension _PassengerSheetActions on _PassengerSheetState {
  // ── Actions ─────────────────────────────────────────────────

  void _runAction(BoardAction action) {
    switch (action) {
      case BoardAction.call:
        _call();
      case BoardAction.collect:
        unawaited(_collect());
      case BoardAction.move:
        _move();
      case BoardAction.checkIn:
        unawaited(_checkIn(true));
    }
  }

  /// One tap, from any lens. This is the whole reason the sheet exists for a
  /// handler chasing a no-show.
  void _call() {
    final phone = _occ.phone;
    if (phone.isEmpty) return;
    HapticFeedback.selectionClick();
    unawaited(PhoneDialer.call(phone));
  }

  /// Money confirms first (spec §8) — a collection cannot be silently reversed
  /// downstream, so it never fires straight off the tap.
  Future<void> _collect() async {
    final amount = _berth.outstanding;
    final collect = widget.onCollect;
    if (collect == null || amount <= 0) return;

    final ok = await UgamDialog.confirm(
      context,
      title: tr('passenger_sheet.confirm_collect_title'),
      message: tr(
        'passenger_sheet.confirm_collect_body',
        namedArgs: {
          'amount': Formatters.formatMoneyInr(amount),
          'name': _displayName,
        },
      ),
      cancelLabel: tr('app.action.cancel'),
      confirmLabel: tr('passenger_sheet.confirm_collect_action'),
      confirmIcon: Icons.payments_rounded,
    );
    if (!ok || !mounted) return;

    // The occupant is captured with the amount: on a shared sofa the two
    // riders can owe the SAME figure, and only the sheet knows whose it is.
    final rider = _occ.passenger;
    await _write(
      BoardAction.collect,
      () => collect(amount, rider),
      fallback: tr(
        'passenger_sheet.collected_toast',
        namedArgs: {
          'amount': Formatters.formatMoneyInr(amount),
          'name': _displayName,
        },
      ),
    );
  }

  /// The other money action: the handler is holding change that belongs to the
  /// rider. Same confirm rule.
  Future<void> _returnChange() async {
    final amount = _berth.changeOwed;
    final give = widget.onReturnChange;
    if (give == null || amount <= 0) return;

    final ok = await UgamDialog.confirm(
      context,
      title: tr('passenger_sheet.confirm_return_title'),
      message: tr(
        'passenger_sheet.confirm_return_body',
        namedArgs: {
          'amount': Formatters.formatMoneyInr(amount),
          'name': _displayName,
        },
      ),
      cancelLabel: tr('app.action.cancel'),
      confirmLabel: tr('passenger_sheet.confirm_return_action'),
      confirmIcon: Icons.undo_rounded,
    );
    if (!ok || !mounted) return;

    // No action: handing back change is not the money lens's Collect, so the
    // sheet pops without a result and the aisle walk stays on this berth.
    await _write(
      null,
      () => give(amount),
      fallback: tr(
        'passenger_sheet.returned_toast',
        namedArgs: {
          'amount': Formatters.formatMoneyInr(amount),
          'name': _displayName,
        },
      ),
    );
  }

  Future<void> _checkIn(bool boarded) async {
    final tick = widget.onCheckIn;
    if (tick == null) return;
    await _write(
      BoardAction.checkIn,
      () => tick(boarded),
      fallback: tr(
        boarded
            ? 'passenger_sheet.checked_in_toast'
            : 'passenger_sheet.checked_out_toast',
        namedArgs: {'name': _displayName},
      ),
    );
  }

  /// The move/swap flow spans two screens today. Reuse it rather than
  /// reimplementing: destination-bus picker → swap assistant → move/swap,
  /// including across buses, with the group cascade already handled.
  void _move() {
    final mover = _occ.passenger;
    if (mover == null || _ctrl == null) return;
    // Anchor the flow to the ROOT navigator BEFORE popping. Our own context is
    // being torn down by the pop, and [SeatMoveFlow.start] opens its picker
    // against whatever it is handed — the same "deactivated widget's ancestor
    // is unsafe" trap that file documents at length.
    final root = Navigator.of(context, rootNavigator: true);
    Navigator.of(context).maybePop(
      const PassengerSheetResult(action: BoardAction.move, completed: true),
    );
    SeatMoveFlow.start(
      root.context,
      tourId: widget.tourId,
      sourceBusId: widget.busId,
      mover: mover,
      fromSeatId: widget.seatId,
      onRelocateToBus: widget.onRelocateToBus,
    );
  }

  /// Free this occupant's berth(s) — they keep their request and drop back into
  /// the pending pool, ready to be re-seated. The undo puts the exact previous
  /// allocation back, which is why it is built here from the list we replaced
  /// rather than being re-derived later.
  Future<void> _free() async {
    final override = widget.onFree;
    if (override != null) {
      await _write(
        BoardAction.move,
        override,
        fallback: tr(
          'passenger_sheet.freed_toast',
          namedArgs: {'name': _displayName, 'seat': _berth.code},
        ),
      );
      return;
    }

    final ctrl = _ctrl;
    final occ = _occ.passenger;
    if (ctrl == null || occ == null) return;

    final before = List<SeatAssignment>.from(occ.assignedSeats);
    final after = before
        .where((a) => !(a.busId == widget.busId && a.seatId == widget.seatId))
        .toList();
    if (after.length == before.length) return;

    await _write(
      BoardAction.move,
      () async {
        await ctrl.assignSeats(widget.tourId, occ.id, after);
        return PassengerSheetUndo(
          message: tr(
            'passenger_sheet.freed_toast',
            namedArgs: {'name': _displayName, 'seat': _berth.code},
          ),
          semanticLabel: tr(
            'passenger_sheet.undo_free_semantic',
            namedArgs: {'name': _displayName, 'seat': _berth.code},
          ),
          undo: () => ctrl.assignSeats(widget.tourId, occ.id, before),
        );
      },
      fallback: tr(
        'passenger_sheet.freed_toast',
        namedArgs: {'name': _displayName, 'seat': _berth.code},
      ),
    );
  }

  /// The one path every mutation goes through: run it, buzz, close the sheet so
  /// the Board can auto-advance the aisle walk, and raise the undo. A null
  /// [action] closes the sheet with no result, so the walk does not advance.
  Future<void> _write(
    BoardAction? action,
    PassengerSheetWrite body, {
    required String fallback,
  }) async {
    if (_busy) return;
    _update(() => _busy = true);

    // Captured BEFORE the await: no BuildContext crosses the async gap, and the
    // toast still lands after the sheet has popped.
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    final navigator = Navigator.of(context);

    PassengerSheetUndo? undo;
    var ok = true;
    try {
      undo = await body();
    } catch (_) {
      ok = false;
    } finally {
      if (mounted) _update(() => _busy = false);
    }

    if (!ok) {
      AppSnackBar.error(tr('passenger_sheet.write_failed'));
      return;
    }

    HapticFeedback.lightImpact();
    navigator.maybePop(
      action == null
          ? null
          : PassengerSheetResult(action: action, completed: true),
    );
    BoardUndoToast.show(
      overlay,
      message: undo?.message ?? fallback,
      onUndo: undo?.undo,
      semanticLabel: undo?.semanticLabel,
    );
  }

  Future<void> _editRequest() async {
    final tour = _ctrl?.getTour(widget.tourId);
    final p = _occ.passenger;
    if (tour == null || p == null) return;
    // Same root-navigator anchoring as [_move]: the editor is opened AFTER this
    // sheet has been popped, so it cannot be hung off our dying context.
    final root = Navigator.of(context, rootNavigator: true);
    Navigator.of(context).maybePop();
    await EditRequestSheet.show(
      context: root.context,
      tour: tour,
      passenger: p,
    );
  }

  Future<void> _togglePriority() async {
    final ctrl = _ctrl;
    final p = _livePassenger;
    if (ctrl == null || p == null) return;
    final approved = p.isPriorityApproved;
    if (!approved) {
      final ok = await UgamDialog.confirm(
        context,
        title: tr('priority.alert_title'),
        message: tr('priority.alert_msg'),
        cancelLabel: tr('app.action.cancel'),
        confirmLabel: tr('priority.alert_confirm'),
        confirmIcon: Icons.star_rounded,
      );
      if (!ok) return;
    }
    await ctrl.setPassengerPriority(widget.tourId, p.id, !approved);
    if (mounted) _update(() {});
  }

  Future<void> _toggleHandler() async {
    final ctrl = _ctrl;
    final p = _occ.passenger;
    if (ctrl == null || p == null) return;
    if (_isHandlerOfThisBus) {
      await ctrl.removeBusHandler(widget.tourId, widget.busId);
    } else {
      await ctrl.setBusHandler(widget.tourId, widget.busId, p.id);
    }
    if (mounted) _update(() {});
  }
}
