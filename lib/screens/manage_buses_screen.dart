import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:url_launcher/url_launcher.dart';

import '../controllers/tour_controller.dart';
import '../design/ugam.dart';
import '../models/bus_details.dart';
import '../models/tour.dart';
import '../utils/app_snackbar.dart';
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

  /// Opens a sheet with the per-bus actions: edit, view status,
  /// re-broadcast to driver via WhatsApp, delete.
  void _openBusMenu(BuildContext context, Tour tour, Bus bus) {
    UgamSheet.show<void>(
      context,
      title: bus.busNumber.isEmpty ? bus.name : bus.busNumber,
      builder: (ctx) {
        final c = UgamColors.of(ctx);
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _BusMenuTile(
              c: c,
              icon: Icons.edit_rounded,
              label: 'Edit bus details',
              onTap: () {
                Navigator.of(ctx).pop();
                Get.to(
                  () => AddBusScreen(tourId: tourId, existing: bus),
                  transition: Transition.cupertino,
                );
              },
            ),
            _BusMenuTile(
              c: c,
              icon: Icons.event_seat_rounded,
              label: 'View seat status',
              onTap: () {
                Navigator.of(ctx).pop();
                Get.to(
                  () => BusStatusScreen(tourId: tourId, busId: bus.id),
                  transition: Transition.cupertino,
                );
              },
            ),
            _BusMenuTile(
              c: c,
              icon: Icons.chat_rounded,
              label: 'Re-broadcast to driver via WhatsApp',
              tint: c.good,
              onTap: () {
                Navigator.of(ctx).pop();
                _broadcastToDriver(tour, bus);
              },
            ),
            _BusMenuTile(
              c: c,
              icon: Icons.delete_outline_rounded,
              label: 'Delete bus',
              tint: c.danger,
              danger: true,
              onTap: () {
                Navigator.of(ctx).pop();
                _confirmDelete(context, tour, bus);
              },
            ),
          ],
        );
      },
    );
  }

  Future<void> _broadcastToDriver(Tour tour, Bus bus) async {
    final phone = bus.driverPhone.replaceAll(RegExp(r'[^\d+]'), '');
    if (phone.isEmpty) {
      AppSnackBar.error('Driver phone is missing on this bus.');
      return;
    }
    var wa = phone.startsWith('+') ? phone.substring(1) : phone;
    if (!phone.startsWith('+') && wa.length == 10) wa = '91$wa';
    final msg = StringBuffer()
      ..writeln('Bus assignment — ${tour.title}')
      ..writeln('Bus: ${bus.busNumber.isEmpty ? bus.name : bus.busNumber}')
      ..writeln(
          'Departure: ${tour.departureDate.day}/${tour.departureDate.month}/${tour.departureDate.year}')
      ..writeln('From: ${tour.fromCity}')
      ..writeln('To: ${tour.toCity}');
    final uri = Uri.parse(
        'https://wa.me/$wa?text=${Uri.encodeComponent(msg.toString())}');
    try {
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!ok) {
        AppSnackBar.error('Could not open WhatsApp.');
      }
    } catch (e) {
      AppSnackBar.error('Could not open WhatsApp. $e');
    }
  }

  Future<void> _confirmDelete(
      BuildContext context, Tour tour, Bus bus) async {
    final c = UgamColors.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: c.card,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(UgamRadius.card),
        ),
        title: Text('Delete bus?',
            style: UgamText.titleM.copyWith(color: c.ink)),
        content: Text(
          'This will remove ${bus.busNumber.isEmpty ? bus.name : bus.busNumber} '
          'from this tour. Seat assignments tied to this bus will be lost.',
          style: UgamText.body.copyWith(color: c.ink2),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text('Cancel',
                style: UgamText.bodyStrong.copyWith(color: c.ink2)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text('Delete',
                style: UgamText.bodyStrong.copyWith(color: c.danger)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await _tourCtrl.removeBus(tour.id, bus.id);
      AppSnackBar.success('Bus deleted.');
    } catch (e) {
      AppSnackBar.error('Could not delete bus. $e');
    }
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
                        itemBuilder: (ctx, i) {
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
                            onMore: () => _openBusMenu(ctx, tour, bus),
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
  final VoidCallback onMore;

  const _BusListItem({
    required this.c,
    required this.bus,
    required this.assigned,
    required this.onOpen,
    required this.onMore,
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
                  onTap: onMore,
                  behavior: HitTestBehavior.opaque,
                  child: Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      color: c.card,
                      shape: BoxShape.circle,
                    ),
                    alignment: Alignment.center,
                    child: Icon(Icons.more_vert_rounded,
                        size: 18, color: c.ink),
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

class _BusMenuTile extends StatelessWidget {
  final UgamColorSet c;
  final IconData icon;
  final String label;
  final Color? tint;
  final bool danger;
  final VoidCallback onTap;

  const _BusMenuTile({
    required this.c,
    required this.icon,
    required this.label,
    required this.onTap,
    this.tint,
    this.danger = false,
  });

  @override
  Widget build(BuildContext context) {
    final iconColor = tint ?? c.ink;
    final labelColor = danger ? c.danger : c.ink;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: UgamSpacing.md),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: danger ? c.warmFill : c.cardElev,
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: Icon(icon, size: 18, color: iconColor),
            ),
            const SizedBox(width: UgamSpacing.md),
            Expanded(
              child: Text(
                label,
                style: UgamText.bodyStrong
                    .copyWith(color: labelColor, fontSize: 14),
              ),
            ),
            Icon(Icons.chevron_right_rounded, size: 18, color: c.ink3),
          ],
        ),
      ),
    );
  }
}
