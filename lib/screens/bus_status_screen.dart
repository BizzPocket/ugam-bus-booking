import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../components/combined_seat_grid.dart';
import '../components/seat_chart_tile.dart';
import '../controllers/tour_controller.dart';
import '../design/group_color.dart';
import '../design/ugam.dart';
import '../models/bus_details.dart';
import '../models/passenger.dart';
import '../models/tour.dart';
import '../models/seat_layout.dart';
import '../services/whatsapp_service.dart';
import '../utils/app_snackbar.dart';
import '../utils/passenger_display.dart';
import '../utils/admin_handler_operate.dart';
import '../utils/phone_dialer.dart';
import '../utils/tour_group_colors.dart';
import '../widgets/chart_expand_button.dart';
import '../widgets/occupant_action_sheet.dart';
import '../widgets/tour_roster_gate.dart';
import 'add_bus_screen.dart';
import 'bus_money_screen.dart';
import 'collection_screen.dart';
import 'fullscreen_chart_screen.dart';
import 'seats_screen.dart';

part 'bus_status/bus_status_header.dart';
part 'bus_status/bus_status_chart.dart';

/// Read-only seat layout for a single bus on a tour. Renders each seat
/// in the layout grid with the assigned passenger's name+phone overlaid
/// when taken. Tapping a booked seat surfaces a sheet with the
/// passenger's full name, phone, and seat list — useful for last-minute
/// checks before locking. No re-assignment happens here; that flow
/// lives in TourSeatAssignmentScreen.
///
/// Visual language: matches `seat_assignment_screen._SeatChartCard` /
/// `_SeatTile` exactly (same UgamColors, same `LayoutBuilder` width
/// math, same booked-vs-free body shapes) — minus the DragTarget /
/// LongPressDraggable wiring since this is view-only.
class BusStatusScreen extends StatefulWidget {
  final String tourId;
  final String busId;

  const BusStatusScreen({super.key, required this.tourId, required this.busId});

  @override
  State<BusStatusScreen> createState() => _BusStatusScreenState();
}

class _BusStatusScreenState extends State<BusStatusScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // A failure is surfaced by the body's [TourRosterGate] retry state.
      Get.find<TourController>()
          .ensureTourReadyForSeating(widget.tourId)
          .catchError((Object _) {});
    });
  }

  @override
  Widget build(BuildContext context) {
    final tourCtrl = Get.find<TourController>();
    final c = UgamColors.of(context);
    return UgamScaffold(
      body: SafeArea(
        child: Obx(() {
          final tour = tourCtrl.getTour(widget.tourId);
          final bus = tour?.buses.firstWhereOrNull((b) => b.id == widget.busId);
          if (tour == null || bus == null) {
            final notFound = UgamEmpty(
              icon: Icons.directions_bus_filled_outlined,
              title: tr('bus_status.bus_not_found'),
            );
            return Column(
              children: [
                UgamAppBar(title: tr('bus_status.bus_not_found')),
                Expanded(
                  // A bus missing from a tour whose roster has not answered yet
                  // (or failed to) is "loading" / "retry", not "not found".
                  child: tour == null
                      ? notFound
                      : TourRosterGate(
                          tourId: widget.tourId,
                          loading: const _StatusLoading(),
                          empty: notFound,
                        ),
                ),
              ],
            );
          }
          final layout = bus.layout;
          if (layout == null) {
            return Column(
              children: [
                _StatusAppBar(bus: bus, tourTitle: tour.title),
                Expanded(
                  child: UgamEmpty(
                    icon: Icons.event_seat_outlined,
                    title: tr('bus_status.no_layout'),
                  ),
                ),
              ],
            );
          }

          // Build seatId → passengers map. A doubleSofa cell may hold up
          // to two passengers when the agent has split the sofa between
          // unrelated singles; everything else has exactly one.
          final assignments = <String, List<Passenger>>{};
          for (final p in tour.passengers) {
            for (final a in p.assignedSeats) {
              if (a.busId == bus.id) {
                (assignments[a.seatId] ??= <Passenger>[]).add(p);
              }
            }
          }

          // THE seat meter's slice for this bus — the same "x / n" the
          // manage-buses row, dashboard and tour detail show (see [SeatMeter]).
          final busMeter = tourCtrl.seatMeterFor(tour).byBus[bus.id];
          final totalSeats = busMeter?.capacity ?? layout.totalSeats;
          final assignedCount =
              busMeter?.occupied ?? tour.occupiedBerthsFor(bus.id);

          return Column(
            children: [
              _StatusAppBar(
                bus: bus,
                tourTitle: tour.title,
                onMoney: () => _openMoneyMenu(context, tour.id, bus),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  UgamSpacing.gutter,
                  0,
                  UgamSpacing.gutter,
                  UgamSpacing.sm,
                ),
                child: _DriverHeroCard(bus: bus),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  UgamSpacing.gutter,
                  0,
                  UgamSpacing.gutter,
                  UgamSpacing.sm,
                ),
                child: _Tally(assigned: assignedCount, total: totalSeats),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: UgamSpacing.gutter,
                  ),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      _SeatChartCard(
                        layout: layout,
                        assignments: assignments,
                        groupColors: tourGroupColors(tour),
                        onSeatTap: (seatId, occupants) => _showSeatOccupants(
                          context,
                          seatId,
                          occupants,
                          bus,
                          tour.id,
                        ),
                      ),
                      if (layout.totalCells > 0)
                        ChartExpandButton(
                          onTap: () => FullscreenChartScreen.open(
                            context,
                            layout: layout,
                            occupantsBySeat: assignments,
                            groupColors: tourGroupColors(tour),
                            title: bus.name,
                            driverLabel: tr('bus_status.driver_label'),
                            markHalfDouble: true,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: UgamSpacing.sm),
              // Collapsed behind a one-line toggle: the 10-key grid sat open
              // under every chart and took ~4 rows from the seats themselves.
              UgamSeatChartLegendToggle(c: c),
              const SizedBox(height: UgamSpacing.sm),
              _BottomActions(
                tour: tour,
                bus: bus,
                onMoney: () => _openMoneyMenu(context, tour.id, bus),
                showOperateAsHandler: tourAllowsAdminHandlerOperate(
                  tour.status,
                ),
              ),
              const SizedBox(height: UgamSpacing.md),
            ],
          );
        }),
      ),
    );
  }

  /// Money actions sheet — surfaced from the app-bar so the fixed below-bar
  /// body no longer has to carry a second row of buttons (it overflowed on
  /// small phones). "Collect" jumps straight into the per-bus CollectionScreen
  /// (the SAME canonical destination the Tour money board's "Collect" shortcut
  /// uses) and "Bus money" opens the per-bus ledger. Navigation logic is
  /// preserved verbatim.
  void _openMoneyMenu(BuildContext context, String tourId, Bus bus) {
    UgamSheet.show<void>(
      context,
      title: tr('bus_status.action.collection_money'),
      builder: (sheetCtx) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          UgamButton(
            kind: UgamButtonKind.tonal,
            expand: true,
            icon: Icons.groups_rounded,
            label: tr('tour_money_board.collect'),
            onPressed: () => _openWithTour(
              sheetCtx,
              tourId,
              (tour) => CollectionScreen(tour: tour, bus: bus),
            ),
          ),
          const SizedBox(height: UgamSpacing.sm),
          UgamButton(
            kind: UgamButtonKind.neutral,
            expand: true,
            icon: Icons.payments_rounded,
            label: tr('bus_status.action.collection_money'),
            onPressed: () => _openWithTour(
              sheetCtx,
              tourId,
              (tour) => BusMoneyScreen(tour: tour, bus: bus),
            ),
          ),
        ],
      ),
    );
  }

  /// Closes the money sheet, then pushes [screen] for the CURRENT tour row —
  /// or says the tour is gone instead of pushing a stale snapshot.
  void _openWithTour(
    BuildContext sheetCtx,
    String tourId,
    Widget Function(Tour tour) screen,
  ) {
    Navigator.of(sheetCtx).pop();
    final tour = Get.find<TourController>().getTour(tourId);
    if (tour == null) {
      AppSnackBar.error(tr('bus_status.tour_not_found_refresh'));
      return;
    }
    Get.to(() => screen(tour), transition: Transition.cupertino);
  }

  /// Routes a seat tap by how many DISTINCT riders sit there. A Double Sofa can
  /// carry up to four (two berths × GO+RET), so a lone rider opens their detail
  /// sheet as before, while a shared seat opens the canonical read-only
  /// [OccupantActionSheet] listing everyone (with per-person call) — the same
  /// sheet the Charts screen uses, so no rider is hidden behind `.first`.
  void _showSeatOccupants(
    BuildContext context,
    String seatId,
    List<Passenger> occupants,
    Bus bus,
    String tourId,
  ) {
    final seen = <String>{};
    final distinct = [
      for (final p in occupants)
        if (seen.add(p.id)) p,
    ];
    if (distinct.isEmpty) return;
    if (distinct.length == 1) {
      _showPassengerSheet(context, distinct.first, bus, tourId);
      return;
    }
    OccupantActionSheet.show(
      context,
      occupants: distinct,
      tourId: bus.tourId?.isNotEmpty == true ? bus.tourId! : tourId,
      busId: bus.id,
      seatId: seatId,
      busName: bus.name,
      mode: OccupantSheetMode.readOnly,
    );
  }

  /// Bottom sheet that shows passenger details when a booked seat is
  /// tapped. Business logic preserved verbatim — same seat-list build,
  /// same handler-badge surfacing, same phone-call CTA.
  void _showPassengerSheet(
    BuildContext context,
    Passenger passenger,
    Bus bus,
    String tourId,
  ) {
    final tour = Get.find<TourController>().getTour(tourId);
    final c = UgamColors.of(context);
    final seatsOnBus = passenger.assignedSeats
        .where((a) => a.busId == bus.id)
        .map((a) => a.seatId)
        .join(', ');
    UgamSheet.show<void>(
      context,
      builder: (_) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      passenger.displayName,
                      style: UgamText.titleM.copyWith(color: c.ink),
                    ),
                    if (passenger.phone.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        passenger.phone,
                        style: UgamText.tabular(
                          UgamText.caption.copyWith(color: c.ink2),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              // Quick-call CTA — handler taps to dial the passenger
              // directly when something's wrong with their booking.
              if (passenger.phone.isNotEmpty) ...[
                const SizedBox(width: UgamSpacing.sm),
                GestureDetector(
                  onTap: () => PhoneDialer.call(passenger.phone),
                  behavior: HitTestBehavior.opaque,
                  child: Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: c.accentFill,
                      shape: BoxShape.circle,
                    ),
                    alignment: Alignment.center,
                    child: Icon(Icons.phone_rounded, size: 18, color: c.accent),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: UgamSpacing.md),
          _SheetRow(label: tr('bus_status.sheet_bus'), value: bus.name),
          _SheetRow(
            label: tr('bus_status.sheet_seats_on_bus'),
            value: seatsOnBus,
          ),
          if (tour != null && tour.handlerId == passenger.id)
            const Padding(
              padding: EdgeInsets.only(top: 10),
              child: _HandlerBadge(),
            ),
        ],
      ),
    );
  }
}

/// Placeholder while the tour's roster is still on its way — the shape of the
/// driver card and the chart, so nothing jumps when the bus lands.
class _StatusLoading extends StatelessWidget {
  const _StatusLoading();

  @override
  Widget build(BuildContext context) {
    // A non-scrolling list, so a short screen clips the placeholder instead of
    // painting an overflow stripe.
    return ListView(
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.symmetric(horizontal: UgamSpacing.gutter),
      children: const [
        UgamSkeleton(height: 96, radius: UgamRadius.card),
        SizedBox(height: UgamSpacing.md),
        UgamSkeleton(height: 320, radius: UgamRadius.card),
      ],
    );
  }
}
