import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/tour_controller.dart';
import '../design/ugam.dart';
import '../models/bus_details.dart';
import '../models/passenger.dart';
import '../models/tour.dart';
import '../services/whatsapp_service.dart';
import '../utils/app_snackbar.dart';
import '../utils/formatters.dart';
import '../utils/passenger_display.dart';
import '../utils/time_format.dart';
import 'add_bus_screen.dart';
import 'bus_status_screen.dart';

/// List of buses attached to a tour. Topbar + capacity stat tiles +
/// photo-anchored bus cards (matching image-5 list pattern) + sticky
/// bottom CTA to add a new bus.
class ManageBusesScreen extends StatelessWidget {
  final String tourId;

  const ManageBusesScreen({super.key, required this.tourId});

  TourController get _tourCtrl => Get.find<TourController>();

  /// Localized departure(-return) label, e.g. `12 Jun` or `12 Jun–14`.
  /// Month names follow the active app locale via [Formatters.formatDateShort].
  String _formatDateRange(BuildContext context, Tour tour) {
    final locale = context.locale.languageCode;
    var label = Formatters.formatDateShort(tour.departureDate, locale: locale);
    if (tour.returnDate != null) {
      label += '–${tour.returnDate!.day}';
    }
    return label;
  }

  int _seatsAssignedForBus(Tour tour, String busId) {
    return tour.passengers.fold<int>(
      0,
      (sum, p) => sum + p.assignedSeats.where((a) => a.busId == busId).length,
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
              label: tr('manage_buses.menu_edit'),
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
              icon: Icons.chat_rounded,
              label: tr('manage_buses.menu_rebroadcast'),
              tint: c.good,
              onTap: () {
                Navigator.of(ctx).pop();
                _broadcastToDriver(tour, bus);
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

  Future<void> _broadcastToDriver(Tour tour, Bus bus) async {
    final phone = bus.driverPhone.replaceAll(RegExp(r'[^\d+]'), '');
    if (phone.isEmpty) {
      AppSnackBar.error(tr('manage_buses.snack_driver_phone_missing'));
      return;
    }
    // This bus's OWN departure place + time (per-bus overrides tour-level),
    // joined by a middot and omitting either half when unset.
    final busDeparture = [bus.boardingPoint, formatHhMm(bus.departureTime)]
        .where((s) => s != null && s.trim().isNotEmpty)
        .join(' · ');
    final msg = StringBuffer()
      ..writeln(tr('manage_buses.wa_assignment',
          namedArgs: {'tour': tour.title}))
      ..writeln(tr('manage_buses.wa_bus', namedArgs: {
        'bus': bus.busNumber.isEmpty ? bus.name : bus.busNumber,
      }))
      ..writeln(tr('manage_buses.wa_departure', namedArgs: {
        'date':
            '${tour.departureDate.day}/${tour.departureDate.month}/${tour.departureDate.year}',
      }))
      ..writeln(tr('manage_buses.wa_from', namedArgs: {'city': tour.fromCity}))
      ..writeln(tr('manage_buses.wa_to', namedArgs: {'city': tour.toCity}));
    if (busDeparture.isNotEmpty) {
      msg.writeln(busDeparture);
    }
    try {
      final ok = await WhatsAppService()
          .openChat(phone: bus.driverPhone, message: msg.toString());
      if (!ok) {
        AppSnackBar.error(tr('manage_buses.snack_wa_failed'));
      }
    } catch (e) {
      AppSnackBar.error('${tr('manage_buses.snack_wa_failed')} $e');
    }
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
        'bus': bus.busNumber.isEmpty ? bus.name : bus.busNumber,
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
        'bus': bus.busNumber.isEmpty ? bus.name : bus.busNumber,
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
              UgamAppBar(
                title: tr('manage_buses.title'),
                subtitle:
                    '${tour.title} · ${_formatDateRange(context, tour)}',
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
                        label: tr('manage_buses.stat_buses'),
                      ),
                    ),
                    const SizedBox(width: UgamSpacing.md),
                    Expanded(
                      child: UgamStatTile(
                        icon: Icons.event_seat_rounded,
                        value: totalCapacity > 0 ? '$assigned' : '—',
                        ofTotal: totalCapacity > 0 ? '/$totalCapacity' : null,
                        label: tr('manage_buses.stat_seats'),
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
                          final assignedForBus = _seatsAssignedForBus(
                            tour,
                            bus.id,
                          );
                          final handler = bus.handlerPassengerId == null
                              ? null
                              : tour.passengers.firstWhereOrNull(
                                  (p) => p.id == bus.handlerPassengerId,
                                );
                          return _BusListItem(
                            c: c,
                            bus: bus,
                            assigned: assignedForBus,
                            handlerName: handler?.displayName,
                            onOpen: () => Get.to(
                              () => BusStatusScreen(
                                tourId: tourId,
                                busId: bus.id,
                              ),
                              transition: Transition.cupertino,
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
      bottomNavigationBar: UgamStickyCTA(
        child: UgamCTA(
          label: tr('manage_buses.add_bus'),
          leadingIcon: Icons.add_rounded,
          onPressed: () => Get.to(() => AddBusScreen(tourId: tourId)),
        ),
      ),
    );
  }
}

class _BusListItem extends StatelessWidget {
  final UgamColorSet c;
  final Bus bus;
  final int assigned;

  /// Display name of this bus's handler, or null when none is assigned yet.
  final String? handlerName;
  final VoidCallback onOpen;
  final VoidCallback onMore;

  /// Opens the per-bus handler picker (tapping the handler row).
  final VoidCallback onHandler;

  const _BusListItem({
    required this.c,
    required this.bus,
    required this.assigned,
    required this.handlerName,
    required this.onOpen,
    required this.onMore,
    required this.onHandler,
  });

  /// Driver name + phone joined by a middot, skipping blanks so an empty
  /// driver never renders as a lone "·".
  String get _driverLine => [bus.driverName, bus.driverPhone]
      .where((s) => s.trim().isNotEmpty)
      .join(' · ');

  /// This bus's own departure place + time joined by a middot, skipping blanks
  /// so an unset half never renders as a lone "·". Per-bus values override the
  /// tour-level / chart-footer departure; empty when both are unset.
  String get _departureLine => [bus.boardingPoint, formatHhMm(bus.departureTime)]
      .where((s) => s != null && s.trim().isNotEmpty)
      .join(' · ');

  @override
  Widget build(BuildContext context) {
    final cap = bus.totalSeats;
    final pct = cap > 0 ? (assigned / cap).clamp(0.0, 1.0) : 0.0;

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
                        bus.busNumber.isEmpty ? bus.name : bus.busNumber,
                        style: UgamText.titleS.copyWith(
                          color: c.ink,
                          fontSize: 15,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (_driverLine.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          _driverLine,
                          style: UgamText.caption.copyWith(
                            color: c.ink2,
                            fontSize: 12,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                      if (_departureLine.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Row(
                          children: [
                            Icon(
                              Icons.place_outlined,
                              size: 12,
                              color: c.ink3,
                            ),
                            const SizedBox(width: 3),
                            Expanded(
                              child: Text(
                                _departureLine,
                                style: UgamText.caption.copyWith(
                                  color: c.ink2,
                                  fontSize: 12,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ],
                      const SizedBox(height: UgamSpacing.sm),
                      Row(
                        children: [
                          if (bus.isAC) UgamReqChip(label: tr('manage_buses.tag_ac')),
                          if (bus.isAC) const SizedBox(width: 5),
                          UgamReqChip(
                            label: tr('manage_buses.chip_seats',
                                namedArgs: {'n': '$cap'}),
                            variant: UgamChipVariant.neutral,
                          ),
                        ],
                      ),
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
            if (cap > 0) ...[
              const SizedBox(height: UgamSpacing.md),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: UgamSpacing.sm),
                child: Row(
                  children: [
                    Expanded(
                      child: ClipRRect(
                        borderRadius:
                            BorderRadius.circular(UgamRadius.chip),
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
                        UgamText.bodyStrong.copyWith(
                          color: c.ink,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ),
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
        decoration: BoxDecoration(
          color: hasHandler ? c.accentFill : c.card,
          borderRadius: BorderRadius.circular(UgamRadius.row),
          border: hasHandler ? null : Border.all(color: c.border),
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
                style: UgamText.bodyStrong.copyWith(
                  color: labelColor,
                  fontSize: 14,
                ),
              ),
            ),
            Icon(Icons.chevron_right_rounded, size: 18, color: c.ink3),
          ],
        ),
      ),
    );
  }
}
