import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../controllers/tour_controller.dart';
import '../design/components/ugam_tappable.dart';
import '../design/ugam.dart';
import '../models/bus_details.dart';
import '../models/passenger.dart';
import '../models/tour.dart';
import '../models/tour_status.dart';
import '../utils/app_snackbar.dart';
import '../utils/passenger_display.dart';
import '../utils/phone_dialer.dart';
import '../utils/time_format.dart';
import '../utils/tour_capacity.dart';
import 'add_bus_screen.dart';
import 'bus_status_screen.dart';


/// List of buses attached to a tour. Topbar + photo-anchored bus cards
/// (matching the image-5 list pattern) + sticky bottom CTA to add a new bus.
///
/// Post-lock (and completed): seat edits stay allowed elsewhere, but bus
/// layout add/edit/duplicate/delete is frozen — see [TourStatus.allowsLayoutEdit].
/// That freeze is announced with a caveat strip rather than by silently
/// removing the Add-bus CTA and every menu entry.
class ManageBusesScreen extends StatelessWidget {
  final String tourId;

  const ManageBusesScreen({super.key, required this.tourId});

  TourController get _tourCtrl => Get.find<TourController>();

  bool _layoutEditable(Tour tour) => tour.status.allowsLayoutEdit;

  /// Opens a sheet with the per-bus actions: edit, call the driver, delete.
  void _openBusMenu(BuildContext context, Tour tour, Bus bus) {
    final canEditLayout = _layoutEditable(tour);
    UgamSheet.show<void>(
      context,
      title: bus.displayLabel,
      builder: (ctx) {
        final c = UgamColors.of(ctx);
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Edit is NOT gated on the layout lock. The lock freezes the seat
            // chart, and this entry is the only route to the driver name and
            // phone, the boarding point, the departure time and the pricing —
            // the fields most likely to change on departure day, which is
            // exactly when the tour is locked. `TourController.updateBus` now
            // gates on `layoutChanged` rather than on status, so a detail edit
            // lands and a re-layout after lock still refuses; and the wizard
            // freezes its own capacity step (see `AddBusScreen`) so the refusal
            // is never something the agent can walk into. Duplicate and delete
            // below stay gated: both change how many buses the notified chart
            // has, which is what the lock exists to hold still.
            _BusMenuTile(
              c: c,
              icon: Icons.edit_rounded,
              label: tr('manage_buses.menu_edit'),
              onTap: () {
                Navigator.of(ctx).pop();
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (context) =>
                        AddBusScreen(tourId: tourId, existing: bus),
                  ),
                );
              },
            ),
            // Duplicate: open the add wizard seeded from this bus as a template
            // (capacity, layout, pricing, boarding, departure, AC all carry
            // over) but STAY in add mode, so save creates a new bus in the next
            // slot. The plate and driver are left blank for the new vehicle.
            if (canEditLayout)
              _BusMenuTile(
                c: c,
                icon: Icons.copy_all_rounded,
                label: tr('manage_buses.menu_duplicate'),
                onTap: () {
                  Navigator.of(ctx).pop();
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (context) =>
                          AddBusScreen(tourId: tourId, templateBus: bus),
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
            if (canEditLayout) ...[
              // The gap is the separation: delete must not sit in the same
              // rhythm as the harmless entries above it.
              const SizedBox(height: UgamSpacing.md),
              _BusMenuTile(
                c: c,
                icon: Icons.delete_outline_rounded,
                label: tr('manage_buses.menu_delete'),
                subtitle: tr('manage_buses.menu_delete_subtitle'),
                danger: true,
                onTap: () {
                  Navigator.of(ctx).pop();
                  _confirmDelete(context, tour, bus);
                },
              ),
            ],
            // A locked tour with no driver number used to open a sheet with a
            // title and NOTHING under it. Say why instead.
            if (!canEditLayout) ...[
              const SizedBox(height: UgamSpacing.sm),
              UgamCaveat(
                message: tr('manage_buses.layout_locked_body'),
                icon: Icons.lock_outline_rounded,
              ),
            ],
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

  void _openAddBus(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (context) => AddBusScreen(tourId: tourId)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    // Layouts deferred on cold start for 2G — coalesced / idempotent.
    // ignore: unawaited_futures
    _tourCtrl.ensureTourReadyForSeating(tourId);

    return UgamScaffold(
      body: SafeArea(
        child: Obx(() {
          final tour = _tourCtrl.getTour(tourId);

          // The app bar is rendered on EVERY path now. It used to be inside the
          // "tour found" branch only, so any of the states below stranded the
          // agent on a screen with no back button.
          if (tour == null) {
            return Column(
              children: [
                UgamAppBar(title: tr('manage_buses.title')),
                Expanded(child: _missingTourState()),
              ],
            );
          }

          // Single engine-sourced capacity snapshot for the whole screen:
          // feeds the app-bar "free seats" subtitle AND each per-bus meter
          // (via cap.byBus[bus.id]) so the list never re-derives its own count.
          final cap = _tourCtrl.capacityFor(tour);
          final totalCapacity = cap.capacity;
          final canEdit = _layoutEditable(tour);

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
              // Why the Add-bus CTA and the per-bus edit/delete entries are
              // gone. Wraps (a Gujarati sentence runs ~30% long), so it says
              // the whole thing rather than trailing off.
              if (!canEdit)
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    UgamSpacing.gutter,
                    UgamSpacing.xs,
                    UgamSpacing.gutter,
                    0,
                  ),
                  child: UgamCaveat(
                    message: tr('manage_buses.layout_locked_body'),
                    icon: Icons.lock_outline_rounded,
                  ),
                ),
              const SizedBox(height: UgamSpacing.sm),
              Expanded(
                child: tour.buses.isEmpty
                    ? UgamEmpty(
                        icon: Icons.directions_bus_outlined,
                        title: tr('manage_buses.empty_title'),
                        body: tr('manage_buses.empty_body'),
                        // From zero buses there is exactly one thing to do, and
                        // it belongs here — not 500px away behind a sticky bar
                        // at the foot of an otherwise blank screen.
                        cta: canEdit
                            ? UgamButton(
                                label: tr('manage_buses.add_bus'),
                                icon: Icons.add_rounded,
                                onPressed: () => _openAddBus(context),
                              )
                            : null,
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.fromLTRB(
                          UgamSpacing.gutter,
                          0,
                          UgamSpacing.gutter,
                          // Was a flat 120. This Scaffold HAS a
                          // bottomNavigationBar, so the body already stops
                          // above the sticky CTA (which pays for the floating
                          // dock through its own SafeArea) — the 120 was dead
                          // space under the last card, not clearance.
                          UgamSpacing.lg,
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
      // Add-bus CTA — hidden once the tour is locked/completed (seats still
      // editable elsewhere; bus layout is frozen) and while the list is empty,
      // where the empty state owns the action instead.
      bottomNavigationBar: Obx(() {
        final tour = _tourCtrl.getTour(tourId);
        final showCta =
            tour != null && _layoutEditable(tour) && tour.buses.isNotEmpty;
        if (!showCta) {
          // A zero-height bar still strips the body SafeArea's bottom inset
          // (Scaffold checks for non-null, not for height), so reserve the
          // inset when the add-bus CTA is hidden. Pushed on the shell's nested
          // navigator this measures the floating dock, not just the system bar.
          return SizedBox(height: MediaQuery.paddingOf(context).bottom);
        }
        return UgamStickyCTA(
          child: UgamCTA(
            label: tr('manage_buses.add_bus'),
            leadingIcon: Icons.add_rounded,
            onPressed: () => _openAddBus(context),
          ),
        );
      }),
    );
  }

  /// Body for "the controller has no tour with this id" — which is three
  /// different situations the screen used to collapse into one bald "Tour not
  /// found": the first load is still running, the load failed, or the tour is
  /// genuinely gone.
  Widget _missingTourState() {
    if (_tourCtrl.isLoading.value) return const _BusListSkeleton();
    if (_tourCtrl.hasError.value) {
      // The localised default, NOT `errorMessage` — that carries a raw
      // Postgrest string ("column … does not exist (42703)") which is English
      // and meaningless to the Gujarati-first operators this app is built for.
      return UgamEmpty.error(onRetry: () => _tourCtrl.refreshTours());
    }
    return UgamEmpty(
      icon: Icons.search_off_rounded,
      title: tr('manage_buses.tour_not_found'),
    );
  }
}

/// First-load placeholder shaped like the bus list it becomes, instead of a
/// centred spinner that pops.
class _BusListSkeleton extends StatelessWidget {
  const _BusListSkeleton();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        UgamSpacing.gutter,
        0,
        UgamSpacing.gutter,
        UgamSpacing.lg,
      ),
      children: [
        for (var i = 0; i < 3; i++) ...[
          const UgamSkeleton(height: 176, radius: UgamRadius.card),
          const SizedBox(height: UgamSpacing.md),
        ],
      ],
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
    // Decorative thumbnail — [px], not [tap]: nothing lands on it.
    final photo = UgamScale.px(context, 76);
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
                    width: photo,
                    height: photo,
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
                        style: UgamText.titleS.copyWith(color: c.ink),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      // Line 1: driver name (emphasised). Line 2: boarding +
                      // departure (muted). Phone is no longer crammed here — it
                      // moved into the bus action sheet ("Call driver").
                      if (_driverLine.isNotEmpty) ...[
                        const SizedBox(height: UgamSpacing.xs),
                        Text(
                          _driverLine,
                          style: UgamText.bodyStrong.copyWith(color: c.ink),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                      if (_departureLine.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          _departureLine,
                          style: UgamText.caption.copyWith(color: c.ink2),
                          maxLines: 2,
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
                  semanticLabel: tr('manage_buses.menu_more'),
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
    return UgamTappable(
      onTap: onTap,
      semanticLabel: hasHandler
          ? tr('bus_handler.row_current', namedArgs: {'name': handlerName!})
          : tr('bus_handler.row_empty'),
      child: Container(
        // Was ~32pt tall (sm padding around a 12pt caption) on a row that is
        // the only way into the handler picker.
        constraints: BoxConstraints(minHeight: UgamScale.tap(context, 44)),
        padding: const EdgeInsets.symmetric(
          horizontal: UgamSpacing.md,
          vertical: UgamSpacing.sm,
        ),
        // No hand-rolled border on the neutral state — depth comes from a
        // recessed fill (base card tone, sunk into the elevated bus card)
        // instead of a hairline. The set state keeps the copper accent tint:
        // an assigned handler is an ownership marker, which is exactly what
        // the accent is rationed for.
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
                // Two lines: "Handler: <Gujarati name>" is the longest string
                // on the card and a single line ellipsised the name away.
                maxLines: 2,
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
    final avatar = UgamScale.px(context, 36);
    return UgamTappable(
      onTap: onTap,
      semanticLabel: passenger.displayName,
      child: Container(
        margin: const EdgeInsets.only(bottom: UgamSpacing.sm),
        constraints: BoxConstraints(minHeight: UgamScale.tap(context, 56)),
        padding: const EdgeInsets.all(UgamSpacing.md),
        decoration: BoxDecoration(
          color: c.cardElev,
          borderRadius: BorderRadius.circular(UgamRadius.row),
          border: isCurrent ? Border.all(color: c.accent, width: 1.5) : null,
        ),
        child: Row(
          children: [
            Container(
              width: avatar,
              height: avatar,
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
                ),
              ),
            ),
            const SizedBox(width: UgamSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 2 lines before ellipsis — app-wide name rule, see
                  // UgamRequestRow.
                  Text(
                    passenger.displayName,
                    style: UgamText.bodyStrong.copyWith(color: c.ink),
                    maxLines: 2,
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
            if (isCurrent) ...[
              const SizedBox(width: UgamSpacing.sm),
              Icon(Icons.check_circle_rounded, size: 20, color: c.accent),
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

  /// Optional muted second line under the label (e.g. the driver's phone
  /// number on the "Call driver" tile, or what deleting actually costs).
  final String? subtitle;
  final bool danger;
  final VoidCallback onTap;

  const _BusMenuTile({
    required this.c,
    required this.icon,
    required this.label,
    required this.onTap,
    this.subtitle,
    this.danger = false,
  });

  @override
  Widget build(BuildContext context) {
    final fg = danger ? c.danger : c.ink;
    // InkWell (ripple + 48dp tap target) replaces the raw GestureDetector;
    // selection haptic on tap for native feel.
    //
    // The destructive tile's fill rides an [Ink] ABOVE the InkWell rather than
    // a Container below it: a decorated child paints over the Material the
    // splash lands on, which would have left the one tile that most needs to
    // acknowledge the finger as the only tile with no visible press at all.
    return Material(
      color: Colors.transparent,
      child: Ink(
        // A destructive entry carries its own tonal danger surface, so it is
        // recognisable before the label is read. `warmFill` (rose) on the old
        // medallion said "a lady is seated here", not "this destroys data".
        decoration: danger
            ? BoxDecoration(
                color: c.dangerFill,
                borderRadius: BorderRadius.circular(UgamRadius.row),
                border: Border.all(color: c.danger.withValues(alpha: 0.28)),
              )
            : null,
        child: InkWell(
          onTap: () {
            HapticFeedback.selectionClick();
            onTap();
          },
          borderRadius: BorderRadius.circular(UgamRadius.row),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: UgamScale.tap(context, 56)),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                vertical: UgamSpacing.md,
                horizontal: UgamSpacing.md,
              ),
              child: Row(
                children: [
                  Container(
                    width: UgamScale.px(context, 36),
                    height: UgamScale.px(context, 36),
                    decoration: BoxDecoration(
                      color: danger
                          ? c.danger.withValues(alpha: 0.14)
                          : c.cardElev,
                      shape: BoxShape.circle,
                    ),
                    alignment: Alignment.center,
                    child: Icon(icon, size: 18, color: fg),
                  ),
                  const SizedBox(width: UgamSpacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          label,
                          style: UgamText.bodyStrong.copyWith(color: fg),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (subtitle != null &&
                            subtitle!.trim().isNotEmpty) ...[
                          const SizedBox(height: 2),
                          // Wraps rather than truncating: the delete tile's
                          // subtitle is a full Gujarati sentence and it is the
                          // line that says what the tap costs.
                          Text(
                            subtitle!,
                            style: UgamText.caption.copyWith(color: c.ink2),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: UgamSpacing.sm),
                  Icon(Icons.chevron_right_rounded, size: 18, color: c.ink3),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
