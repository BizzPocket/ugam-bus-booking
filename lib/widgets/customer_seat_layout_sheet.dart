import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../design/ugam.dart';
import '../models/bus_details.dart';
import '../models/seat_layout.dart';
import '../models/seat_type.dart';
import '../services/customer_requests_store.dart';

/// Read-only seat layout viewer for the customer "My Requests" screen.
/// Shows the customer's assigned seats highlighted on the actual bus
/// layout. Seats from other passengers render as neutral, since the
/// customer should not see who else is on the bus.
Future<void> showCustomerSeatLayoutSheet(
  BuildContext context, {
  required CustomerRequestEntry entry,
}) {
  return UgamSheet.show<void>(
    context,
    title: tr('customer_my_requests.layout_sheet_title'),
    builder: (_) => _CustomerSeatLayoutSheet(entry: entry),
  );
}

class _CustomerSeatLayoutSheet extends StatefulWidget {
  final CustomerRequestEntry entry;

  const _CustomerSeatLayoutSheet({required this.entry});

  @override
  State<_CustomerSeatLayoutSheet> createState() =>
      _CustomerSeatLayoutSheetState();
}

class _CustomerSeatLayoutSheetState extends State<_CustomerSeatLayoutSheet> {
  final _store = CustomerRequestsStore();
  bool _loading = true;
  String? _error;
  List<Bus> _buses = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final buses = await _store.busLayoutsForRequest(widget.entry.id);
      if (!mounted) return;
      setState(() {
        _buses = buses;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = tr('customer_my_requests.layout_load_error');
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final assignedCount = widget.entry.assignedSeats.length;

    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            tr(
              'customer_my_requests.layout_sheet_subtitle',
              namedArgs: {'count': assignedCount.toString()},
            ),
            style: UgamText.caption.copyWith(color: c.ink2),
          ),
          const SizedBox(height: UgamSpacing.lg),
          _body(),
        ],
      ),
    );
  }

  Widget _body() {
    final c = UgamColors.of(context);
    if (_loading) {
      return const SizedBox(
        height: 200,
        child: Center(
          child: CircularProgressIndicator(),
        ),
      );
    }
    if (_error != null) {
      return SizedBox(
        height: 250,
        child: UgamEmpty(
          icon: Icons.cloud_off_rounded,
          title: tr('customer_my_requests.layout_load_error_title'),
          body: _error!,
        ),
      );
    }
    if (_buses.isEmpty) {
      return SizedBox(
        height: 250,
        child: UgamEmpty(
          icon: Icons.event_seat_outlined,
          title: tr('customer_my_requests.layout_empty_title'),
          body: tr('customer_my_requests.layout_empty_body'),
        ),
      );
    }

    final mySeats = widget.entry.assignedSeats;
    return ListView.separated(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.only(bottom: UgamSpacing.xl),
      itemCount: _buses.length,
      separatorBuilder: (_, _) => const SizedBox(height: UgamSpacing.lg),
      itemBuilder: (_, i) {
        final bus = _buses[i];
        final mineOnThisBus = mySeats
            .where((s) => s.busId == bus.id)
            .map((s) => s.seatId)
            .toSet();
        return _BusLayoutCard(bus: bus, mySeatIds: mineOnThisBus);
      },
    );
  }
}

class _BusLayoutCard extends StatefulWidget {
  final Bus bus;
  final Set<String> mySeatIds;

  const _BusLayoutCard({required this.bus, required this.mySeatIds});

  @override
  State<_BusLayoutCard> createState() => _BusLayoutCardState();
}

class _BusLayoutCardState extends State<_BusLayoutCard> {
  bool _showUpper = false;

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final layout = widget.bus.layout;
    final hasLower = layout != null && layout.lowerDeck.any((c) => c.hasSeat);
    final hasUpper = layout != null && layout.upperDeck.any((c) => c.hasSeat);
    if (!hasLower && hasUpper && !_showUpper) {
      _showUpper = true;
    }

    return Container(
      decoration: BoxDecoration(
        color: c.card,
        borderRadius: BorderRadius.circular(UgamRadius.card),
        border: Border.all(color: c.border),
      ),
      padding: const EdgeInsets.all(UgamSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _busHeader(),
          if (layout == null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: UgamSpacing.md),
              child: Text(
                tr('customer_my_requests.layout_unavailable'),
                style: UgamText.body.copyWith(color: c.ink2),
              ),
            )
          else ...[
            if (hasLower && hasUpper) ...[
              const SizedBox(height: UgamSpacing.md),
              _deckToggle(),
            ],
            const SizedBox(height: UgamSpacing.lg),
            _SeatGrid(
              layout: layout,
              isUpper: _showUpper,
              mySeatIds: widget.mySeatIds,
            ),
            const SizedBox(height: UgamSpacing.md),
            _legend(),
          ],
        ],
      ),
    );
  }

  Widget _busHeader() {
    final c = UgamColors.of(context);
    final mine = widget.mySeatIds.toList()..sort();
    return Row(
      children: [
        Icon(
          Icons.directions_bus_rounded,
          size: 20,
          color: c.accent,
        ),
        const SizedBox(width: UgamSpacing.sm),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.bus.busNumber.isNotEmpty
                    ? '${widget.bus.name} · ${widget.bus.busNumber}'
                    : widget.bus.name,
                style: UgamText.titleS.copyWith(color: c.ink),
              ),
              if (mine.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    tr(
                      'customer_my_requests.layout_your_seats',
                      namedArgs: {'seats': mine.join(', ')},
                    ),
                    style: UgamText.caption.copyWith(
                      color: c.accent,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _deckToggle() {
    return UgamTabPills(
      currentIndex: _showUpper ? 1 : 0,
      onChanged: (i) {
        setState(() {
          _showUpper = i == 1;
        });
      },
      items: [
        UgamTabItem(
          label: tr('customer_my_requests.layout_deck_lower'),
          icon: Icons.layers_clear_rounded,
        ),
        UgamTabItem(
          label: tr('customer_my_requests.layout_deck_upper'),
          icon: Icons.layers_rounded,
        ),
      ],
    );
  }

  Widget _legend() {
    final c = UgamColors.of(context);
    return Wrap(
      spacing: UgamSpacing.md,
      runSpacing: UgamSpacing.xs,
      children: [
        _legendItem(
          color: c.accent,
          label: tr('customer_my_requests.layout_legend_mine'),
        ),
        _legendItem(
          color: c.cardElev,
          border: c.border,
          label: tr('customer_my_requests.layout_legend_other'),
        ),
      ],
    );
  }

  Widget _legendItem({
    required Color color,
    Color? border,
    required String label,
  }) {
    final c = UgamColors.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 14,
          height: 14,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(4),
            border: border != null ? Border.all(color: border) : null,
          ),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: UgamText.caption.copyWith(color: c.ink2),
        ),
      ],
    );
  }
}

class _SeatGrid extends StatelessWidget {
  final BusLayout layout;
  final bool isUpper;
  final Set<String> mySeatIds;

  const _SeatGrid({
    required this.layout,
    required this.isUpper,
    required this.mySeatIds,
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final deck = isUpper ? layout.upperDeck : layout.lowerDeck;
    final cols = layout.cols;
    var maxRow = -1;
    for (final cell in deck) {
      if (cell.hasSeat && cell.row > maxRow) maxRow = cell.row;
    }
    if (maxRow < 0) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: UgamSpacing.md),
        child: Center(
          child: Text(
            tr('customer_my_requests.layout_deck_empty'),
            style: UgamText.caption.copyWith(color: c.ink3),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(UgamSpacing.md),
      decoration: BoxDecoration(
        color: c.cardElev,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: c.border),
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              Icon(
                Icons.account_circle_rounded,
                size: 16,
                color: c.ink3,
              ),
              const SizedBox(width: 6),
              Text(
                tr('customer_my_requests.layout_driver').toUpperCase(),
                style: UgamText.micro.copyWith(
                  letterSpacing: 1,
                  color: c.ink3,
                ),
              ),
            ],
          ),
          const SizedBox(height: UgamSpacing.sm),
          Divider(height: 1, color: c.border),
          const SizedBox(height: UgamSpacing.md),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Column(
              children: [
                for (int r = 0; r <= maxRow; r++) ...[
                  _row(context, deck, r, cols),
                  if (r < maxRow) const SizedBox(height: 6),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _row(BuildContext context, List<SeatCell> deck, int row, int cols) {
    final children = <Widget>[];
    final aisleAt = cols ~/ 2;
    for (int col = 0; col < cols; col++) {
      if (col == aisleAt) {
        children.add(const SizedBox(width: 18));
      }
      final cell = deck.firstWhere(
        (s) => s.row == row && s.col == col,
        orElse: () => SeatCell(row: row, col: col),
      );
      children.add(_cellWidget(context, cell));
      if (col < cols - 1 && col != aisleAt - 1) {
        children.add(const SizedBox(width: 6));
      }
    }
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: children,
    );
  }

  Widget _cellWidget(BuildContext context, SeatCell cell) {
    final c = UgamColors.of(context);
    const double w = 46;
    const double h = 40;
    if (cell.isEmpty) {
      return const SizedBox(width: w, height: h);
    }
    final isMine = cell.seatId != null && mySeatIds.contains(cell.seatId);
    final bg = isMine ? c.accent : c.card;
    final border = isMine ? c.accent : c.border;
    final fg = isMine ? c.onAccent : c.ink2;
    return Container(
      width: w,
      height: h,
      decoration: BoxDecoration(
        color: bg,
        border: Border.all(color: border, width: isMine ? 1.5 : 1),
        borderRadius: BorderRadius.circular(UgamRadius.seat),
      ),
      alignment: Alignment.center,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            cell.seatId ?? '',
            style: UgamText.tabular(
              UgamText.bodyStrong.copyWith(
                fontSize: 11,
                color: fg,
              ),
            ),
          ),
          if (cell.seatType != null)
            Text(
              _shortType(cell.seatType!),
              style: UgamText.micro.copyWith(
                fontSize: 7,
                fontWeight: FontWeight.w700,
                color: fg.withValues(alpha: 0.8),
                letterSpacing: 0.4,
              ),
            ),
        ],
      ),
    );
  }

  String _shortType(SeatType t) {
    switch (t) {
      case SeatType.singleSofa:
        return 'SINGLE';
      case SeatType.doubleSofa:
        return 'DOUBLE';
      case SeatType.seater:
        return 'SEATER';
    }
  }
}
