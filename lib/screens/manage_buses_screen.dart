import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../controllers/tour_controller.dart';
import '../design/components/ugam_capacity_meter.dart';
import '../design/ugam.dart';
import '../models/bus_details.dart';
import '../models/passenger.dart';
import '../models/tour.dart';
import '../utils/app_snackbar.dart';
import '../utils/passenger_display.dart';
import '../utils/phone_dialer.dart';
import '../utils/time_format.dart';
import '../utils/tour_capacity.dart';
import 'add_bus_screen.dart';
import 'bus_status_screen.dart';


/// List of buses attached to a tour. Topbar + capacity stat tiles +
/// photo-anchored bus cards (matching image-5 list pattern) + sticky
/// bottom CTA to add a new bus.
class ManageBusesScreen extends StatelessWidget {
  final String tourId;

  const ManageBusesScreen({super.key, required this.tourId});

  TourController get _tourCtrl => Get.find<TourController>();

  /// Opens a sheet with the per-bus actions: edit, call the driver, delete.
  void _openBusMenu(BuildContext context, Tour tour, Bus bus) {
    UgamSheet.show<void>(
      context,
      title: bus.displayLabel,
      builder: (ctx) {
        final c = UgamColors.of(ctx);
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _BusMenuTile(
              c: c,
              icon: Icons.edit_rounded,
              label: tr('manage_buses.menu_edit'),
              onTap: () {
                Navigator.of(ctx).pop();
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (context) => AddBusScreen(tourId: tourId, existing: bus),
                  ),
                );
              },
            ),
            // Driver phone lives here now (moved off the dense card meta line):
            // a one-tap call, with the number shown as the tile subtitle.
            if (bus.driverPhone.trim().isNotEmpty)
              _BusMenuTile(
                c: c,
                icon: Icons.call_rounded,
                label: tr('manage_buses.menu_call_driver'),
                subtitle: bus.driverPhone,
                onTap: () {
                  Navigator.of(ctx).pop();
                  PhoneDialer.call(bus.driverPhone);
                },
              ),
            _BusMenuTile(
              c: c,
              icon: Icons.delete_outline_rounded,
              label: tr('manage_buses.menu_delete'),
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

  /// Distinct passengers holding at least one seat on [bus], in roster order.
  /// These are the only people eligible to handle the bus — a handler must be
  /// physically on board.
  List<Passenger> _seatedPassengers(Tour tour, Bus bus) {
    return tour.passengers
        .where((p) => p.assignedSeats.any((a) => a.busId == bus.id))
        .toList();
  }

  /// Per-bus handler picker. Lists the bus's seated passengers; picking one
  /// calls [TourController.setBusHandler], the current handler (if any) can be
  /// cleared via [TourController.removeBusHandler]. Re-reads the live bus from
  /// the controller so the "current" tick stays correct after a change.
  void _openHandlerPicker(BuildContext context, Tour tour, Bus bus) {
    final seated = _seatedPassengers(tour, bus);
    if (seated.isEmpty) {
      AppSnackBar.warning(tr('bus_handler.none_seated'));
      return;
    }

    UgamSheet.show<void>(
      context,
      title: tr('bus_handler.picker_title', namedArgs: {
        'bus': bus.displayLabel,
      }),
      builder: (ctx) {
        final c = UgamColors.of(ctx);
        // Live bus so the current-handler highlight reflects the latest pick.
        final liveBus =
            _tourCtrl.getTour(tour.id)?.buses.firstWhereOrNull(
                  (b) => b.id == bus.id,
                ) ??
            bus;
        final currentId = liveBus.handlerPassengerId;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: UgamSpacing.sm),
              child: Text(
                tr('bus_handler.picker_subtitle'),
                style: UgamText.caption.copyWith(color: c.ink2),
              ),
            ),
            ...seated.map((p) {
              final isCurrent = p.id == currentId;
              return _HandlerPickTile(
                c: c,
                passenger: p,
                isCurrent: isCurrent,
                onTap: () async {
                  Navigator.of(ctx).pop();
                  if (isCurrent) return;
                  await _tourCtrl.setBusHandler(tour.id, bus.id, p.id);
                  AppSnackBar.success(
                    tr('bus_handler.set_done',
                        namedArgs: {'name': p.displayName}),
                  );
                },
              );
            }),
            if (currentId != null) ...[
              const SizedBox(height: UgamSpacing.sm),
              UgamButton(
                label: tr('bus_handler.remove'),
                icon: Icons.person_remove_outlined,
                kind: UgamButtonKind.dangerTonal,
                expand: true,
                onPressed: () async {
                  Navigator.of(ctx).pop();
                  await _tourCtrl.removeBusHandler(tour.id, bus.id);
                  AppSnackBar.success(tr('bus_handler.remove_done'));
                },
              ),
            ],
          ],
        );
      },
    );
  }

  Future<void> _confirmDelete(BuildContext context, Tour tour, Bus bus) async {
    final confirmed = await UgamDialog.confirm(
      context,
      title: tr('manage_buses.delete_title'),
      message: tr('manage_buses.delete_body', namedArgs: {
        'bus': bus.displayLabel,
      }),
      confirmLabel: tr('app.action.delete'),
      destructive: true,
      confirmIcon: Icons.delete_outline_rounded,
    );
    if (!confirmed) return;
    try {
      await _tourCtrl.removeBus(tour.id, bus.id);
      AppSnackBar.success(tr('manage_buses.snack_deleted'));
    } catch (e) {
      AppSnackBar.error('${tr('manage_buses.snack_delete_failed')} $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);

    return UgamScaffold(
      body: SafeArea(
        child: Obx(() {
          final tour = _tourCtrl.getTour(tourId);
          if (tour == null) {
            return UgamEmpty(
              icon: Icons.search_off_rounded,
              title: tr('manage_buses.tour_not_found'),
            );
          }

          // Single engine-sourced capacity snapshot for the whole screen:
          // feeds the app-bar "free seats" subtitle AND each per-bus meter
          // (via cap.byBus[bus.id]) so the list never re-derives its own count.
          final cap = computeTourCapacity(tour);
          final totalCapacity = cap.capacity;

          // "N buses · X free of Y" — the old 2-col stat strip folded into the
          // app-bar subtitle so the list starts higher (mobile-native: one
          // hero context line, no metric grid). Leads with FREE seats — the
          // figure the agent acts on — never an opaque assigned/total or a %.
          final busesLabel = tr(
            'manage_buses.subtitle_buses',
            namedArgs: {'count': '${tour.buses.length}'},
          );
          final seatsLabel = totalCapacity > 0
              ? tr('manage_buses.subtitle_seats_free', namedArgs: {
                  'free': '${cap.free}',
                  'capacity': '$totalCapacity',
                })
              : null;
          final summaryLine =
              [busesLabel, seatsLabel].whereType<String>().join('  ·  ');

          return Column(
            children: [
              UgamAppBar(
                title: tr('manage_buses.title'),
                subtitle: summaryLine,
              ),
              const SizedBox(height: UgamSpacing.sm),
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
                          final handler = bus.handlerPassengerId == null
                              ? null
                              : tour.passengers.firstWhereOrNull(
                                  (p) => p.id == bus.handlerPassengerId,
                                );
                          return _BusListItem(
                            c: c,
                            bus: bus,
                            busCap: cap.byBus[bus.id],
                            handlerName: handler?.displayName,
                            onOpen: () => Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (context) => BusStatusScreen(
                                  tourId: tourId,
                                  busId: bus.id,
                                ),
                              ),
                            ),
                            onMore: () => _openBusMenu(ctx, tour, bus),
                            onHandler: () => _openHandlerPicker(ctx, tour, bus),
                          );
                        },
                      ),
              ),
            ],
          );
        }),
      ),
      // Add-bus CTA.
      bottomNavigationBar: UgamStickyCTA(
        child: UgamCTA(
          label: tr('manage_buses.add_bus'),
          leadingIcon: Icons.add_rounded,
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (context) => AddBusScreen(tourId: tourId),
            ),
          ),
        ),
      ),
    );
  }
}

class _BusListItem extends StatelessWidget {
  final UgamColorSet c;
  final Bus bus;

  /// This bus's leg-aware capacity slice from the tour engine snapshot
  /// (`cap.byBus[bus.id]`). Null when the bus isn't in the plan (no layout
  /// yet) — the meter is simply skipped in that case.
  final BusCapacity? busCap;

  /// Display name of this bus's handler, or null when none is assigned yet.
  final String? handlerName;
  final VoidCallback onOpen;
  final VoidCallback onMore;

  /// Opens the per-bus handler picker (tapping the handler row).
  final VoidCallback onHandler;

  const _BusListItem({
    required this.c,
    required this.bus,
    required this.busCap,
    required this.handlerName,
    required this.onOpen,
    required this.onMore,
    required this.onHandler,
  });

  /// Driver name only (line 1 of the meta stack). Phone is no longer crammed
  /// here — it lives in the bus action sheet ("Call driver"). Empty when unset.
  String get _driverLine => bus.driverName.trim();

  /// This bus's own boarding place + departure time joined by a middot,
  /// skipping blanks so an unset half never renders as a lone "·". Per-bus
  /// values override the tour-level / chart-footer departure; empty when both
  /// are unset. This is line 2 of the meta stack.
  String get _departureLine => [bus.boardingPoint, formatHhMm(bus.departureTime)]
      .where((s) => s != null && s.trim().isNotEmpty)
      .join(' · ');

  @override
  Widget build(BuildContext context) {
    return UgamCard.media(
      onTap: onOpen,
      elev: true,
      child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(UgamRadius.photo),
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
                        bus.displayLabel,
                        style: UgamText.titleS.copyWith(
                          color: c.ink,
                          fontSize: 15,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      // Line 1: driver name (emphasised). Line 2: boarding +
                      // departure (muted). Phone is no longer crammed here — it
                      // moved into the bus action sheet ("Call driver").
                      if (_driverLine.isNotEmpty) ...[
                        const SizedBox(height: 3),
                        Text(
                          _driverLine,
                          style: UgamText.bodyStrong.copyWith(
                            color: c.ink,
                            fontSize: 13,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                      if (_departureLine.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          _departureLine,
                          style: UgamText.caption.copyWith(
                            color: c.ink2,
                            fontSize: 12,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                      if (bus.isAC) ...[
                        const SizedBox(height: UgamSpacing.sm),
                        UgamReqChip(label: tr('manage_buses.tag_ac')),
                      ],
                    ],
                  ),
                ),
                UgamIconButton(
                  icon: Icons.more_vert_rounded,
                  onTap: onMore,
                  semanticLabel: tr('manage_buses.menu_edit'),
                ),
              ],
            ),
            // Leg-aware occupancy: the shared two-leg meter ("Go x/n · Ret
            // y/n" + free count over a single thin bar). Replaces the old
            // merged $assigned/$cap + percentage bar, which hid which leg was
            // fuller and could leak a fractional seatLoad. Skipped when the bus
            // has no engine slice yet (no layout).
            if (busCap != null && busCap!.capacity > 0) ...[
              const SizedBox(height: UgamSpacing.md),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: UgamSpacing.sm),
                child: UgamCapacityMeter.bus(busCap!),
              ),
              const SizedBox(height: UgamSpacing.xs),
            ],
            const SizedBox(height: UgamSpacing.sm),
            _HandlerRow(c: c, handlerName: handlerName, onTap: onHandler),
          ],
        ),
    );
  }
}

/// Per-bus handler chip inside a bus card. Shows the current handler's name
/// (with a badge) or a "Set handler" prompt; tapping opens the picker.
class _HandlerRow extends StatelessWidget {
  final UgamColorSet c;
  final String? handlerName;
  final VoidCallback onTap;

  const _HandlerRow({
    required this.c,
    required this.handlerName,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final hasHandler = handlerName != null && handlerName!.trim().isNotEmpty;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: UgamSpacing.md,
          vertical: UgamSpacing.sm,
        ),
        // No hand-rolled border on the neutral state — depth comes from a
        // recessed fill (base card tone, sunk into the elevated bus card)
        // instead of a hairline. The set state keeps the copper accent tint.
        decoration: BoxDecoration(
          color: hasHandler ? c.accentFill : c.card,
          borderRadius: BorderRadius.circular(UgamRadius.row),
        ),
        child: Row(
          children: [
            Icon(
              Icons.badge_outlined,
              size: 16,
              color: hasHandler ? c.accent : c.ink3,
            ),
            const SizedBox(width: UgamSpacing.sm),
            Expanded(
              child: Text(
                hasHandler
                    ? tr('bus_handler.row_current',
                        namedArgs: {'name': handlerName!})
                    : tr('bus_handler.row_empty'),
                style: UgamText.caption.copyWith(
                  color: hasHandler ? c.ink : c.ink2,
                  fontWeight: hasHandler ? FontWeight.w700 : FontWeight.w500,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: UgamSpacing.sm),
            Icon(Icons.chevron_right_rounded, size: 16, color: c.ink3),
          ],
        ),
      ),
    );
  }
}

/// A row in the per-bus handler picker — a seated passenger with a check tick
/// when they already handle this bus.
class _HandlerPickTile extends StatelessWidget {
  final UgamColorSet c;
  final Passenger passenger;
  final bool isCurrent;
  final VoidCallback onTap;

  const _HandlerPickTile({
    required this.c,
    required this.passenger,
    required this.isCurrent,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        margin: const EdgeInsets.only(bottom: UgamSpacing.sm),
        padding: const EdgeInsets.all(UgamSpacing.md),
        decoration: BoxDecoration(
          color: c.cardElev,
          borderRadius: BorderRadius.circular(UgamRadius.row),
          border: isCurrent ? Border.all(color: c.accent, width: 1.5) : null,
        ),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: isCurrent ? c.accent : c.card,
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: Text(
                passenger.displayName.isNotEmpty
                    ? passenger.displayName[0].toUpperCase()
                    : '?',
                style: UgamText.bodyStrong.copyWith(
                  color: isCurrent ? c.onAccent : c.ink,
                  fontSize: 14,
                ),
              ),
            ),
            const SizedBox(width: UgamSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    passenger.displayName,
                    style: UgamText.bodyStrong.copyWith(color: c.ink),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (passenger.phone.isNotEmpty)
                    Text(
                      passenger.phone,
                      style: UgamText.caption.copyWith(color: c.ink2),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ),
            ),
            if (isCurrent)
              Icon(Icons.check_circle_rounded, size: 20, color: c.accent),
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

  /// Optional muted second line under the label (e.g. the driver's phone
  /// number on the "Call driver" tile).
  final String? subtitle;
  final Color? tint;
  final bool danger;
  final VoidCallback onTap;

  const _BusMenuTile({
    required this.c,
    required this.icon,
    required this.label,
    required this.onTap,
    this.subtitle,
    this.tint,
    this.danger = false,
  });

  @override
  Widget build(BuildContext context) {
    final iconColor = tint ?? c.ink;
    final labelColor = danger ? c.danger : c.ink;
    // InkWell (ripple + 48dp tap target) replaces the raw GestureDetector;
    // selection haptic on tap for native feel.
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () {
          HapticFeedback.selectionClick();
          onTap();
        },
        borderRadius: BorderRadius.circular(UgamRadius.row),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            vertical: UgamSpacing.md,
            horizontal: UgamSpacing.sm,
          ),
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
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      label,
                      style: UgamText.bodyStrong.copyWith(
                        color: labelColor,
                        fontSize: 14,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (subtitle != null && subtitle!.trim().isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        subtitle!,
                        style: UgamText.caption.copyWith(color: c.ink2),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded, size: 18, color: c.ink3),
            ],
          ),
        ),
      ),
    );
  }
}
