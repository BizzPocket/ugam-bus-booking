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
import '../utils/passenger_display.dart';

String _money(num v) => '₹${v.toStringAsFixed(0)}';

String? _tripLabel(TripType t) {
  switch (t) {
    case TripType.roundTrip:
      return null;
    case TripType.outboundOnly:
      return 'Outbound only';
    case TripType.returnOnly:
      return 'Return only';
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
    final c = UgamColors.of(context);
    return Scaffold(
      backgroundColor: c.bg,
      appBar: AppBar(title: Text('Collection · ${widget.bus.name}')),
      body: SafeArea(
        top: false,
        child: Obx(() {
          final s = controller.summaryForBus(widget.bus.id);
          final lines = _seatLines.where(_passesFilter).toList();

          return ListView(
            padding: const EdgeInsets.fromLTRB(
              UgamSpacing.gutter,
              UgamSpacing.sm,
              UgamSpacing.gutter,
              UgamSpacing.huge,
            ),
            children: [
              _SummaryHeader(
                collected: s.collected,
                toReturn: s.toReturnTotal,
                toCollect: s.toCollectTotal,
              ),
              const SizedBox(height: UgamSpacing.lg),
              UgamTabPills(
                currentIndex: _filter,
                onChanged: (i) => setState(() => _filter = i),
                items: const [
                  UgamTabItem(label: 'All'),
                  UgamTabItem(label: 'To return'),
                  UgamTabItem(label: 'To collect'),
                ],
              ),
              const SizedBox(height: UgamSpacing.lg),
              if (lines.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    vertical: UgamSpacing.huge,
                  ),
                  child: Center(
                    child: Text(
                      'No passengers match this filter.',
                      style: UgamText.body.copyWith(color: c.ink2),
                    ),
                  ),
                )
              else
                ...lines.map((line) {
                  return Padding(
                    padding: const EdgeInsets.only(bottom: UgamSpacing.md),
                    child: _PassengerRow(
                      line: line,
                      bus: widget.bus,
                      onTap: () => _openCollectSheet(context, line),
                    ),
                  );
                }),
            ],
          );
        }),
      ),
    );
  }

  void _openCollectSheet(BuildContext context, _SeatCollectionLine line) {
    final p = line.passenger;
    final due = line.due;
    final col = line.col;
    final receivedCtrl = TextEditingController(
      text: (col?.amountReceived ?? 0) == 0
          ? ''
          : (col!.amountReceived).toStringAsFixed(0),
    );
    final returnedCtrl = TextEditingController(
      text: (col?.amountRefunded ?? 0) == 0
          ? ''
          : (col!.amountRefunded).toStringAsFixed(0),
    );
    final collectedByCtrl = TextEditingController(text: col?.collectedBy ?? '');
    final noteCtrl = TextEditingController(text: col?.note ?? '');

    UgamSheet.show<void>(
      context,
      title: p.displayName,
      builder: (sheetCtx) {
        final sc = UgamColors.of(sheetCtx);
        return SingleChildScrollView(
          child: StatefulBuilder(
            builder: (innerCtx, setSheetState) {
              double parse(TextEditingController ctl) =>
                  double.tryParse(ctl.text.trim()) ?? 0;
              final received = parse(receivedCtrl);
              final returned = parse(returnedCtrl);
              final balance = received - returned - due;

              final (String balLabel, Color balColor) = balance > 0
                  ? ('Change to return: ${_money(balance)}', sc.warm)
                  : balance < 0
                  ? ('Still to collect: ${_money(-balance)}', sc.danger)
                  : ('Settled', sc.good);

              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _ReadOnlyLine(label: 'Amount due', value: _money(due)),
                  const SizedBox(height: UgamSpacing.lg),
                  UgamInput(
                    label: 'Received',
                    controller: receivedCtrl,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                    ],
                    onChanged: (_) => setSheetState(() {}),
                  ),
                  const SizedBox(height: UgamSpacing.md),
                  UgamInput(
                    label: 'Returned to customer',
                    controller: returnedCtrl,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                    ],
                    onChanged: (_) => setSheetState(() {}),
                  ),
                  const SizedBox(height: UgamSpacing.md),
                  UgamInput(label: 'Collected by', controller: collectedByCtrl),
                  const SizedBox(height: UgamSpacing.md),
                  UgamInput(label: 'Note', controller: noteCtrl),
                  const SizedBox(height: UgamSpacing.lg),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                      horizontal: UgamSpacing.lg,
                      vertical: UgamSpacing.md,
                    ),
                    decoration: BoxDecoration(
                      color: balColor.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(UgamRadius.row),
                    ),
                    child: Text(
                      balLabel,
                      style: UgamText.bodyStrong.copyWith(color: balColor),
                    ),
                  ),
                  const SizedBox(height: UgamSpacing.lg),
                  UgamCTA(
                    label: 'Save',
                    onPressed: () async {
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
                        amountReceived: parse(receivedCtrl),
                        amountRefunded: parse(returnedCtrl),
                        collectedBy: collectedBy.isEmpty ? null : collectedBy,
                        note: note.isEmpty ? null : note,
                      );
                      await controller.upsertCollection(updated);
                      if (innerCtx.mounted) Navigator.of(innerCtx).pop();
                    },
                  ),
                ],
              );
            },
          ),
        );
      },
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
    return Row(
      children: [
        Expanded(
          child: UgamStatTile(
            icon: Icons.payments_rounded,
            value: _money(collected),
            label: 'Collected',
            variant: UgamStatVariant.good,
          ),
        ),
        const SizedBox(width: UgamSpacing.md),
        Expanded(
          child: UgamStatTile(
            icon: Icons.undo_rounded,
            value: _money(toReturn),
            label: 'To return',
            variant: UgamStatVariant.warm,
          ),
        ),
        const SizedBox(width: UgamSpacing.md),
        Expanded(
          child: UgamStatTile(
            icon: Icons.account_balance_wallet_rounded,
            value: _money(toCollect),
            label: 'To collect',
            variant: UgamStatVariant.accent,
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

  const _PassengerRow({
    required this.line,
    required this.bus,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final passenger = line.passenger;
    final due = line.due;
    final col = line.col;
    final received = col?.amountReceived ?? 0;
    final balance = col == null ? -due : col.balance;
    final trip = _tripLabel(passenger.tripType);

    // Status chip resolution.
    late final String chipLabel;
    late final Color chipColor;
    if (col != null && col.isReturnDue) {
      chipLabel = 'Return ${_money(col.changeToReturn)}';
      chipColor = c.warm;
    } else if (balance < 0) {
      chipLabel = 'Due ${_money(due - received)}';
      chipColor = c.danger;
    } else if (col != null && col.isSquare && received > 0) {
      chipLabel = 'Paid';
      chipColor = c.good;
    } else {
      chipLabel = 'Not collected';
      chipColor = c.ink3;
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
                          ? 'Seat ${line.seatId}'
                          : '${passenger.phone} · Seat ${line.seatId}',
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
              _StatusChip(label: chipLabel, color: chipColor),
            ],
          ),
          const SizedBox(height: UgamSpacing.sm),
          Row(
            children: [
              Expanded(
                child: _MetricCol(label: 'Due', value: _money(due), c: c),
              ),
              Expanded(
                child: _MetricCol(
                  label: 'Received',
                  value: _money(received),
                  c: c,
                ),
              ),
            ],
          ),
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

class _StatusChip extends StatelessWidget {
  final String label;
  final Color color;

  const _StatusChip({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(UgamRadius.chip),
      ),
      child: Text(
        label,
        style: UgamText.tabular(
          UgamText.caption.copyWith(color: color, fontWeight: FontWeight.w700),
        ),
      ),
    );
  }
}

class _ReadOnlyLine extends StatelessWidget {
  final String label;
  final String value;

  const _ReadOnlyLine({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: UgamText.body.copyWith(color: c.ink2)),
        Text(
          value,
          style: UgamText.tabular(UgamText.titleS.copyWith(color: c.ink)),
        ),
      ],
    );
  }
}
