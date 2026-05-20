import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/tour_controller.dart';
import '../design/ugam.dart';
import '../models/bus_details.dart';
import '../models/tour.dart';
import 'add_bus_screen.dart';
import 'bus_status_screen.dart';

/// List of buses attached to a tour. Topbar + capacity stat tiles +
/// photo-anchored bus cards (matching image-5 list pattern) + sticky
/// bottom CTA to add a new bus.
class ManageBusesScreen extends StatelessWidget {
  final String tourId;

  const ManageBusesScreen({super.key, required this.tourId});

  TourController get _tourCtrl => Get.find<TourController>();

  String _formatDateRange(Tour tour) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    final dep = tour.departureDate;
    var label = '${months[dep.month - 1]} ${dep.day}';
    if (tour.returnDate != null) {
      label += '–${tour.returnDate!.day}';
    }
    return label;
  }

  int _seatsAssignedForBus(Tour tour, String busId) {
    return tour.passengers.fold<int>(
      0,
      (sum, p) =>
          sum + p.assignedSeats.where((a) => a.busId == busId).length,
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);

    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        child: Obx(() {
          final tour = _tourCtrl.getTour(tourId);
          if (tour == null) {
            return UgamEmpty(
              icon: Icons.search_off_rounded,
              title: tr('manage_buses.tour_not_found'),
            );
          }

          final assigned = tour.totalSeatsAssigned;
          final totalCapacity = tour.totalBusSeats;

          return Column(
            children: [
              _TopBar(
                c: c,
                title: tour.title,
                subtitle: _formatDateRange(tour),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  UgamSpacing.gutter,
                  UgamSpacing.md,
                  UgamSpacing.gutter,
                  UgamSpacing.lg,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: UgamStatTile(
                        icon: Icons.directions_bus_rounded,
                        value: '${tour.buses.length}',
                        label: 'Buses',
                      ),
                    ),
                    const SizedBox(width: UgamSpacing.md),
                    Expanded(
                      child: UgamStatTile(
                        icon: Icons.event_seat_rounded,
                        value: totalCapacity > 0 ? '$assigned' : '—',
                        ofTotal: totalCapacity > 0 ? '/$totalCapacity' : null,
                        label: 'Seats',
                        variant: UgamStatVariant.good,
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: tour.buses.isEmpty
                    ? UgamEmpty(
                        icon: Icons.directions_bus_outlined,
                        title: tr('manage_buses.empty_title'),
                        body: tr('manage_buses.empty_body'),
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.fromLTRB(
                          UgamSpacing.gutter,
                          0,
                          UgamSpacing.gutter,
                          120,
                        ),
                        itemCount: tour.buses.length,
                        separatorBuilder: (_, _) =>
                            const SizedBox(height: UgamSpacing.md),
                        itemBuilder: (_, i) {
                          final bus = tour.buses[i];
                          final assignedForBus =
                              _seatsAssignedForBus(tour, bus.id);
                          return _BusListItem(
                            c: c,
                            bus: bus,
                            assigned: assignedForBus,
                            onOpen: () => Get.to(
                              () => BusStatusScreen(
                                tourId: tourId,
                                busId: bus.id,
                              ),
                              transition: Transition.cupertino,
                            ),
                            onEdit: () => Get.to(
                              () => AddBusScreen(
                                tourId: tourId,
                                existing: bus,
                              ),
                              transition: Transition.cupertino,
                            ),
                          );
                        },
                      ),
              ),
            ],
          );
        }),
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            UgamSpacing.gutter,
            UgamSpacing.sm,
            UgamSpacing.gutter,
            UgamSpacing.md,
          ),
          child: UgamCTA(
            label: tr('manage_buses.add_bus'),
            leadingIcon: Icons.add_rounded,
            onPressed: () =>
                Get.to(() => AddBusScreen(tourId: tourId)),
          ),
        ),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  final UgamColorSet c;
  final String title;
  final String subtitle;

  const _TopBar({
    required this.c,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        UgamSpacing.md,
        UgamSpacing.sm,
        UgamSpacing.md,
        UgamSpacing.sm,
      ),
      child: Row(
        children: [
          GestureDetector(
            onTap: () => Get.back(),
            behavior: HitTestBehavior.opaque,
            child: Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: c.cardElev,
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child:
                  Icon(Icons.arrow_back_rounded, size: 19, color: c.ink),
            ),
          ),
          const SizedBox(width: UgamSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  tr('manage_buses.title'),
                  style: UgamText.titleL.copyWith(color: c.ink),
                ),
                Text(
                  '$title · $subtitle',
                  style: UgamText.caption.copyWith(color: c.ink2),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _BusListItem extends StatelessWidget {
  final UgamColorSet c;
  final Bus bus;
  final int assigned;
  final VoidCallback onOpen;
  final VoidCallback onEdit;

  const _BusListItem({
    required this.c,
    required this.bus,
    required this.assigned,
    required this.onOpen,
    required this.onEdit,
  });

  @override
  Widget build(BuildContext context) {
    final cap = bus.totalSeats;
    final pct = cap > 0 ? (assigned / cap).clamp(0.0, 1.0) : 0.0;

    return GestureDetector(
      onTap: onOpen,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.all(UgamSpacing.sm),
        decoration: BoxDecoration(
          color: c.cardElev,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: SizedBox(
                    width: 76,
                    height: 76,
                    child: UgamBusBackdrop(seed: bus.id),
                  ),
                ),
                const SizedBox(width: UgamSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        bus.busNumber,
                        style: UgamText.titleS
                            .copyWith(color: c.ink, fontSize: 15),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${bus.driverName} · ${bus.driverPhone}',
                        style: UgamText.caption
                            .copyWith(color: c.ink2, fontSize: 12),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: UgamSpacing.sm),
                      Row(
                        children: [
                          if (bus.isAC) const UgamReqChip(label: 'AC'),
                          if (bus.isAC) const SizedBox(width: 5),
                          UgamReqChip(
                            label: '$cap SEATS',
                            variant: UgamChipVariant.neutral,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                GestureDetector(
                  onTap: onEdit,
                  behavior: HitTestBehavior.opaque,
                  child: Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      color: c.card,
                      shape: BoxShape.circle,
                    ),
                    alignment: Alignment.center,
                    child: Icon(Icons.edit_rounded, size: 16, color: c.ink),
                  ),
                ),
              ],
            ),
            if (cap > 0) ...[
              const SizedBox(height: UgamSpacing.md),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: UgamSpacing.sm,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: pct,
                          minHeight: 6,
                          backgroundColor: c.card,
                          valueColor: AlwaysStoppedAnimation(c.accent),
                        ),
                      ),
                    ),
                    const SizedBox(width: UgamSpacing.md),
                    Text(
                      '$assigned/$cap',
                      style: UgamText.tabular(
                        UgamText.bodyStrong.copyWith(color: c.ink, fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: UgamSpacing.xs),
            ],
          ],
        ),
      ),
    );
  }
}
