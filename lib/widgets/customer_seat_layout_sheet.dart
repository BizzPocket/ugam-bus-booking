import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../components/combined_seat_grid.dart';
import '../design/ugam.dart';
import '../models/bus_details.dart';
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
  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final layout = widget.bus.layout;

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
          if (layout == null || layout.totalCells == 0)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: UgamSpacing.md),
              child: Text(
                tr('customer_my_requests.layout_unavailable'),
                style: UgamText.body.copyWith(color: c.ink2),
              ),
            )
          else ...[
            const SizedBox(height: UgamSpacing.lg),
            Container(
              padding: const EdgeInsets.all(UgamSpacing.md),
              decoration: BoxDecoration(
                color: c.cardElev,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: c.border),
              ),
              child: CombinedSeatGrid(
                layout: layout,
                driverLabel: tr('customer_my_requests.layout_driver'),
                tileBuilder: (ctx, cell) {
                  final cc = UgamColors.of(ctx);
                  final isMine = cell.seatId != null &&
                      widget.mySeatIds.contains(cell.seatId);
                  return CombinedSeatGrid.seatTile(
                    ctx,
                    label: cell.seatId ?? '',
                    subLabel: cell.seatType != null
                        ? CombinedSeatGrid.shortType(cell.seatType!)
                        : null,
                    background: isMine ? cc.accent : cc.card,
                    border: isMine ? cc.accent : cc.border,
                    foreground: isMine ? cc.onAccent : cc.ink2,
                    borderWidth: isMine ? 1.5 : 1,
                  );
                },
              ),
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
