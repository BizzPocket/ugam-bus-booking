part of '../tour_detail_screen.dart';

// ─── BUSES TAB ────────────────────────────────────────────────────────

class _BusesTab extends StatelessWidget {
  final Tour tour;
  final UgamColorSet c;

  const _BusesTab({required this.tour, required this.c});

  @override
  Widget build(BuildContext context) {
    if (tour.buses.isEmpty) {
      return SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.only(top: UgamSpacing.lg),
          child: UgamEmpty(
            icon: Icons.directions_bus_outlined,
            title: tr('tour_detail.no_buses_title'),
            body: tr('tour_detail.no_buses_body'),
            cta: UgamCTA(
              label: tr('tour_detail.add_bus'),
              leadingIcon: Icons.add_rounded,
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (context) => AddBusScreen(tourId: tour.id),
                ),
              ),
            ),
          ),
        ),
      );
    }

    // ONE add-bus affordance per screen: the sticky bottom CTA owns "Add
    // another bus" (see _StickyAction case 2). The previously-duplicated inline
    // _AddBusTile is intentionally omitted here so the entry isn't doubled.
    // THE seat meter ([SeatMeter]) — whole seats, never a percentage, and the
    // same "x / n" the header vitals, dashboard and manage buses show.
    final meter = Get.find<TourController>().seatMeterFor(tour);
    final occupied = meter.occupied;
    final capacity = meter.capacity;
    final driversSet = tour.buses.where((b) => b.driverName.trim().isNotEmpty).length;

    return SliverList(
      delegate: SliverChildListDelegate.fixed([
        Row(
          children: [
            Expanded(
              child: UgamCard.plain(
                padding: const EdgeInsets.all(UgamSpacing.md),
                child: Column(
                  children: [
                    Text(
                      capacity == 0 ? '—' : '$occupied/$capacity',
                      style: UgamText.tabular(UgamText.titleM.copyWith(color: c.ink)),
                    ),
                    Text(tr('tour_detail.fleet_filled_label'),
                        style: UgamText.micro.copyWith(color: c.ink3)),
                  ],
                ),
              ),
            ),
            const SizedBox(width: UgamSpacing.sm),
            Expanded(
              child: UgamCard.plain(
                padding: const EdgeInsets.all(UgamSpacing.md),
                child: Column(
                  children: [
                    Text(
                      tr('tour_detail.fleet_drivers', namedArgs: {
                        'set': '$driversSet',
                        'total': '${tour.buses.length}',
                      }),
                      style: UgamText.tabular(
                        UgamText.titleM.copyWith(
                          color: driversSet == tour.buses.length ? c.ink : c.danger,
                        ),
                      ),
                    ),
                    Text(tr('tour_detail.fleet_drivers_label'),
                        style: UgamText.micro.copyWith(color: c.ink3)),
                  ],
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: UgamSpacing.md),
        // Live map. Only while the trip is actually running: handlers may only
        // push positions on a locked tour (migration 047), so before lock there
        // is nothing to plot and the entry would just disappoint.
        if (tour.status == TourStatus.locked) ...[
          UgamCTA(
            label: tr('tracking.map_open'),
            leadingIcon: Icons.map_outlined,
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) =>
                    LiveMapScreen(tourId: tour.id, buses: tour.buses),
              ),
            ),
          ),
          const SizedBox(height: UgamSpacing.md),
        ],
        for (final (i, bus) in tour.buses.indexed) ...[
          _BusListItem(
            bus: bus,
            tourId: tour.id,
            // Leg-aware berths occupied on this bus (max of the busier leg) —
            // single-sourced from the same helper the capacity engine uses.
            filled: meter.byBus[bus.id]?.occupied ??
                tour.occupiedBerthsFor(bus.id),
            capacity: meter.byBus[bus.id]?.capacity ?? bus.totalSeats,
            c: c,
          ),
          if (i != tour.buses.length - 1)
            const SizedBox(height: UgamSpacing.md),
        ],
      ]),
    );
  }
}

class _BusListItem extends StatelessWidget {
  final Bus bus;

  /// The enclosing tour's id. `Bus.tourId` is nullable and not always populated,
  /// so it cannot be trusted as the sole source — BusStatusScreen applies the
  /// same fallback at bus_status_screen.dart:257.
  final String tourId;
  final int filled;
  final int capacity;
  final UgamColorSet c;
  const _BusListItem({
    required this.bus,
    required this.tourId,
    required this.filled,
    required this.capacity,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    return UgamCard.plain(
      elev: true,
      padding: const EdgeInsets.all(UgamSpacing.md),
      // Tapping a bus opens its seat chart directly — the most common action.
      // Bus management (edit/delete/handler/add) stays reachable via the tour
      // actions + the per-bus "more" menu inside ManageBuses, so we skip the
      // ManageBuses hop that previously forced a second tap to reach the chart.
      onTap: () {
        HapticFeedback.selectionClick();
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (context) => BusStatusScreen(
              tourId: bus.tourId?.isNotEmpty == true ? bus.tourId! : tourId,
              busId: bus.id,
            ),
          ),
        );
      },
      child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(UgamRadius.photo),
              child: SizedBox(
                width: 64,
                height: 64,
                child: UgamBusBackdrop(seed: '${bus.id}-bus'),
              ),
            ),
            const SizedBox(width: UgamSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    bus.displayLabel,
                    style: UgamText.titleS.copyWith(color: c.ink),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    bus.driverName.isNotEmpty
                        ? bus.driverName
                        : tr('tour_detail.driver_not_set'),
                    style: UgamText.caption.copyWith(
                      color: bus.driverName.isNotEmpty ? c.ink2 : c.ink3,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(99),
                    child: LinearProgressIndicator(
                      value: capacity == 0
                          ? 0
                          : (filled / capacity).clamp(0.0, 1.0),
                      minHeight: 5,
                      backgroundColor: c.cardElev,
                      // Ink while filling, `good` once full: "how full" is a
                      // measurement, "full" is a state worth a colour. Amber
                      // said neither — and one bar per bus row put four or five
                      // copper strips down a tab whose CTA carries none.
                      color: capacity > 0 && filled >= capacity
                          ? c.good
                          : c.ink2,
                    ),
                  ),
                  if (bus.driverPhone.trim().isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 3),
                      // Tap barrier, NOT a resize: the two call buttons must
                      // stay 32 or the driver phone number ellipsizes on a
                      // 360/375pt device (PLAN §5 item 6). This absorbs a near
                      // miss so it no longer falls through to the card's own
                      // onTap and navigates into the seat chart.
                      child: GestureDetector(
                        onTap: () {},
                        behavior: HitTestBehavior.opaque,
                        child: Row(
                          children: [
                            Flexible(
                              child: Text(
                                bus.driverPhone,
                                style: UgamText.tabular(
                                  UgamText.caption.copyWith(color: c.ink3),
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const SizedBox(width: UgamSpacing.sm),
                            // Reach the driver without leaving the tour — same
                            // symmetry as the rider row-tap actions. Neutral
                            // icon buttons, repeated once per bus; their own
                            // taps win over the row's.
                            UgamIconButton(
                              icon: Icons.chat_rounded,
                              onTap: () => _contactDriverOnWhatsApp(bus),
                              size: 32,
                              iconSize: 16,
                              semanticLabel: tr('tour_detail.msg_whatsapp'),
                            ),
                            const SizedBox(width: 6),
                            UgamIconButton(
                              icon: Icons.call_rounded,
                              onTap: () => PhoneDialer.call(bus.driverPhone),
                              size: 32,
                              iconSize: 16,
                              semanticLabel: tr('tour_detail.call'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  const SizedBox(height: UgamSpacing.sm),
                  Row(
                    children: [
                      if (bus.isAC) ...[
                        UgamReqChip(label: tr('tour_detail.chip_ac')),
                        const SizedBox(width: 5),
                      ],
                      // Occupancy at a glance — "12/40 filled" — tinted by how
                      // full the bus is: green when full, WARM while there are
                      // berths still to sell (seats left is the open work on
                      // this tab), neutral when the bus is untouched. It was
                      // amber for the partly-filled case, which made the
                      // commonest state on the screen the loudest one.
                      UgamReqChip(
                        label: tr('tour_detail.bus_occupancy', namedArgs: {
                          'filled': '$filled',
                          // Same leg-aware capacity as the bar beside it, so
                          // the chip and the bar can never disagree.
                          'total': '$capacity',
                        }),
                        variant: capacity > 0 && filled >= capacity
                            ? UgamChipVariant.good
                            : (filled > 0
                                ? UgamChipVariant.warm
                                : UgamChipVariant.neutral),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: UgamSpacing.sm),
            // The same "open this" affordance is a plain grey chevron on the
            // Passengers tab; repeating a copper circle once per bus row would
            // have spent the accent on "this row is tappable".
            Icon(Icons.chevron_right_rounded, size: 18, color: c.ink3),
          ],
        ),
      );
  }
}
