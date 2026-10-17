import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../controllers/money_controller.dart';
import '../controllers/pickup_controller.dart';
import '../design/ugam.dart';
import '../models/bus_details.dart';
import '../models/collection.dart';
import '../models/passenger.dart';
import '../models/payment_claim.dart';
import '../models/tour.dart';
import '../models/trip_type.dart';
import '../utils/app_snackbar.dart';
import '../utils/collection_seat_resolver.dart';
import '../utils/formatters.dart';
import '../utils/passenger_display.dart';
import '../utils/seat_money_state.dart';
import '../widgets/board/passenger_sheet.dart' show BoardUndoToast;
import '../widgets/money_loading_skeleton.dart';

String? _tripLabel(TripType t) {
  switch (t) {
    case TripType.roundTrip:
      return null;
    case TripType.outboundOnly:
      return tr('collection.trip_outbound_only');
    case TripType.returnOnly:
      return tr('collection.trip_return_only');
  }
}

/// Per-bus cash collection from passengers. Lists every passenger holding
/// a seat on this bus, shows what they owe vs. what's been received, and
/// lets the handler record received/returned cash via a bottom sheet. All
/// figures derive from [MoneyController]'s `collections` obs list.
class CollectionScreen extends StatefulWidget {
  final Tour tour;
  final Bus bus;

  /// When set, opens on the To collect / To return filter for this rider so a
  /// seat-move money notice can deep-link straight to who needs settling.
  final String? highlightPassengerId;

  const CollectionScreen({
    super.key,
    required this.tour,
    required this.bus,
    this.highlightPassengerId,
  });

  @override
  State<CollectionScreen> createState() => _CollectionScreenState();
}

class _CollectionScreenState extends State<CollectionScreen> {
  final MoneyController controller = Get.find<MoneyController>();

  /// 0 = All, 1 = To return, 2 = To collect
  int _filter = 0;

  /// Applies [highlightPassengerId] once after the first non-loading frame.
  bool _highlightApplied = false;

  /// True only when the money load failed AND nothing is already held — so a
  /// transient read failure shows a retry instead of a roster that falsely reads
  /// as "nobody has paid". Reads the money obs inside the calling [Obx] to stay
  /// reactive across a retry.
  bool get _showLoadError =>
      controller.loadFailed.value &&
      controller.collections.isEmpty &&
      controller.expenses.isEmpty &&
      controller.handovers.isEmpty &&
      controller.incomes.isEmpty;

  @override
  void initState() {
    super.initState();
    // Warm the global pickup list once so the per-name code tags can resolve.
    if (Get.isRegistered<PickupController>()) {
      Get.find<PickupController>().ensureLoaded();
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      controller.loadForTour(widget.tour.id);
    });
  }

  List<_SeatCollectionLine> get _seatLines {
    final lines = <_SeatCollectionLine>[];
    for (final p in widget.tour.passengers) {
      // Distinct PHYSICAL seats only: a whole double-sofa is two assignment
      // entries on one seat, and amountDueForSeat already charges the full sofa
      // once — so a line per entry would bill it twice.
      //
      // Deduplicated on the BASE id. The app writes both berths under the
      // identical seatId, but the older `#n` berth-suffix form still exists in
      // the data (diagnostics CHECK 10), and on the raw string those read as two
      // seats — two rows for one rider, each at the full sofa price, doubling
      // this bus's shortfall the moment they are part-paid. Every other reader
      // already normalises: `Bus.amountDueFor`, `collectionRowForSeat`, and
      // 062's SQL all strip the suffix first.
      final seatIds = <String>{
        for (final a in p.assignedSeats)
          if (a.busId == widget.bus.id) baseSeatId(a.seatId),
      };
      for (final seatId in seatIds) {
        final due = widget.bus.amountDueForSeat(p, seatId);
        lines.add(
          _SeatCollectionLine(
            passenger: p,
            seatId: seatId,
            due: due,
            col: controller.collectionFor(p, widget.bus.id, seatId),
            pendingClaim: controller.pendingClaimForPassenger(p.id),
          ),
        );
      }
    }
    lines.sort((a, b) => a.seatId.compareTo(b.seatId));
    return lines;
  }

  bool _passesFilter(_SeatCollectionLine line) {
    switch (_filter) {
      case 1: // To return
        return line.isReturnDue;
      case 2: // To collect
        return line.isShortfall;
      default:
        return true;
    }
  }

  /// Pick To collect / To return when deep-linking a rider after a seat move.
  void _applyHighlightIfNeeded() {
    if (_highlightApplied) return;
    final id = widget.highlightPassengerId;
    if (id == null || id.isEmpty) {
      _highlightApplied = true;
      return;
    }
    final mine = _seatLines.where((l) => l.passenger.id == id).toList();
    if (mine.isEmpty) {
      // Roster not ready yet (or rider not on this bus) — try again next frame.
      return;
    }
    _highlightApplied = true;
    final next = mine.any((l) => l.isShortfall)
        ? 2
        : mine.any((l) => l.isReturnDue)
            ? 1
            : 0;
    if (next == _filter) return;
    // Never setState during Obx build — schedule after this frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _filter == next) return;
      setState(() => _filter = next);
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return UgamScaffold(
      body: SafeArea(
        child: Column(
          children: [
            UgamAppBar(
              eyebrow: tr('collection.eyebrow'),
              title: tr(
                'collection.app_bar_title',
                namedArgs: {'bus': widget.bus.name},
              ),
            ),
            Expanded(
              child: Obx(() {
                if (controller.isLoading.value &&
                    !controller.loadedOnce.value) {
                  return const MoneyLoadingSkeleton();
                }
                // A failed load leaves the collections empty; show the shared
                // retry rather than a roster where every seat falsely reads as
                // "not collected".
                if (_showLoadError) {
                  return UgamEmpty.error(
                    onRetry: () => controller.loadForTour(widget.tour.id),
                  );
                }

                _applyHighlightIfNeeded();

                final s = controller.summaryForBus(widget.bus.id);
                // Kept apart so the empty state can tell "the filter is hiding
                // them" from "nobody is seated on this bus at all" — two very
                // different situations that used to share one sentence.
                final allLines = _seatLines;
                final lines = allLines.where(_passesFilter).toList();

                return Column(
                  children: [
                    // Pinned compact summary — stays put while the roster scrolls.
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                        UgamSpacing.gutter,
                        UgamSpacing.sm,
                        UgamSpacing.gutter,
                        UgamSpacing.md,
                      ),
                      child: _SummaryHeader(
                        collected: s.collected,
                        toReturn: s.toReturnTotal,
                        toCollect: s.toCollectTotal,
                      ),
                    ),
                    // Filter pills sit directly above the roster they control.
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                        UgamSpacing.gutter,
                        0,
                        UgamSpacing.gutter,
                        UgamSpacing.md,
                      ),
                      child: UgamTabPills(
                        currentIndex: _filter,
                        onChanged: (i) => setState(() => _filter = i),
                        items: [
                          UgamTabItem(label: tr('collection.filter_all')),
                          UgamTabItem(label: tr('collection.filter_to_return')),
                          UgamTabItem(
                            label: tr('collection.filter_to_collect'),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: lines.isEmpty
                          ? (allLines.isEmpty
                              // Genuinely zero: there is no roster to filter.
                              // The fix lives on the seat chart, so this state
                              // says so instead of offering a dead button.
                              ? UgamEmpty(
                                  icon: Icons.event_seat_outlined,
                                  title: tr('collection.empty_no_seats_title'),
                                  body: tr('collection.empty_no_seats_body'),
                                )
                              // Filtered to nothing — one action, and it is
                              // always the right one.
                              : UgamEmpty(
                                  icon: Icons.filter_alt_off_rounded,
                                  title: tr('collection.empty_no_match'),
                                  cta: UgamCTA(
                                    label: tr('collection.empty_show_all'),
                                    leadingIcon: Icons.list_rounded,
                                    onPressed: () =>
                                        setState(() => _filter = 0),
                                  ),
                                ))
                          : RefreshIndicator(
                              // Chrome, not ownership — the pull spinner is
                              // neutral ink2 in every screen, so it never
                              // changes hue between tabs.
                              color: c.ink2,
                              onRefresh: () =>
                                  controller.refreshForTour(widget.tour.id),
                              child: ListView.separated(
                                physics: const AlwaysScrollableScrollPhysics(
                                  parent: BouncingScrollPhysics(),
                                ),
                                padding: const EdgeInsets.fromLTRB(
                                  UgamSpacing.gutter,
                                  0,
                                  UgamSpacing.gutter,
                                  UgamSpacing.huge,
                                ),
                                itemCount: lines.length,
                                separatorBuilder: (_, _) =>
                                    const SizedBox(height: UgamSpacing.md),
                                itemBuilder: (_, i) {
                                  final line = lines[i];
                                  return _PassengerRow(
                                    line: line,
                                    bus: widget.bus,
                                    onTap: () =>
                                        _openCollectSheet(context, line),
                                    onMarkPaid: () => _markPaid(line),
                                    // Only a seat that actually holds recorded
                                    // money has anything to undo.
                                    onUndoPayment: line.hasRecordedMoney
                                        ? () => _confirmUndoPayment(line)
                                        : null,
                                  );
                                },
                              ),
                            ),
                    ),
                  ],
                );
              }),
            ),
          ],
        ),
      ),
    );
  }

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

class _SeatCollectionLine {
  final Passenger passenger;
  final String seatId;

  /// LIVE fare for this seat on THIS bus, from `Bus.amountDueForSeat`.
  final double due;

  final Collection? col;

  /// Unverified UPI assertion — show as warm hint; never treat as paid.
  final PaymentClaim? pendingClaim;

  const _SeatCollectionLine({
    required this.passenger,
    required this.seatId,
    required this.due,
    required this.col,
    this.pendingClaim,
  });

  /// Cash actually held for this seat (`received − refunded`).
  double get net => netCollectedOf(col);

  /// Paid-vs-owed against the LIVE fare rather than the stored `amount_due`
  /// snapshot — see [liveBalanceOf], which the handler's seat dots share, so
  /// the two surfaces can never disagree about who still owes.
  double get liveBalance => liveBalanceOf(due, col);

  bool get isReturnDue => liveBalance > Collection.kMoneyEpsilon;
  bool get isShortfall => liveBalance < -Collection.kMoneyEpsilon;

  /// True when this seat has a collection row carrying real cash (received or
  /// handed back) — the rows an "undo payment" can reverse.
  bool get hasRecordedMoney =>
      col != null &&
      ((col!.amountReceived).abs() > Collection.kMoneyEpsilon ||
          (col!.amountRefunded).abs() > Collection.kMoneyEpsilon);

  double get changeToReturn => isReturnDue ? liveBalance : 0;
  double get stillToCollect => isShortfall ? -liveBalance : 0;
}

class _SummaryHeader extends StatelessWidget {
  final double collected;
  final double toReturn;
  final double toCollect;

  const _SummaryHeader({
    required this.collected,
    required this.toReturn,
    required this.toCollect,
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final settled = toCollect.abs() <= 0.005;
    // Outstanding cash is a semantic state (danger — "something needs you"),
    // not an ownership. Matches the live pill inside the collect sheet, so the
    // header figure and the sheet agree on what red means.
    final figureColor = settled ? c.good : c.danger;

    // ── ONE compact summary card ───────────────────────────────────────
    // Hero = the action number (still to collect); collected / to-return are
    // quiet inline chips on the row below, no longer a separate stat grid.
    return UgamCard.plain(
      elev: true,
      padding: const EdgeInsets.all(UgamSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              // Decorative leading glyph tile — [UgamScale.px], so it tracks
              // the label text beside it instead of staying chunky at full
              // size while that text shrinks on a narrow phone.
              Container(
                width: UgamScale.px(context, 42),
                height: UgamScale.px(context, 42),
                decoration: BoxDecoration(
                  color: settled ? c.goodFill : c.dangerFill,
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: Icon(
                  Icons.account_balance_wallet_rounded,
                  size: UgamScale.px(context, 20),
                  color: figureColor,
                ),
              ),
              const SizedBox(width: UgamSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // The eyebrow over the screen's hero figure → the
                    // script-safe [UgamText.label] step (Inter 13 / w700 /
                    // zero tracking), not `micro`. This site was the ladder's
                    // worst case in one line: `.toUpperCase()` (a no-op in
                    // Gujarati), a forked `letterSpacing` (tracking splits
                    // conjuncts), and a hand-set w700 on a 10px Sora step that
                    // renders at 8.5 on a small phone. All three are gone; the
                    // emphasis is weight + `ink2`, the one device that
                    // survives a fallback Indic face.
                    Text(
                      tr('collection.filter_to_collect'),
                      style: UgamText.label.copyWith(color: c.ink2),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: UgamSpacing.xs),
                    // LADDER GAP: this was a raw `fontSize: 30`. The numeric
                    // ladder runs numLg 20 → numXl 26 → hero 56, so 30 is not
                    // a step and there is nothing between 26 and 56 for a
                    // "card hero figure". Taken to numXl (26) rather than
                    // hardcoded; if a 30-ish numeric step is wanted it belongs
                    // in UgamText, not here.
                    // scaleDown, not ellipsis: an ellipsised total is a WRONG
                    // total, and this is the number the handler settles on.
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text(
                        Formatters.formatMoneyInr(toCollect),
                        style: UgamText.tabular(
                          UgamText.numXl.copyWith(color: figureColor),
                        ),
                        maxLines: 1,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: UgamSpacing.md),
          Divider(height: 1, thickness: 1, color: c.border),
          const SizedBox(height: UgamSpacing.md),
          // ── Demoted pair: inline chips, single row ─────────────────────
          Row(
            children: [
              Expanded(
                child: _SummaryChip(
                  icon: Icons.payments_rounded,
                  label: tr('collection.collected'),
                  value: Formatters.formatMoneyInr(collected),
                  tone: c.good,
                ),
              ),
              const SizedBox(width: UgamSpacing.lg),
              Expanded(
                child: _SummaryChip(
                  icon: Icons.undo_rounded,
                  label: tr('collection.filter_to_return'),
                  value: Formatters.formatMoneyInr(toReturn),
                  tone: c.warm,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// One demoted figure inside [_SummaryHeader]: a tinted glyph, a tabular
/// value, and a micro caps label — the inline replacement for the old
/// separate [UgamStatTile] row.
class _SummaryChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color tone;

  const _SummaryChip({
    required this.icon,
    required this.label,
    required this.value,
    required this.tone,
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return Row(
      children: [
        Icon(icon, size: 16, color: tone),
        const SizedBox(width: UgamSpacing.sm),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  value,
                  style: UgamText.tabular(
                    UgamText.bodyStrong.copyWith(color: c.ink),
                  ),
                  maxLines: 1,
                ),
              ),
              const SizedBox(height: 1),
              // The label half of a value pair → [captionStrong] (12, the
              // documented script floor), not `micro`, which is Latin-only.
              Text(
                label,
                style: UgamText.captionStrong.copyWith(color: c.ink2),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _PassengerRow extends StatelessWidget {
  final _SeatCollectionLine line;
  final Bus bus;
  final VoidCallback onTap;
  final VoidCallback onMarkPaid;

  /// Reverse the money recorded on this seat. Null when nothing is recorded.
  final VoidCallback? onUndoPayment;

  const _PassengerRow({
    required this.line,
    required this.bus,
    required this.onTap,
    required this.onMarkPaid,
    this.onUndoPayment,
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final passenger = line.passenger;
    // Global pickup-code lookup for the trailing name tag; null (degrade to
    // name-only) when the controller isn't registered.
    final pickup = Get.isRegistered<PickupController>()
        ? Get.find<PickupController>()
        : null;
    final due = line.due;
    final col = line.col;
    final received = col?.amountReceived ?? 0;
    final returned = col?.amountRefunded ?? 0;
    final trip = _tripLabel(passenger.tripType);
    // Everything below reads the LIVE balance (see _SeatCollectionLine), so a
    // rider carried in from another bus shows the DIFFERENCE at this bus's
    // band — not the full fare over again, and not a stale "settled".
    final isShortfall = line.isShortfall;
    final shortfall = line.stillToCollect;

    // Status chip resolution. UgamReqChip carries the tone via variant, and
    // every state here has a real semantic token: money handed back is warm,
    // money still owed is danger, settled is good, untouched is neutral. The
    // "due" state used to borrow the accent on the stated grounds that the
    // chip set had no danger tone — [UgamChipVariant.danger] exists, so that
    // note was stale and the amber was buying nothing.
    late final String chipLabel;
    late final UgamChipVariant chipVariant;
    if (line.isReturnDue) {
      chipLabel = tr(
        'collection.chip_return',
        namedArgs: {'amount': Formatters.formatMoneyInr(line.changeToReturn)},
      );
      chipVariant = UgamChipVariant.warm;
    } else if (isShortfall) {
      chipLabel = tr(
        'collection.chip_due',
        namedArgs: {'amount': Formatters.formatMoneyInr(shortfall)},
      );
      chipVariant = UgamChipVariant.danger;
    } else if (received > 0) {
      chipLabel = tr('collection.chip_paid');
      chipVariant = UgamChipVariant.good;
    } else {
      chipLabel = tr('collection.chip_not_collected');
      chipVariant = UgamChipVariant.neutral;
    }

    final card = UgamCard.plain(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Name stays flexible so it can never overflow, but wraps to
                    // 2 lines before it ellipsises (app-wide rule — see
                    // UgamRequestRow); the pickup-CODE tag is a fixed trailing
                    // chip that baseline-aligns to the name's first line.
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: [
                        Flexible(
                          child: Text(
                            passenger.displayName,
                            style: UgamText.titleS.copyWith(color: c.ink),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        // Only with a live controller — an Obx whose closure
                        // reads no observable throws (see PickupController.
                        // codeFor).
                        if (pickup != null)
                          Obx(() {
                            final code = pickup.codeFor(
                              passenger.pickupLocationId,
                            );
                            if (code == null || code.isEmpty) {
                              return const SizedBox.shrink();
                            }
                            return Padding(
                              padding: const EdgeInsets.only(
                                left: UgamSpacing.sm,
                              ),
                              child: UgamReqChip(
                                label: code,
                                variant: UgamChipVariant.neutral,
                              ),
                            );
                          }),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      passenger.phone.trim().isEmpty
                          ? tr(
                              'collection.seat_label',
                              namedArgs: {'seat': line.seatId},
                            )
                          : tr(
                              'collection.phone_seat_label',
                              namedArgs: {
                                'phone': passenger.phone,
                                'seat': line.seatId,
                              },
                            ),
                      style: UgamText.caption.copyWith(color: c.ink2),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (trip != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          trip,
                          // A status word that must hold against the caption
                          // copy around it → [captionStrong]. `micro` is
                          // Latin-only and "ફક્ત પાછા આવવાનું" is not.
                          style: UgamText.captionStrong.copyWith(color: c.warm),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    // The unverified-UPI hint moved DOWN here, onto the same
                    // line as the rest of the rider's detail — the pattern
                    // [UgamRequestRow] already uses for secondary chips.
                    //
                    // It used to be a second natural-width chip in the trailing
                    // cluster. Row lays non-flex children out with UNBOUNDED
                    // main-axis constraints, so a money chip + this chip + the
                    // 44pt settle button could together exceed the card at
                    // 320px with Gujarati labels at the 1.3x text scale
                    // app.dart permits: the Expanded name got 0 and the row
                    // overflowed. Only ONE natural-width chip rides the top
                    // line now, and it can no longer be starved.
                    if (line.pendingClaim != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 3),
                        child: UgamReqChip(
                          label: tr(
                            'collection.upi_pending_chip',
                            namedArgs: {
                              'n': Formatters.formatMoneyInr(
                                line.pendingClaim!.amountRupees,
                              ),
                            },
                          ),
                          variant: UgamChipVariant.warm,
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: UgamSpacing.sm),
              UgamReqChip(label: chipLabel, variant: chipVariant),
              // Settle-in-full, on the row. 44×44 (the touch floor) and 8dp
              // clear of the chip beside it, so it can be hit one-handed
              // without opening the sheet by mistake.
              if (isShortfall) ...[
                const SizedBox(width: UgamSpacing.sm),
                UgamIconButton(
                  key: ValueKey('mark-paid-${line.seatId}-${passenger.id}'),
                  icon: Icons.check_rounded,
                  // A BUTTON — never the brand hue. The danger chip beside it
                  // already says how much is owed; the control itself is plain
                  // chrome, exactly as `action` is a neutral in the palette.
                  tone: UgamIconButtonTone.neutral,
                  semanticLabel: tr(
                    'collection.mark_paid',
                    namedArgs: {
                      'amount': Formatters.formatMoneyInr(shortfall),
                    },
                  ),
                  onTap: onMarkPaid,
                ),
              ],
              // Undo, in the SAME slot the ✓ occupies on an owing row — so a
              // Paid / To-return row gets its reverse control exactly where the
              // settle control was, and the two never share a row (no extra
              // width at 320px). Confirmed by a dialog before anything moves.
              //
              // GHOST, not a filled disc: a paid row is finished business, so
              // its reverse control must not shout as loud as the ✓ on an
              // owing row. Same 44pt hit box (the touch floor), but no fill and
              // a muted ink — it is there when wanted, invisible when scanning.
              if (!isShortfall && onUndoPayment != null) ...[
                const SizedBox(width: UgamSpacing.sm),
                UgamIconButton(
                  key: ValueKey('undo-paid-${line.seatId}-${passenger.id}'),
                  icon: Icons.undo_rounded,
                  tone: UgamIconButtonTone.neutral,
                  fillOverride: Colors.transparent,
                  inkOverride: c.ink3,
                  iconSize: 17,
                  semanticLabel: tr('collection.undo_payment_title'),
                  onTap: onUndoPayment!,
                ),
              ],
            ],
          ),
          // Fare · Received (· Returned) on ONE caption line. This used to be
          // a two-column label-over-value block that labelled the FARE "Due",
          // so a paid rider read "Due ₹3,400" and an unpaid one saw the same
          // figure twice (chip + metric). The chip owns "how much is owed";
          // this line is the record: what the seat costs and what came in.
          // Money handed back appears only when there is some.
          const SizedBox(height: 3),
          Text.rich(
            TextSpan(
              children: [
                _metricSpan(
                  tr('collection.metric_fare'),
                  Formatters.formatMoneyInr(due),
                  c,
                ),
                _metricSep(c),
                _metricSpan(
                  tr('collection.received'),
                  Formatters.formatMoneyInr(received),
                  c,
                ),
                if (returned > 0) ...[
                  _metricSep(c),
                  _metricSpan(
                    tr('collection.metric_returned'),
                    Formatters.formatMoneyInr(returned),
                    c,
                  ),
                ],
              ],
            ),
            style: UgamText.tabular(UgamText.caption.copyWith(color: c.ink2)),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );

    // Nothing owed → a plain row, no action affordance at all.
    if (!isShortfall) return card;

    // One-tap full settlement. It rides ON the row (44×44, next to the status
    // chip) instead of a full-width button stacked underneath: the row is a
    // list item in a long seat list, and a stacked CTA per seat turned the
    // list into a column of web cards. Swipe-right settles too.
    return UgamSwipeAction(
      key: ValueKey('collect-swipe-${line.seatId}-${passenger.id}'),
      rightIcon: Icons.check_rounded,
      rightLabel: tr(
        'collection.mark_paid',
        namedArgs: {'amount': Formatters.formatMoneyInr(shortfall)},
      ),
      onRight: onMarkPaid,
      borderRadius: BorderRadius.circular(UgamRadius.card),
      child: card,
    );
  }
}

/// "Fare ₹3,400" — the label in the caption ink, the figure a step stronger so
/// the money still leads. Wraps (maxLines 2 on the host) rather than losing a
/// digit at the 1.3x text scale.
InlineSpan _metricSpan(String label, String value, UgamColorSet c) => TextSpan(
  children: [
    TextSpan(text: '$label '),
    TextSpan(
      text: value,
      style: UgamText.captionStrong.copyWith(color: c.ink),
    ),
  ],
);

InlineSpan _metricSep(UgamColorSet c) =>
    TextSpan(text: '  ·  ', style: TextStyle(color: c.ink3));
