import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../components/combined_seat_grid.dart';
import '../components/seat_chart_tile.dart';
import '../controllers/tour_controller.dart';
import '../design/group_color.dart';
import '../design/ugam.dart';
import '../models/bus_details.dart';
import '../models/passenger.dart';
import '../models/seat_layout.dart';
import '../models/tour.dart';
import '../routes/app_routes.dart';
import '../utils/app_snackbar.dart';
import '../utils/seat_occupants.dart';
import '../utils/tour_capacity.dart';
import '../utils/tour_group_colors.dart';
import '../widgets/chart_expand_button.dart';
import '../widgets/occupant_action_sheet.dart';
import 'add_bus_screen.dart';
import 'create_tour_screen.dart';
import 'fullscreen_chart_screen.dart';

part 'charts/charts_widgets.dart';

/// Top-level CHARTS tab — a one-tap, read-only seat-chart browser.
///
/// Previously the agent reached a bus chart only through a 5–6 tap drill-down
/// (Tours → tour → Seats → summary → bus card → grid). This surface flattens
/// that: pick a tour (pills), pick a bus (pills), and the canonical read-only
/// chart is on screen immediately. It defaults to the nearest upcoming active
/// tour that has buses and that tour's first bus, so a chart is visible with
/// ZERO extra taps after opening the tab.
///
/// View-only by design: it renders the SAME [SeatChartTile] / [CombinedSeatGrid]
/// the agent assign / handler / bus-status charts use (group & priority rings,
/// one-way leg colours, the shared full-screen blow-up) but writes nothing.
/// Tapping a booked seat opens a minimal read-only occupant sheet; an "Edit
/// seats" link routes into the unified editable grid for anyone who wants to act.
class ChartsScreen extends StatefulWidget {
  const ChartsScreen({super.key});

  @override
  State<ChartsScreen> createState() => _ChartsScreenState();
}

class _ChartsScreenState extends State<ChartsScreen> {
  final tourCtrl = Get.find<TourController>();

  /// The agent's current tour pick. Null until a first pick is resolved (or
  /// when the chosen tour scrolls out of the eligible set). Tracked by id, not
  /// index, so realtime reordering / additions don't shift the selection.
  String? _selectedTourId;

  /// The current bus pick within the selected tour, by id. Null falls back to
  /// the tour's first bus.
  String? _selectedBusId;

  String? _layoutWarmTourId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _warmLayouts());
  }

  void _warmLayouts([String? tourId]) {
    final eligible = _eligibleTours();
    final tour = tourId != null
        ? eligible.firstWhereOrNull((t) => t.id == tourId) ??
            _resolveTour(eligible)
        : _resolveTour(eligible);
    if (tour == null) return;
    if (_layoutWarmTourId == tour.id) return;
    _layoutWarmTourId = tour.id;
    // ignore: unawaited_futures
    tourCtrl.ensureTourReadyForSeating(tour.id);
  }

  /// Active tours that carry at least one bus, soonest departure first — the
  /// only tours that can show a chart. A stable, defensively-copied sort.
  List<Tour> _eligibleTours() {
    final list = tourCtrl.activeTours.where((t) => t.buses.isNotEmpty).toList()
      ..sort((a, b) => a.departureDate.compareTo(b.departureDate));
    return list;
  }

  /// Resolves the tour to show: the agent's pick when it is still eligible,
  /// else the nearest upcoming one (first of the soonest-first list).
  Tour? _resolveTour(List<Tour> eligible) {
    if (eligible.isEmpty) return null;
    final id = _selectedTourId;
    if (id != null) {
      final match = eligible.firstWhereOrNull((t) => t.id == id);
      if (match != null) return match;
    }
    return eligible.first;
  }

  /// Resolves the bus to show within [tour]: the agent's pick when it is still
  /// on the tour, else the first bus.
  Bus? _resolveBus(Tour tour) {
    if (tour.buses.isEmpty) return null;
    final id = _selectedBusId;
    if (id != null) {
      final match = tour.buses.firstWhereOrNull((b) => b.id == id);
      if (match != null) return match;
    }
    return tour.buses.first;
  }

  void _pickTour(String tourId) {
    // Haptic fires inside UgamSelectorPills.onChanged.
    setState(() {
      _selectedTourId = tourId;
      // A fresh tour resets the bus pick so the new tour's first bus shows.
      _selectedBusId = null;
      _layoutWarmTourId = null;
    });
    _warmLayouts(tourId);
  }

  void _pickBus(String busId) {
    // Haptic fires inside UgamSelectorPills.onChanged.
    setState(() => _selectedBusId = busId);
  }

  /// Routes into the unified editable seat grid for this bus. The chart screen
  /// itself stays read-only; this is the one-tap hand-off to the editor.
  void _editSeats(String tourId, String busId) {
    HapticFeedback.lightImpact();
    Get.toNamed(
      AppRoutes.seatAssignment,
      arguments: {'tourId': tourId, 'busId': busId},
    );
  }

  /// The empty chart's way out. A bus with no seat layout used to be a dead
  /// end here — a grey glyph and a sentence, with no way to fix it from the
  /// screen that reported the problem.
  ///
  /// The layout is generated in exactly one place in the app: the add/edit-bus
  /// wizard's save path (`BusLayout.generate` in `add_bus_screen.dart`), driven
  /// by its Step 2 "capacity & layout" inputs and its edit-only "Regenerate
  /// layout" action. So the CTA opens THIS bus in that wizard rather than
  /// inventing a layout editor that does not exist. Same push shape as the
  /// no-buses empty state above.
  void _createLayout(Tour tour, Bus bus) {
    HapticFeedback.lightImpact();
    Get.to(
      () => AddBusScreen(tourId: tour.id, existing: bus),
      transition: Transition.cupertino,
    );
  }

  /// Rebuild a LOST grid rather than generating a new one.
  ///
  /// `TourController.recoverBusLayoutFor` re-derives the layout from the bus's
  /// seat count, its type, and the seat ids the riders are still holding, then
  /// writes ONLY the layout column. Every candidate it considers hosts every
  /// surviving id identically, so nobody moves — which is the whole difference
  /// between this and [_createLayout], where a regenerate renumbers the seats
  /// and unassigns the people sitting in them.
  ///
  /// It can legitimately fail to find exactly one answer (a bus whose surviving
  /// ids fit several layouts, or none). It says which in `reason`, and that is
  /// surfaced verbatim instead of a generic error — the reason names the actual
  /// obstacle and is the only lead the agent has.
  Future<void> _recoverLayout(Tour tour, Bus bus) async {
    HapticFeedback.lightImpact();
    final confirmed = await UgamDialog.confirm(
      context,
      title: tr('charts.recover_confirm_title'),
      message: tr('charts.recover_confirm_body'),
      confirmLabel: tr('charts.recover_layout'),
    );
    if (!confirmed || !mounted) return;

    final result = await tourCtrl.recoverBusLayoutFor(tour.id, bus.id);
    if (!mounted) return;
    if (result.recovered) {
      AppSnackBar.success(tr('charts.recover_done'));
    } else {
      AppSnackBar.error(result.reason);
    }
  }

  /// Builds the seatId → occupants map for [bus] from [tour]'s passengers. A
  /// doubleSofa cell may hold up to two passengers (a split sofa, or a disjoint
  /// GO/RETURN leg reuse); everything else has exactly one. Same shape the
  /// canonical tile and the full-screen view consume.
  Map<String, List<Passenger>> _assignmentsFor(Tour tour, Bus bus) {
    final assignments = <String, List<Passenger>>{};
    for (final p in tour.passengers) {
      for (final a in p.assignedSeats) {
        if (a.busId == bus.id) {
          (assignments[a.seatId] ??= <Passenger>[]).add(p);
        }
      }
    }
    return assignments;
  }

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return UgamScaffold(
      body: SafeArea(
        bottom: false,
        child: Obx(() {
          final eligible = _eligibleTours();
          final resolved = _resolveTour(eligible);
          if (resolved != null) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              _warmLayouts(resolved.id);
            });
          }
          if (eligible.isEmpty) {
            // No active tour has a bus yet — make the empty state actionable.
            // If an active tour exists, jump into adding a bus to the nearest
            // upcoming one; otherwise there's no tour to add a bus to, so the
            // CTA offers tour creation instead of being a dead end.
            final activeTours = tourCtrl.activeTours;
            final Tour? addBusTarget = activeTours.isEmpty
                ? null
                : (activeTours.toList()
                      ..sort((a, b) =>
                          a.departureDate.compareTo(b.departureDate)))
                    .first;
            return Column(
              children: [
                UgamAppBar(title: tr('charts.title'), showBack: false),
                Expanded(
                  child: UgamEmpty(
                    icon: Icons.event_seat_outlined,
                    title: tr('charts.empty.title'),
                    body: tr('charts.empty.body'),
                    cta: UgamCTA(
                      label: addBusTarget != null
                          ? tr('add_bus.title')
                          : tr('create_tour.title'),
                      leadingIcon: Icons.add_rounded,
                      onPressed: () {
                        HapticFeedback.lightImpact();
                        final target = addBusTarget;
                        // Both branches push the same way — the single empty
                        // -state button used to animate differently depending
                        // on which label it happened to be showing.
                        if (target != null) {
                          Get.to(
                            () => AddBusScreen(tourId: target.id),
                            transition: Transition.cupertino,
                          );
                        } else {
                          Get.to(
                            () => const CreateTourScreen(),
                            transition: Transition.cupertino,
                          );
                        }
                      },
                    ),
                  ),
                ),
              ],
            );
          }

          final tour = _resolveTour(eligible)!;
          final bus = _resolveBus(tour)!;
          final layout = bus.layout;
          final assignments = _assignmentsFor(tour, bus);
          // De-duped, leg-aware distinct occupants per seat (the shared
          // resolver). Feeds the read-only sheet so a shared/leg-shared double
          // shows BOTH names; the raw `assignments` above still feeds the tile.
          final sheetOccupants = occupantListForBus(tour.passengers, bus.id);
          final groupColors = tourGroupColors(tour);
          // Denominator through the shared [busBerths] definition so a bus whose
          // layout jsonb has not landed (or was lost) reads its legacy seat
          // count instead of 0 — this bar used to render "36/0". Held cells are
          // added back because this is the bus's PHYSICAL size, matching what
          // `layout.totalSeats` reported before the fallback existed.
          final berths = busBerths(bus);
          final totalSeats = berths.sellable + berths.reserved;
          // Leg-aware fill count (busier leg = max(GO, RET)) — NOT a raw fold
          // of `assignments` entries. A seat shared by an outbound-only rider
          // and a return-only rider produces two disjoint assignment entries
          // on ONE physical berth; folding them double-counts and can read
          // past capacity (e.g. "40/37"). `assignments` itself is untouched —
          // it still feeds the tile grid, which needs the raw per-seat lists.
          //
          // Both numbers then come from THE seat meter's slice for this bus
          // when it has one ([SeatMeter]), so this bar reads the same "x / n"
          // as manage buses, bus status and the dashboard.
          final busMeter =
              Get.find<TourController>().seatMeterFor(tour).byBus[bus.id];
          final assignedCount =
              busMeter?.occupied ?? tour.occupiedBerthsFor(bus.id);
          final meterTotal = (busMeter?.capacity ?? 0) > 0
              ? busMeter!.capacity
              : totalSeats;
          // ONE truth for "there is a grid on screen", so the expand button,
          // the edit-seats pill and the legend can never disagree. Non-null
          // exactly when a real grid renders, which also keeps type promotion
          // at the call sites that need the layout itself.
          final chartLayout =
              (layout != null && layout.totalCells > 0) ? layout : null;
          // The edit-seats pill floats ON the chart card, so the chart's scroll
          // extent has to stop above it. Without this the rear row (DL6 / DU6
          // on a 40-berth sleeper) came to rest UNDER the pill at maximum
          // scroll and those two berths could not be tapped at all. Reserving
          // the pill's own height plus its bottom offset leaves the last berth
          // clear whether the grid scrolls or fits.
          final fabReserve = UgamScale.tap(context, 50) + UgamSpacing.sm;

          return Column(
            children: [
              UgamAppBar(title: tr('charts.title'), showBack: false),
              if (eligible.length > 1) ...[
                // Faded, so a tour list that runs past the edge reads as
                // scrollable instead of looking like a title clipped mid-word.
                _ScrollEdgeFade(
                  child: UgamSelectorPills(
                    items: [
                      for (final t in eligible) UgamSelectorItem(label: t.title),
                    ],
                    currentIndex: eligible.indexWhere((t) => t.id == tour.id),
                    onChanged: (i) => _pickTour(eligible[i].id),
                  ),
                ),
                const SizedBox(height: UgamSpacing.md),
              ],
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  UgamSpacing.gutter,
                  UgamSpacing.sm,
                  UgamSpacing.gutter,
                  UgamSpacing.sm,
                ),
                child: _BusBar(
                  tour: tour,
                  bus: bus,
                  assigned: assignedCount,
                  total: meterTotal,
                  onPickBus: _pickBus,
                  c: c,
                ),
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
                        loaded: tourCtrl.layoutsLoadedFor(tour.id),
                        assignments: assignments,
                        sheetOccupants: sheetOccupants,
                        groupColors: groupColors,
                        // Only a rendered grid sits under the floating pill, so
                        // only a rendered grid reserves room for it.
                        bottomReserve: chartLayout == null ? 0 : fabReserve,
                        onCreateLayout: () => _createLayout(tour, bus),
                        seatedRiders: assignedCount,
                        onRecoverLayout: () => _recoverLayout(tour, bus),
                        onSeatTap: (seatId, occupants) =>
                            _showOccupantSheet(context, seatId, occupants, bus),
                      ),
                      if (chartLayout != null)
                        ChartExpandButton(
                          onTap: () => FullscreenChartScreen.open(
                            context,
                            layout: chartLayout,
                            occupantsBySeat: assignments,
                            groupColors: groupColors,
                            title: bus.name,
                            driverLabel: tr('charts.driver_label'),
                            markHalfDouble: true,
                          ),
                        ),
                      // Thumb-reachable "edit seats" hand-off as a small FAB
                      // overlaying the chart's bottom-right, instead of a
                      // full-width footer button that pushed the legend up and
                      // ate vertical chart space. It floats over the card's
                      // reserved bottom band (see `fabReserve`), never over a
                      // berth. The legend stays below.
                      if (chartLayout != null)
                        Positioned(
                          right: UgamSpacing.sm,
                          bottom: UgamSpacing.sm,
                          child: _EditSeatsFab(
                            onTap: () => _editSeats(tour.id, bus.id),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              // Ten colour codes is more than anyone holds at once, and below
              // an EMPTY chart they explain seats that do not exist. So: shown
              // only when a grid is on screen, and folded behind a one-line
              // "what do the colours mean?" header that keeps all ten entries
              // one tap away.
              if (chartLayout != null) ...[
                const SizedBox(height: UgamSpacing.sm),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: UgamSpacing.gutter,
                  ),
                  child: UgamExpander(
                    title: tr('charts.legend_toggle'),
                    icon: Icons.palette_outlined,
                    // [UgamExpander]'s header is a bare Row — its tallest
                    // child is the 22pt chevron, so its opaque tap area is
                    // 22pt, half the 44pt floor. A zero-width spacer in the
                    // trailing slot is the only lever this screen has to
                    // raise it without editing the shared component.
                    trailing: SizedBox(height: UgamScale.tap(context, 44)),
                    child: UgamSeatChartLegend(c: c),
                  ),
                ),
              ],
              SizedBox(
                height: MediaQuery.of(context).padding.bottom + UgamSpacing.md,
              ),
            ],
          );
        }),
      ),
    );
  }

  /// READ-ONLY occupant sheet for a tapped seat. Hands the seat's FULL distinct
  /// occupant list to the shared [OccupantActionSheet] in
  /// [OccupantSheetMode.readOnly]: a shared / leg-shared double surfaces BOTH
  /// names via the sheet's person toggle (the bug fix), with the call row but
  /// no editing — re-seating lives in the unified grid behind "Edit seats".
  void _showOccupantSheet(
    BuildContext context,
    String seatId,
    List<Passenger> occupants,
    Bus bus,
  ) {
    if (occupants.isEmpty) return;
    OccupantActionSheet.show(
      context,
      occupants: occupants,
      tourId: bus.tourId ?? occupants.first.tourId,
      busId: bus.id,
      seatId: seatId,
      busName: bus.name,
      mode: OccupantSheetMode.readOnly,
    );
  }
}
