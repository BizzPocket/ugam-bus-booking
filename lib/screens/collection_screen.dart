import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../controllers/money_controller.dart';
import '../design/ugam.dart';
import '../models/bus_details.dart';
import '../models/collection.dart';
import '../models/passenger.dart';
import '../models/tour.dart';
import '../models/trip_type.dart';
import '../utils/formatters.dart';
import '../utils/passenger_display.dart';
import '../utils/seat_money_state.dart';

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

  const CollectionScreen({super.key, required this.tour, required this.bus});

  @override
  State<CollectionScreen> createState() => _CollectionScreenState();
}

class _CollectionScreenState extends State<CollectionScreen> {
  final MoneyController controller = Get.find<MoneyController>();

  /// 0 = All, 1 = To return, 2 = To collect
  int _filter = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      controller.loadForTour(widget.tour.id);
    });
  }

  List<_SeatCollectionLine> get _seatLines {
    final lines = <_SeatCollectionLine>[];
    for (final p in widget.tour.passengers) {
      // Distinct seats only: a whole double-sofa is stored as TWO assignment
      // entries on the same seatId; amountDueForSeat already charges the full
      // sofa for that case, so iterate per distinct seatId (not per entry) to
      // avoid duplicate lines / double counting.
      final seatIds = p.assignedSeats
          .where((a) => a.busId == widget.bus.id)
          .map((a) => a.seatId)
          .toSet();
      for (final seatId in seatIds) {
        final due = widget.bus.amountDueForSeat(p, seatId);
        lines.add(
          _SeatCollectionLine(
            passenger: p,
            seatId: seatId,
            due: due,
            col: controller.collectionFor(p.id, widget.bus.id, seatId),
          ),
        );
      }
    }
    lines.sort((a, b) => a.seatId.compareTo(b.seatId));
    return lines;
  }

  bool _passesFilter(_SeatCollectionLine line) {
    final col = line.col;
    switch (_filter) {
      case 1: // To return
        return col != null && col.isReturnDue;
      case 2: // To collect
        return col == null || col.balance < 0;
      default:
        return true;
    }
  }

  @override
  Widget build(BuildContext context) {
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
                final s = controller.summaryForBus(widget.bus.id);
                final lines = _seatLines.where(_passesFilter).toList();

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
                          UgamTabItem(
                            label: tr('collection.filter_to_return'),
                          ),
                          UgamTabItem(
                            label: tr('collection.filter_to_collect'),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: lines.isEmpty
                          ? UgamEmpty(
                              icon: Icons.account_balance_wallet_rounded,
                              title: tr('collection.empty_no_match'),
                            )
                          : ListView.separated(
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
                                  onTap: () => _openCollectSheet(context, line),
                                  onMarkPaid: () => _markPaid(line),
                                );
                              },
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
    await controller.upsertCollection(updated);
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

    final returnedCtrl = TextEditingController(
      text: (col?.amountRefunded ?? 0) == 0
          ? ''
          : (col!.amountRefunded).toStringAsFixed(0),
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
      statusBuilder: (sCtx, amount) =>
          _ChangeStatusPill(amount: amount.toDouble(), due: due),
      details: (detailCtx) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          UgamInput(
            label: tr('collection.returned_to_customer'),
            controller: returnedCtrl,
            keyboardType: const TextInputType.numberWithOptions(
              decimal: true,
            ),
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
          UgamInput(
            label: tr('collection.note'),
            controller: noteCtrl,
          ),
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
/// the difference: hand back change (warm), keep collecting (accent), or it's
/// square (good). This is what makes "₹500 to return" visible at the moment of
/// collection instead of a silent calculation.
class _ChangeStatusPill extends StatelessWidget {
  final double amount;
  final double due;

  const _ChangeStatusPill({required this.amount, required this.due});

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final diff = amount - due;
    final IconData icon;
    final Color tone;
    final String label;
    if (diff > 0.005) {
      icon = Icons.undo_rounded;
      tone = c.warm;
      label = tr(
        'collection.change_to_return',
        namedArgs: {'amount': Formatters.formatMoneyInr(diff)},
      );
    } else if (diff < -0.005) {
      icon = Icons.south_west_rounded;
      tone = c.accent;
      label = tr(
        'collection.still_to_collect',
        namedArgs: {'amount': Formatters.formatMoneyInr(-diff)},
      );
    } else {
      icon = Icons.check_circle_rounded;
      tone = c.good;
      label = tr('collection.settled');
    }
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: UgamSpacing.lg,
        vertical: UgamSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: tone.withValues(alpha: 0.12),
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
  final double due;
  final Collection? col;

  const _SeatCollectionLine({
    required this.passenger,
    required this.seatId,
    required this.due,
    required this.col,
  });
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
    final figureColor = settled ? c.good : c.accent;

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
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: settled ? c.goodFill : c.accentFill,
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: Icon(
                  Icons.account_balance_wallet_rounded,
                  size: 20,
                  color: figureColor,
                ),
              ),
              const SizedBox(width: UgamSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      tr('collection.filter_to_collect').toUpperCase(),
                      style: UgamText.micro.copyWith(
                        color: c.ink3,
                        letterSpacing: 0.6,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: UgamSpacing.xs),
                    Text(
                      Formatters.formatMoneyInr(toCollect),
                      style: UgamText.tabular(
                        UgamText.numLg
                            .copyWith(color: figureColor, fontSize: 30),
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
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
              Text(
                value,
                style: UgamText.tabular(
                  UgamText.bodyStrong.copyWith(color: c.ink),
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 1),
              Text(
                label.toUpperCase(),
                style: UgamText.micro.copyWith(color: c.ink3),
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

  const _PassengerRow({
    required this.line,
    required this.bus,
    required this.onTap,
    required this.onMarkPaid,
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final passenger = line.passenger;
    final due = line.due;
    final col = line.col;
    final received = col?.amountReceived ?? 0;
    final returned = col?.amountRefunded ?? 0;
    final balance = col == null ? -due : col.balance;
    final trip = _tripLabel(passenger.tripType);
    final shortfall = due - received;
    final isShortfall = balance < 0;

    // Status chip resolution. UgamReqChip carries the tone via variant; the
    // shortfall ("due") state maps to the accent attention variant since the
    // chip set has no danger tone (the row's Mark-paid action + danger metric
    // already flag the owed amount).
    late final String chipLabel;
    late final UgamChipVariant chipVariant;
    if (col != null && col.isReturnDue) {
      chipLabel = tr(
        'collection.chip_return',
        namedArgs: {'amount': Formatters.formatMoneyInr(col.changeToReturn)},
      );
      chipVariant = UgamChipVariant.warm;
    } else if (isShortfall) {
      chipLabel = tr(
        'collection.chip_due',
        namedArgs: {'amount': Formatters.formatMoneyInr(shortfall)},
      );
      chipVariant = UgamChipVariant.accent;
    } else if (col != null && col.isSquare && received > 0) {
      chipLabel = tr('collection.chip_paid');
      chipVariant = UgamChipVariant.good;
    } else {
      chipLabel = tr('collection.chip_not_collected');
      chipVariant = UgamChipVariant.neutral;
    }

    return UgamCard.plain(
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
                    Text(
                      passenger.displayName,
                      style: UgamText.titleS.copyWith(color: c.ink),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
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
                          style: UgamText.micro.copyWith(color: c.warm),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: UgamSpacing.sm),
              UgamReqChip(label: chipLabel, variant: chipVariant),
            ],
          ),
          const SizedBox(height: UgamSpacing.sm),
          Row(
            children: [
              Expanded(
                child: _MetricCol(
                  label: tr('collection.metric_due'),
                  value: Formatters.formatMoneyInr(due),
                  c: c,
                ),
              ),
              Expanded(
                child: _MetricCol(
                  label: tr('collection.received'),
                  value: Formatters.formatMoneyInr(received),
                  c: c,
                ),
              ),
              // Money handed back (change or an explicit refund) — shown only
              // when there is some, so the return is visible on the record, not
              // hidden inside the collection row.
              if (returned > 0)
                Expanded(
                  child: _MetricCol(
                    label: tr('collection.metric_returned'),
                    value: Formatters.formatMoneyInr(returned),
                    c: c,
                  ),
                ),
            ],
          ),
          // One-tap full settlement — only when the seat still owes money.
          // Tonal (never solid gold) per the accent-rationing law.
          if (isShortfall) ...[
            const SizedBox(height: UgamSpacing.md),
            UgamButton(
              label: tr(
                'collection.mark_paid',
                namedArgs: {'amount': Formatters.formatMoneyInr(shortfall)},
              ),
              icon: Icons.check_rounded,
              kind: UgamButtonKind.tonal,
              expand: true,
              onPressed: onMarkPaid,
            ),
          ],
        ],
      ),
    );
  }
}

class _MetricCol extends StatelessWidget {
  final String label;
  final String value;
  final UgamColorSet c;

  const _MetricCol({required this.label, required this.value, required this.c});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label.toUpperCase(),
          style: UgamText.micro.copyWith(color: c.ink3),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: UgamText.tabular(UgamText.bodyStrong.copyWith(color: c.ink)),
        ),
      ],
    );
  }
}

