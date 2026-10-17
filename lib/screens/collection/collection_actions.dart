part of '../collection_screen.dart';

/// Money writes for one seat line: mark paid (with undo), undo a recorded
/// payment, and the numpad settle sheet.
extension _CollectionActions on _CollectionScreenState {
  /// One-tap full settlement for a shortfall row: records the entire
  /// [_SeatCollectionLine.due] as received (no refund) and squares the line.
  /// Pure reuse of [MoneyController.upsertCollection] with the exact Collection
  /// shape the detail sheet's Save builds — no new money math or persistence.
  Future<void> _markPaid(_SeatCollectionLine line) async {
    final base =
        line.col ??
        Collection(
          tourId: widget.tour.id,
          busId: widget.bus.id,
          passengerId: line.passenger.id,
          seatId: line.seatId,
        );
    final updated = base.copyWith(
      seatId: line.seatId,
      amountDue: line.due,
      amountReceived: line.due,
      amountRefunded: 0,
    );
    // Captured BEFORE the await so no BuildContext crosses the async gap.
    final overlay = Overlay.maybeOf(context);
    final previous = line.col;
    try {
      await controller.upsertCollection(updated);
    } catch (_) {
      // upsertCollection already refetched and surfaced its own error toast.
      return;
    }
    _refreshTotals();
    if (!mounted) return;

    final name = line.passenger.displayName;
    final amountText = Formatters.formatMoneyInr(line.stillToCollect);
    // The one place a mis-tap on ✓ can be taken back. Same toast + same
    // restore rule as the Board's collect undo: a row that did not exist
    // before is DELETED (a zeroed row would still post to the ledger and still
    // read as "collected from"), an existing row is put back exactly as it was.
    BoardUndoToast.show(
      overlay,
      message: tr(
        'collection.paid_toast',
        namedArgs: {'name': name, 'amount': amountText},
      ),
      semanticLabel: tr(
        'collection.undo_paid_semantic',
        namedArgs: {'name': name, 'amount': amountText},
      ),
      onUndo: () async {
        try {
          if (previous == null) {
            await controller.deleteCollection(updated.id);
          } else {
            await controller.upsertCollection(previous);
          }
        } catch (_) {
          // Both writes surface their own error toast and refetch.
          return;
        }
        _refreshTotals();
      },
    );
  }

  /// Reverses money already recorded on a seat (a Paid / To-return row) after
  /// an explicit confirm. Soft-deletes the collection row through the same
  /// [MoneyController.deleteCollection] the Board's undo uses; 062's ledger
  /// trigger posts the reversing entry, so the append-only ledger keeps the
  /// history and nothing is destroyed server-side.
  Future<void> _confirmUndoPayment(_SeatCollectionLine line) async {
    final col = line.col;
    if (col == null) return;
    final amountText = Formatters.formatMoneyInr(line.net);
    final ok = await UgamDialog.confirm(
      context,
      title: tr('collection.undo_payment_title'),
      message: tr(
        'collection.undo_payment_body',
        namedArgs: {
          'amount': amountText,
          'name': line.passenger.displayName,
          'seat': line.seatId,
        },
      ),
      confirmLabel: tr('collection.undo_payment_confirm'),
      confirmIcon: Icons.undo_rounded,
      destructive: true,
    );
    if (!ok) return;
    try {
      await controller.deleteCollection(col.id);
    } catch (_) {
      // deleteCollection already refetched and surfaced its own error toast.
      return;
    }
    _refreshTotals();
    AppSnackBar.success(tr('collection.payment_undone'));
  }

  /// The header's "collected" figure comes from the ledger rollup, which only
  /// moves on a refetch — the local list alone updates to-collect but not
  /// collected. Best-effort and background: the write already landed.
  void _refreshTotals() {
    // ignore: unawaited_futures
    controller.refreshForTour(widget.tour.id).catchError((_) {});
  }

  /// Numpad-first settle sheet. The hero amount is the cash **received**; the
  /// optional "returned" amount + "collected by" / "note" live in a
  /// collapsible details block. [UgamAmountSheet] only hands back the received
  /// number, so the secondary fields are read off controllers we own here, and
  /// the SAME [MoneyController.upsertCollection] call the old form built runs
  /// once the sheet confirms.
  Future<void> _openCollectSheet(
    BuildContext context,
    _SeatCollectionLine line,
  ) async {
    final p = line.passenger;
    final due = line.due;
    final col = line.col;

    // Only pre-seed the "returned" field with a GENUINE manual return; the
    // auto-recorded change stays blank so a re-open re-derives it from the
    // freshly typed received amount (shared helper — handler sheet uses it too).
    final seedReturn = manualReturnToSeed(col);
    final returnedCtrl = TextEditingController(
      text: seedReturn == null ? '' : seedReturn.toStringAsFixed(0),
    );
    final collectedByCtrl = TextEditingController(text: col?.collectedBy ?? '');
    final noteCtrl = TextEditingController(text: col?.note ?? '');

    double parse(TextEditingController ctl) =>
        double.tryParse(ctl.text.trim()) ?? 0;

    final received = await UgamAmountSheet.show(
      context,
      title: p.displayName,
      dueLabel: tr('collection.amount_due'),
      due: due == due.roundToDouble() ? due.round() : due,
      initial: (col?.amountReceived ?? 0) == 0 ? null : col!.amountReceived,
      confirmLabel: tr('app.action.save'),
      // Live readout: as the handler keys in the cash received, show the change
      // to hand back (or the shortfall still owed), so it's never a silent
      // mental sum — the core "₹500 to return isn't shown" fix.
      statusBuilder: (sCtx, amount) => ValueListenableBuilder<TextEditingValue>(
        valueListenable: returnedCtrl,
        builder: (_, value, _) => _ChangeStatusPill(
          amount: amount.toDouble(),
          due: due,
          returned: double.tryParse(value.text.trim()) ?? 0,
        ),
      ),
      details: (detailCtx) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          UgamInput(
            label: tr('collection.returned_to_customer'),
            controller: returnedCtrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
            ],
          ),
          const SizedBox(height: UgamSpacing.md),
          UgamInput(
            label: tr('collection.collected_by'),
            controller: collectedByCtrl,
          ),
          const SizedBox(height: UgamSpacing.md),
          UgamInput(label: tr('collection.note'), controller: noteCtrl),
        ],
      ),
    );

    if (received == null) return;

    final base =
        col ??
        Collection(
          tourId: widget.tour.id,
          busId: widget.bus.id,
          passengerId: p.id,
          seatId: line.seatId,
        );
    final collectedBy = collectedByCtrl.text.trim();
    final note = noteCtrl.text.trim();
    final updated = base.copyWith(
      seatId: line.seatId,
      amountDue: due,
      amountReceived: received.toDouble(),
      // Overpayment becomes recorded change-returned (net settles to due) unless
      // the handler typed an explicit return — keeps the books honest and puts
      // the ₹500 handed back on the record. See [refundToRecord].
      amountRefunded: refundToRecord(
        due: due,
        received: received.toDouble(),
        manualReturned: parse(returnedCtrl),
      ),
      collectedBy: collectedBy.isEmpty ? null : collectedBy,
      note: note.isEmpty ? null : note,
    );
    await controller.upsertCollection(updated);
  }
}

/// Live status under the amount hero in the collect sheet. Reads the cash typed
/// so far against the resolved due and tells the handler exactly what to do with
/// the difference: hand back change (warm), still owed (danger), or it's
/// square (good). This is what makes "₹500 to return" visible at the moment of
/// collection instead of a silent calculation.
class _ChangeStatusPill extends StatelessWidget {
  final double amount;
  final double due;
  final double returned;

  const _ChangeStatusPill({
    required this.amount,
    required this.due,
    this.returned = 0,
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    // Mirror exactly what Save will persist: the auto-recorded change (or an
    // explicit manual return) is netted out of received before comparing to due.
    // So a typed return that leaves a shortfall never reads as "Settled", while
    // a plain overpayment still surfaces the change to hand back.
    final refund = refundToRecord(
      due: due,
      received: amount,
      manualReturned: returned,
    );
    final shortfall = due - (amount - refund);
    final IconData icon;
    final Color tone;
    // The matching tonal SURFACE token for `tone`. A hand-mixed
    // `tone.withValues(alpha: 0.12)` sat weaker than every other tonal fill in
    // the app (warm was off by a third vs warmFill), so the pill the handler
    // stares at while counting cash read washed out next to the sheet's
    // tonal buttons.
    final Color fill;
    final String label;
    if (shortfall > 0.005) {
      icon = Icons.south_west_rounded;
      // Money still owed is a SEMANTIC state, and the palette already has the
      // token for "something needs you". It was amber, which on this screen
      // competed with the amber on the seat chart, the row chips and the
      // settle button until none of them meant anything.
      tone = c.danger;
      fill = c.dangerFill;
      label = tr(
        'collection.still_to_collect',
        namedArgs: {'amount': Formatters.formatMoneyInr(shortfall)},
      );
    } else if (refund > 0.005) {
      icon = Icons.undo_rounded;
      tone = c.warm;
      fill = c.warmFill;
      label = tr(
        'collection.change_to_return',
        namedArgs: {'amount': Formatters.formatMoneyInr(refund)},
      );
    } else {
      icon = Icons.check_circle_rounded;
      tone = c.good;
      fill = c.goodFill;
      label = tr('collection.settled');
    }
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: UgamSpacing.lg,
        vertical: UgamSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(UgamRadius.chip),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: tone),
          const SizedBox(width: UgamSpacing.sm),
          Flexible(
            child: Text(
              label,
              style: UgamText.bodyStrong.copyWith(color: tone),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
