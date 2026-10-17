part of '../add_bus_screen.dart';

/// Regenerate + save for the wizard. Split out of [_AddBusScreenState] so the
/// screen file reads as form state + build; behaviour is unchanged.
extension _AddBusSave on _AddBusScreenState {
  // ── Regenerate layout (edit only) ───────────────────────────────────

  /// Force-rebuild this bus's seat layout from the current form settings
  /// (capacity + single count + the all-double-back-row toggle). Used to migrate
  /// a bus whose layout was saved under the OLD seat engine onto the current one.
  ///
  /// Renumbers every berth, so any passenger currently seated on THIS bus is
  /// freed and must be re-assigned. Shows its own destructive confirm; on accept
  /// it sets [_forceRegenerate] and runs the normal [_save] (which then skips its
  /// own resize prompt because the warning was already shown here).
  Future<void> _regenerateLayout() async {
    final seated = _seatedOnThisBus;
    final ok = await UgamDialog.confirm(
      context,
      title: tr('add_bus.regenerate_confirm_title'),
      message: seated > 0
          ? tr(
              'add_bus.regenerate_confirm_msg',
              namedArgs: {'count': '$seated'},
            )
          : tr('add_bus.regenerate_confirm_msg_empty'),
      confirmLabel: tr('add_bus.regenerate_confirm_cta'),
      destructive: true,
    );
    if (ok != true) return;
    _update(() => _forceRegenerate = true);
    await _save();
  }

  // ── Save ────────────────────────────────────────────────────────────

  Future<void> _save() async {
    // Layout-buildability is enforced inline on Step 2 (see _canAdvance);
    // this guard is a final safety net and surfaces no toast.
    if (!widget.isEditing && _singleSofaInvalid) {
      _forceRegenerate = false;
      return;
    }

    // Re-run the plate check here as well as on blur: the agent can reach Save
    // from Step 3 without the identity field ever losing focus (tapping Next
    // while the keyboard is up), and a collision must not reach the wire.
    if (!_validateBusNumber()) {
      _forceRegenerate = false;
      // Send them to the field that is wrong instead of leaving a dead Save.
      _update(() => _currentStep = 0);
      AppSnackBar.error(_busNumberError ?? tr('add_bus.snackbar.error_save'));
      return;
    }

    final tour = _tour;
    if (tour == null) {
      _forceRegenerate = false;
      AppSnackBar.error(tr('add_bus.snackbar.error_tour_not_found'));
      return;
    }

    final priceText = _price.text.trim();
    final pricePerSeat = priceText.isEmpty
        ? tour.pricePerSeat
        : (double.tryParse(priceText) ?? tour.pricePerSeat);

    // Full bus rent paid to the owner — auto-counted as a busOwner expense.
    final busPrice = double.tryParse(_busPrice.text.trim()) ?? 0;
    final boardingPoint = _boardingPoint.text.trim();

    double? parseOpt(TextEditingController c) {
      final t = c.text.trim();
      return t.isEmpty ? null : double.tryParse(t);
    }

    final singleSofaPrice = parseOpt(_singleSofaPrice);
    final doubleSofaPrice = parseOpt(_doubleSofaPrice);

    // Rear-zone: how many of the LAST rows are priced differently, and at what
    // per-person rate. Clamped to the layout's row count below (different per
    // branch — edit reuses the saved layout, add uses the freshly built one).
    final rearRowsRaw = int.tryParse(_rearRows.text.trim()) ?? 0;
    final rearPrice = rearRowsRaw <= 0 ? null : parseOpt(_rearPrice);

    final slotLabel = _effectiveSlotLabel;

    _update(() => _saving = true);
    try {
      if (widget.isEditing) {
        final source = widget.existing!;

        // The layout is rebuilt when the admin either touched a capacity field
        // (_capacityChanged) OR tapped "Regenerate layout" (_forceRegenerate) —
        // the latter forces a fresh build from the current settings so a bus
        // saved under the old seat engine adopts the current one. Otherwise the
        // saved layout is reused untouched, so seat IDs — and every existing
        // seat assignment — stay exactly as they were.
        final regenerate = _capacityChanged || _forceRegenerate;
        final newLayout = regenerate ? _generateLayout() : source.layout;

        // A real resize/regenerate renumbers the seat IDs, so anyone seated on
        // this bus would be orphaned. Confirm-then-clear those assignments first.
        final oldIds = source.layout?.allSeatIds.toSet() ?? <String>{};
        final newIds = newLayout?.allSeatIds.toSet() ?? <String>{};
        final structuralChange =
            regenerate &&
            (oldIds.length != newIds.length || !oldIds.containsAll(newIds));

        final seated = _seatedOnThisBus;
        if (structuralChange && seated > 0) {
          // The "Regenerate layout" button shows its own destructive warning
          // before calling _save, so don't double-prompt here when the rebuild
          // was forced from that button — only the in-flow resize path prompts.
          if (!_forceRegenerate) {
            final ok = await UgamDialog.confirm(
              context,
              title: tr('add_bus.resize_confirm_title'),
              message: tr(
                'add_bus.resize_confirm_msg',
                namedArgs: {'count': '$seated'},
              ),
              confirmLabel: tr('add_bus.resize_confirm_cta'),
              destructive: true,
            );
            if (ok != true) {
              if (mounted) _update(() => _saving = false);
              _forceRegenerate = false;
              return;
            }
          }
          // Frees every seat on this bus; the passengers' request lines stay
          // intact so they reappear as needing assignment and can be re-seated.
          await _tourCtrl.unassignBus(widget.tourId, source.id);
        }

        final rowCount = newLayout?.rows ?? rearRowsRaw;
        final rearRows = rearRowsRaw.clamp(0, rowCount);
        final updated = source.copyWith(
          name: slotLabel,
          busNumber: _busNumber.text.trim(),
          boardingPoint: boardingPoint,
          departureTime: _departureHhmm,
          driverName: _driverName.text.trim(),
          driverPhone: _driverPhone.text.trim(),
          isAC: _isAC,
          pricePerSeat: pricePerSeat,
          busPrice: busPrice,
          rentIncludesFuel: _rentIncludesFuel,
          singleSofaPrice: singleSofaPrice,
          doubleSofaPrice: doubleSofaPrice,
          rearRows: rearRows,
          rearPrice: rearRows == 0 ? null : rearPrice,
          priceBands: _sanitizedBands(rowCount),
          layout: newLayout,
          totalSeatsLegacy: structuralChange ? _totalSeats : null,
        );
        // `regenerate` is the editor's own record of whether it built a fresh
        // grid this save. Handing it to the controller keeps the "reused
        // untouched" promise above literally true: when false the layout column
        // never reaches the wire, so a bus whose jsonb had not loaded yet cannot
        // have its seat chart overwritten with the null we are holding.
        await _tourCtrl.updateBus(
          widget.tourId,
          updated,
          layoutChanged: regenerate,
        );
        if (!mounted) return;
        AppSnackBar.success(
          tr('add_bus.snackbar.updated', namedArgs: {'name': updated.name}),
        );
        AppNav.pop(context);
        return;
      }

      final layout = _generateLayout();

      final rearRows = rearRowsRaw.clamp(0, layout.rows);

      final bus = Bus(
        name: slotLabel,
        busNumber: _busNumber.text.trim(),
        boardingPoint: boardingPoint,
        departureTime: _departureHhmm,
        driverName: _driverName.text.trim(),
        driverPhone: _driverPhone.text.trim(),
        isAC: _isAC,
        busType: _AddBusScreenState._busType.displayName,
        totalSeatsLegacy: _totalSeats,
        pricePerSeat: pricePerSeat,
        busPrice: busPrice,
        rentIncludesFuel: _rentIncludesFuel,
        singleSofaPrice: singleSofaPrice,
        doubleSofaPrice: doubleSofaPrice,
        rearRows: rearRows,
        rearPrice: rearRows == 0 ? null : rearPrice,
        priceBands: _sanitizedBands(layout.rows),
        layout: layout,
      );

      await _tourCtrl.addBus(widget.tourId, bus);
      if (!mounted) return;
      AppSnackBar.success(
        tr('add_bus.snackbar.added', namedArgs: {'name': bus.name}),
      );
      AppNav.pop(context);
    } catch (_) {
      AppSnackBar.error(tr('add_bus.snackbar.error_save'));
    } finally {
      // Always clear the forced-regenerate intent so a later normal save (e.g.
      // a plain field edit after an error) never regenerates unexpectedly.
      _forceRegenerate = false;
      if (mounted) _update(() => _saving = false);
    }
  }

  /// Clean the edited bands for persistence: drop bands with no price, normalise
  /// each range (fromRow <= toRow) and clamp both ends to the bus's [rowCount]
  /// so an out-of-range band can never silently shadow nothing.
  List<PriceBand> _sanitizedBands(int rowCount) {
    final maxRow = (rowCount - 1).clamp(0, 1 << 30);
    final out = <PriceBand>[];
    for (final b in _priceBands) {
      if (b.price <= 0) continue;
      var lo = b.fromRow <= b.toRow ? b.fromRow : b.toRow;
      var hi = b.fromRow <= b.toRow ? b.toRow : b.fromRow;
      lo = lo.clamp(0, maxRow);
      hi = hi.clamp(0, maxRow);
      out.add(b.copyWith(fromRow: lo, toRow: hi));
    }
    return out;
  }
}
