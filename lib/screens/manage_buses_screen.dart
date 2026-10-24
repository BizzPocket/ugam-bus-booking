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
import '../utils/in_flight.dart';
import '../utils/passenger_display.dart';
import '../utils/phone_dialer.dart';
import '../utils/time_format.dart';
import '../utils/admin_handler_operate.dart';
import '../utils/tour_capacity.dart';
import '../widgets/tour_roster_gate.dart';
import 'add_bus_screen.dart';
import 'bus_status_screen.dart';

part 'manage_buses/manage_buses_list_item.dart';
part 'manage_buses/manage_buses_sheet_tiles.dart';

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

  /// Plain MaterialPageRoute push — the one transition every destination off
  /// this screen uses.
  void _push(BuildContext context, Widget screen) {
    Navigator.of(context).push(MaterialPageRoute(builder: (context) => screen));
  }

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
                _push(context, AddBusScreen(tourId: tourId, existing: bus));
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
                  _push(
                    context,
                    AddBusScreen(tourId: tourId, templateBus: bus),
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
            if (tourAllowsAdminHandlerOperate(tour.status))
              _BusMenuTile(
                c: c,
                icon: Icons.manage_accounts_rounded,
                label: tr('manage_buses.menu_operate_as_handler'),
                subtitle: tr('manage_buses.menu_operate_as_handler_subtitle'),
                onTap: () {
                  Navigator.of(ctx).pop();
                  openAdminHandlerOperate(tour: tour, busId: bus.id);
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
      title: tr(
        'bus_handler.picker_title',
        namedArgs: {'bus': bus.displayLabel},
      ),
      builder: (ctx) {
        final c = UgamColors.of(ctx);
        // Live bus so the current-handler highlight reflects the latest pick.
        final liveBus =
            _tourCtrl
                .getTour(tour.id)
                ?.buses
                .firstWhereOrNull((b) => b.id == bus.id) ??
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
                  // One handler write per bus at a time: the sheet closes on
                  // tap, so a re-opened picker must not stack a second write
                  // behind a slow first one.
                  await InFlight.run('bus-handler:${bus.id}', () async {
                    await _tourCtrl.setBusHandler(tour.id, bus.id, p.id);
                    AppSnackBar.success(
                      tr(
                        'bus_handler.set_done',
                        namedArgs: {'name': p.displayName},
                      ),
                    );
                  });
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
                  await InFlight.run('bus-handler:${bus.id}', () async {
                    await _tourCtrl.removeBusHandler(tour.id, bus.id);
                    AppSnackBar.success(tr('bus_handler.remove_done'));
                  });
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
      message: tr(
        'manage_buses.delete_body',
        namedArgs: {'bus': bus.displayLabel},
      ),
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

  void _openAddBus(BuildContext context) =>
      _push(context, AddBusScreen(tourId: tourId));

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);

    return UgamScaffold(
      body: SafeArea(
        // Roster + layouts (deferred on cold start for 2G), fetched ONCE per
        // open. It used to be fired from this build, so a failed read re-sent
        // itself on every rebuild.
        child: EnsureTourReady(
          tourId: tourId,
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

          // THE seat meter (see [SeatMeter]) for the whole screen:
          // feeds the app-bar "free seats" subtitle AND each per-bus meter
          // (via cap.byBus[bus.id]) so the list never re-derives its own count.
          final cap = _tourCtrl.seatMeterFor(tour);
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
              ? tr(
                  'manage_buses.subtitle_seats_free',
                  namedArgs: {
                    'free': '${cap.free}',
                    'capacity': '$totalCapacity',
                  },
                )
              : null;
          final summaryLine = [
            busesLabel,
            seatsLabel,
          ].whereType<String>().join('  ·  ');

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
                    // Information, not an alarm: a locked tour is the normal
                    // state after Lock & notify.
                    tone: UgamCaveatTone.info,
                  ),
                ),
              const SizedBox(height: UgamSpacing.sm),
              Expanded(
                child: tour.buses.isEmpty
                    // "No buses · Add bus" only once the roster has answered —
                    // while hydrating, or after it failed, this tour may well
                    // have buses, and the CTA would add a duplicate.
                    ? TourRosterGate(
                        tourId: tourId,
                        loading: const _BusListSkeleton(),
                        empty: UgamEmpty(
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
                      ),
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
                            onOpen: () => _push(
                              context,
                              BusStatusScreen(tourId: tourId, busId: bus.id),
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
