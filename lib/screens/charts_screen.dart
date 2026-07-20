import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
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
import '../utils/seat_occupants.dart';
import '../utils/tour_group_colors.dart';
import '../widgets/chart_expand_button.dart';
import '../widgets/occupant_action_sheet.dart';
import 'add_bus_screen.dart';
import 'create_tour_screen.dart';
import 'fullscreen_chart_screen.dart';

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
    });
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
                _Header(c: c),
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
                        if (target != null) {
                          Get.to(() => AddBusScreen(tourId: target.id));
                        } else {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => const CreateTourScreen(),
                            ),
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
          final totalSeats = layout?.totalSeats ?? 0;
          final assignedCount = assignments.values.fold<int>(
            0,
            (sum, list) => sum + list.length,
          );

          return Column(
            children: [
              _Header(c: c),
              if (eligible.length > 1) ...[
                UgamSelectorPills(
                  items: [
                    for (final t in eligible) UgamSelectorItem(label: t.title),
                  ],
                  currentIndex: eligible.indexWhere((t) => t.id == tour.id),
                  onChanged: (i) => _pickTour(eligible[i].id),
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
                  total: totalSeats,
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
                        assignments: assignments,
                        sheetOccupants: sheetOccupants,
                        groupColors: groupColors,
                        onSeatTap: (seatId, occupants) =>
                            _showOccupantSheet(context, seatId, occupants, bus),
                      ),
                      if (layout != null && layout.totalCells > 0)
                        ChartExpandButton(
                          onTap: () => FullscreenChartScreen.open(
                            context,
                            layout: layout,
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
                      // ate vertical chart space. The legend stays below.
                      if (layout != null && layout.totalCells > 0)
                        Positioned(
                          right: UgamSpacing.sm,
                          bottom: UgamSpacing.sm,
                          child: _EditSeatsFab(
                            c: c,
                            onTap: () => _editSeats(tour.id, bus.id),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: UgamSpacing.sm),
              UgamSeatChartLegend(c: c),
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

// ─── Header ────────────────────────────────────────────────────────────

class _Header extends StatelessWidget {
  final UgamColorSet c;
  const _Header({required this.c});

  @override
  Widget build(BuildContext context) {
    // Shared chrome — this is a top-level tab, so no back affordance.
    return UgamAppBar(title: tr('charts.title'), showBack: false);
  }
}

// ─── Bus bar ───────────────────────────────────────────────────────────

/// One compact row that merges what used to be a separate bus-selector strip
/// AND a full `n/total` tally card. The bus selector sits on the left (pills
/// when the tour carries >1 bus, else the single bus's name so it never
/// disappears), the placed/total fill on the right. Folding the standalone
/// tally card away reclaims a whole vertical band for the seat grid without
/// losing the fill signal or the bus name.
class _BusBar extends StatelessWidget {
  final Tour tour;
  final Bus bus;
  final int assigned;
  final int total;
  final ValueChanged<String> onPickBus;
  final UgamColorSet c;

  const _BusBar({
    required this.tour,
    required this.bus,
    required this.assigned,
    required this.total,
    required this.onPickBus,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    final multiBus = tour.buses.length > 1;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: multiBus
              ? UgamSelectorPills(
                  padding: EdgeInsets.zero,
                  items: [
                    for (final b in tour.buses) UgamSelectorItem(label: b.name),
                  ],
                  currentIndex: tour.buses.indexWhere((b) => b.id == bus.id),
                  onChanged: (i) => onPickBus(tour.buses[i].id),
                )
              : Text(
                  bus.name.toUpperCase(),
                  style: UgamText.micro.copyWith(color: c.ink2),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
        ),
        const SizedBox(width: UgamSpacing.md),
        _FillIndicator(assigned: assigned, total: total, c: c),
      ],
    );
  }
}

/// The compact placed/total signal on the right of the [_BusBar]: a tabular
/// `n/total` count and a short NEUTRAL-ink fill bar. Ink, not champagne — the
/// accent stays rationed to the one Edit-seats CTA.
class _FillIndicator extends StatelessWidget {
  final int assigned;
  final int total;
  final UgamColorSet c;

  const _FillIndicator({
    required this.assigned,
    required this.total,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    final ratio = total == 0 ? 0.0 : assigned / total;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '$assigned/$total',
          style: UgamText.tabular(
            UgamText.numLg.copyWith(color: c.ink, fontSize: 16),
          ),
        ),
        const SizedBox(width: UgamSpacing.sm),
        SizedBox(
          width: 52,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(UgamRadius.chip),
            child: LinearProgressIndicator(
              value: ratio.clamp(0.0, 1.0),
              minHeight: 6,
              backgroundColor: c.card,
              valueColor: AlwaysStoppedAnimation(c.ink2),
            ),
          ),
        ),
      ],
    );
  }
}

// ─── Edit-seats FAB ────────────────────────────────────────────────────

/// The chart's one primary hand-off into the editable grid, as a small copper
/// FAB overlaying the chart's bottom-right (thumb zone) instead of a full-width
/// footer button. It carries the screen's single rationed solid-copper fill —
/// THE LAW's one focal element — with the edit glyph plus a compact label, a
/// soft copper glow, and a 48dp-min tap target with ripple + haptic.
class _EditSeatsFab extends StatelessWidget {
  final UgamColorSet c;
  final VoidCallback onTap;

  const _EditSeatsFab({required this.c, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: tr('charts.edit_seats'),
      child: Material(
        color: c.accent,
        elevation: 0,
        borderRadius: BorderRadius.circular(UgamRadius.button),
        shadowColor: Colors.transparent,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(UgamRadius.button),
            boxShadow: [
              BoxShadow(
                color: c.glow,
                blurRadius: 18,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(UgamRadius.button),
            onTap: () {
              HapticFeedback.selectionClick();
              onTap();
            },
            child: Container(
              constraints: const BoxConstraints(minHeight: 48),
              padding: const EdgeInsets.symmetric(
                horizontal: UgamSpacing.lg,
                vertical: UgamSpacing.sm + 2,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.edit_rounded, size: 18, color: c.onAccent),
                  const SizedBox(width: UgamSpacing.sm),
                  Text(
                    tr('charts.edit_seats'),
                    style: UgamText.bodyStrong.copyWith(color: c.onAccent),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Seat chart card ───────────────────────────────────────────────────

/// The rounded card holding the canonical read-only chart for the bus. Renders
/// the same [SeatChartTile] + [CombinedSeatGrid] every other chart uses (drag
/// OFF), so the browser reads identically — group / priority rings, one-way leg
/// colours — minus any editing.
class _SeatChartCard extends StatelessWidget {
  final BusLayout? layout;

  /// Raw, berth-accurate occupant lists for TILE rendering: a whole double held
  /// solo appears twice so the half-double split detection stays exact.
  final Map<String, List<Passenger>> assignments;

  /// De-duped, GO-first distinct occupants per seat (the shared resolver's
  /// `occ.all`) for the SHEET. Keyed by seatId; a shared/leg-shared double has
  /// both people here, a whole-double-solo collapses to one.
  final Map<String, List<Passenger>> sheetOccupants;
  final GroupColorResolver groupColors;

  /// Hands the tapped seat's id plus its FULL distinct-occupant list (de-duped,
  /// GO-first) to the read-only sheet — a shared/leg-shared double surfaces BOTH
  /// names, not just the first. This list is the bug-fix surface.
  final void Function(String seatId, List<Passenger> occupants) onSeatTap;

  const _SeatChartCard({
    required this.layout,
    required this.assignments,
    required this.sheetOccupants,
    required this.groupColors,
    required this.onSeatTap,
  });

  @override
  Widget build(BuildContext context) {
    final l = layout;
    if (l == null || l.totalCells == 0) {
      return UgamCard.plain(
        child: UgamEmpty(
          icon: Icons.event_seat_outlined,
          title: tr('charts.no_layout'),
        ),
      );
    }

    return UgamCard.plain(
      padding: const EdgeInsets.symmetric(
        horizontal: UgamSpacing.md,
        vertical: UgamSpacing.lg,
      ),
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(
          parent: BouncingScrollPhysics(),
        ),
        child: UgamBusChassis(
          child: CombinedSeatGrid(
            layout: l,
            cellWidth: kSeatTileW,
            cellHeight: kSeatTileH,
            colGap: 6,
            rowGap: 6,
            driverLabel: tr('charts.driver_label'),
            // Header band so the top-left expand button clears the first seat.
            reserveTopAction: true,
            tileBuilder: (ctx, cell) {
              final occupants = cell.seatId != null
                  ? (assignments[cell.seatId] ?? const <Passenger>[])
                  : const <Passenger>[];
              return RepaintBoundary(
                child: SeatChartTile(
                  cell: cell,
                  occupants: occupants,
                  groupColors: groupColors,
                  markHalfDouble: true,
                  // Pass ALL occupants (not `.first`) to the read-only sheet so
                  // a shared / leg-shared double surfaces BOTH names. The
                  // distinct, GO-first set comes from the shared resolver
                  // (sheetOccupants), matching what the tile paints.
                  onTapBooked: occupants.isEmpty
                      ? null
                      : () => onSeatTap(
                          cell.seatId!,
                          sheetOccupants[cell.seatId] ?? occupants,
                        ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

