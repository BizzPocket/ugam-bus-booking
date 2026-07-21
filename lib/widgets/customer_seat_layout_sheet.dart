import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../components/combined_seat_grid.dart';
import '../components/seat_chart_tile.dart';
import '../design/group_color.dart';
import '../design/ugam.dart';
import '../models/bus_details.dart';
import '../models/passenger.dart';
import '../models/trip_type.dart';
import '../services/customer_requests_store.dart';

/// Read-only seat layout viewer for the customer "My Requests" screen.
/// Shows the customer's assigned seats highlighted on the actual bus layout,
/// with EVERY booked seat labelled by its occupant (name + phone) so
/// co-travellers on a group tour can coordinate — the organiser's deliberate
/// choice (see migration 041 for the privacy posture).
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

  /// busId → seatId → the riders seated there (name + phone), from the roster
  /// RPC. Empty until the tour is locked. Lets the sheet show WHO sits where.
  Map<String, Map<String, List<Passenger>>> _seatOccupants = const {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      // Start both round-trips before awaiting so they run in parallel: the bus
      // layouts and the (name + phone) roster that labels every booked seat.
      final busesF = _store.busLayoutsForRequest(widget.entry.id);
      final rosterF = _store.seatRosterForRequest(widget.entry.id);
      final buses = await busesF;
      final roster = await rosterF;
      if (!mounted) return;
      final occ = <String, Map<String, List<Passenger>>>{};
      for (final r in roster) {
        (occ[r.busId] ??= <String, List<Passenger>>{})
            .putIfAbsent(r.seatId, () => <Passenger>[])
            // Stable id (name|phone) so a whole double held by ONE rider — which
            // arrives as two berth entries — de-dupes to a single name, while a
            // genuinely shared sofa (two people) still renders split.
            .add(Passenger(id: '${r.name}|${r.phone}', tourId: '', name: r.name, phone: r.phone));
      }
      setState(() {
        _buses = buses;
        _seatOccupants = occ;
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

    final entry = widget.entry;
    final mySeats = entry.assignedSeats;
    return ListView.separated(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.only(bottom: UgamSpacing.xl),
      itemCount: _buses.length,
      separatorBuilder: (_, _) => const SizedBox(height: UgamSpacing.lg),
      itemBuilder: (_, i) {
        final bus = _buses[i];
        // seatId → the leg the customer holds it for. Per-seat leg when stamped
        // (mixed-leg requests), else the request's overall trip type — so a
        // one-way rider's seat renders half instead of a full accent chair.
        final mineOnThisBus = <String, TripType>{
          for (final s in mySeats.where((s) => s.busId == bus.id))
            s.seatId: s.leg ?? entry.tripType,
        };
        return _BusLayoutCard(
          bus: bus,
          mySeatLegs: mineOnThisBus,
          seatOccupants: _seatOccupants[bus.id] ?? const {},
        );
      },
    );
  }
}

class _BusLayoutCard extends StatefulWidget {
  final Bus bus;

  /// seatId → the leg the customer holds that seat for (drives the half render
  /// for one-way seats). The keys are the customer's own seats on this bus.
  final Map<String, TripType> mySeatLegs;

  /// seatId → the riders seated there (name + phone), from the roster RPC. Drives
  /// the (now non-anonymous) occupant identity shown on every booked seat.
  final Map<String, List<Passenger>> seatOccupants;

  const _BusLayoutCard({
    required this.bus,
    required this.mySeatLegs,
    required this.seatOccupants,
  });

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
                cellWidth: kSeatTileW,
                cellHeight: kSeatTileH,
                driverLabel: tr('customer_my_requests.layout_driver'),
                tileBuilder: (ctx, cell) {
                  // Non-anonymous: every booked seat shows its occupant's name +
                  // phone (organiser's choice, so co-travellers can coordinate).
                  // The viewer's OWN seats get an accent ring, drawn OUTSIDE the
                  // shared tile so the canonical tile component stays untouched.
                  final isMine = cell.seatId != null &&
                      widget.mySeatLegs.containsKey(cell.seatId);
                  final occupants = cell.seatId == null
                      ? const <Passenger>[]
                      : (widget.seatOccupants[cell.seatId] ??
                          const <Passenger>[]);
                  final tile = SeatChartTile(
                    cell: cell,
                    occupants: occupants,
                    groupColors: const GroupColorResolver({}),
                  );
                  if (!isMine) return tile;
                  return Stack(
                    children: [
                      tile,
                      Positioned.fill(
                        child: IgnorePointer(
                          child: Container(
                            decoration: BoxDecoration(
                              borderRadius:
                                  BorderRadius.circular(UgamRadius.seat),
                              border: Border.all(color: c.accent, width: 2.5),
                            ),
                          ),
                        ),
                      ),
                    ],
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
    final mine = widget.mySeatLegs.keys.toList()..sort();
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
                widget.bus.customerLabel,
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
