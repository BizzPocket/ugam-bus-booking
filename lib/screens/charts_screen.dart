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
import '../utils/passenger_display.dart';
import '../utils/phone_dialer.dart';
import '../utils/tour_group_colors.dart';
import '../widgets/chart_expand_button.dart';
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
    final list = tourCtrl.activeTours
        .where((t) => t.buses.isNotEmpty)
        .toList()
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
    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        bottom: false,
        child: Obx(() {
          final eligible = _eligibleTours();
          if (eligible.isEmpty) {
            return Column(
              children: [
                _Header(c: c),
                Expanded(
                  child: UgamEmpty(
                    icon: Icons.event_seat_outlined,
                    title: tr('charts.empty.title'),
                    body: tr('charts.empty.body'),
                  ),
                ),
              ],
            );
          }

          final tour = _resolveTour(eligible)!;
          final bus = _resolveBus(tour)!;
          final layout = bus.layout;
          final assignments = _assignmentsFor(tour, bus);
          final groupColors = tourGroupColors(tour);
          final totalSeats = layout?.totalSeats ?? 0;
          final assignedCount = assignments.values
              .fold<int>(0, (sum, list) => sum + list.length);

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
              if (tour.buses.length > 1) ...[
                UgamSelectorPills(
                  items: [
                    for (final b in tour.buses)
                      UgamSelectorItem(label: b.name),
                  ],
                  currentIndex:
                      tour.buses.indexWhere((b) => b.id == bus.id),
                  onChanged: (i) => _pickBus(tour.buses[i].id),
                ),
                const SizedBox(height: UgamSpacing.sm),
              ],
              Padding(
                padding: EdgeInsets.fromLTRB(
                  UgamSpacing.gutter,
                  tour.buses.length > 1 ? 0 : UgamSpacing.sm,
                  UgamSpacing.gutter,
                  UgamSpacing.sm,
                ),
                child: _Tally(
                  bus: bus,
                  assigned: assignedCount,
                  total: totalSeats,
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
                        groupColors: groupColors,
                        onSeatTap: (p) =>
                            _showOccupantSheet(context, p, bus, c),
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
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: UgamSpacing.sm),
              const _Legend(),
              const SizedBox(height: UgamSpacing.sm + 2),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: UgamSpacing.gutter,
                ),
                child: UgamButton(
                  label: tr('charts.edit_seats'),
                  icon: Icons.grid_view_rounded,
                  kind: UgamButtonKind.ghost,
                  onPressed: () => _editSeats(tour.id, bus.id),
                ),
              ),
              SizedBox(
                height: MediaQuery.of(context).padding.bottom + UgamSpacing.md,
              ),
            ],
          );
        }),
      ),
    );
  }

  /// Minimal READ-ONLY occupant sheet: name, phone (tap-to-call), the seats
  /// this passenger holds on this bus. No editing — re-seating lives in the
  /// unified grid behind "Edit seats".
  void _showOccupantSheet(
    BuildContext context,
    Passenger passenger,
    Bus bus,
    UgamColorSet c,
  ) {
    final seatsOnBus = passenger.assignedSeats
        .where((a) => a.busId == bus.id)
        .map((a) => a.seatId)
        .toSet()
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
                    if (passenger.phone.trim().isNotEmpty) ...[
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
              if (passenger.phone.trim().isNotEmpty) ...[
                const SizedBox(width: UgamSpacing.sm),
                UgamIconButton(
                  icon: Icons.phone_rounded,
                  onTap: () => PhoneDialer.call(passenger.phone),
                  size: 40,
                  iconSize: 18,
                  semanticLabel: tr('charts.call_passenger'),
                ),
              ],
            ],
          ),
          const SizedBox(height: UgamSpacing.md),
          _SheetRow(label: tr('charts.sheet_bus'), value: bus.name, c: c),
          _SheetRow(label: tr('charts.sheet_seats'), value: seatsOnBus, c: c),
        ],
      ),
    );
  }
}

// ─── Header ────────────────────────────────────────────────────────────

class _Header extends StatelessWidget {
  final UgamColorSet c;
  const _Header({required this.c});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        UgamSpacing.gutter,
        UgamSpacing.lg,
        UgamSpacing.gutter,
        UgamSpacing.md,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              tr('charts.title'),
              style: UgamText.titleXl.copyWith(color: c.ink),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Tally ─────────────────────────────────────────────────────────────

/// Per-bus placed/total tally: a big tabular count, the bus name, and a thin
/// fill bar — the at-a-glance fill state for the bus on screen.
class _Tally extends StatelessWidget {
  final Bus bus;
  final int assigned;
  final int total;
  final UgamColorSet c;

  const _Tally({
    required this.bus,
    required this.assigned,
    required this.total,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    final ratio = total == 0 ? 0.0 : assigned / total;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: UgamSpacing.md,
        vertical: UgamSpacing.sm + 2,
      ),
      decoration: BoxDecoration(
        color: c.cardElev,
        borderRadius: BorderRadius.circular(UgamRadius.row),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '$assigned/$total',
                style: UgamText.numLg.copyWith(color: c.ink),
              ),
              Text(
                bus.name.toUpperCase(),
                style: UgamText.micro.copyWith(color: c.ink2),
              ),
            ],
          ),
          const SizedBox(width: UgamSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  '${(ratio * 100).round()}%',
                  style: UgamText.tabular(
                    UgamText.caption.copyWith(
                      color: c.ink2,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: ratio.clamp(0.0, 1.0),
                    minHeight: 6,
                    backgroundColor: c.card,
                    valueColor: AlwaysStoppedAnimation(c.accent),
                  ),
                ),
              ],
            ),
          ),
        ],
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
  final Map<String, List<Passenger>> assignments;
  final GroupColorResolver groupColors;
  final ValueChanged<Passenger> onSeatTap;

  const _SeatChartCard({
    required this.layout,
    required this.assignments,
    required this.groupColors,
    required this.onSeatTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final l = layout;
    if (l == null || l.totalCells == 0) {
      return UgamCard.plain(
        child: Center(
          child: Text(
            tr('charts.no_layout'),
            textAlign: TextAlign.center,
            style: UgamText.body.copyWith(color: c.ink2),
          ),
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
        child: CombinedSeatGrid(
          layout: l,
          cellWidth: kSeatTileW,
          cellHeight: kSeatTileH,
          colGap: 6,
          rowGap: 6,
          driverLabel: tr('charts.driver_label'),
          tileBuilder: (ctx, cell) {
            final occupants = cell.seatId != null
                ? (assignments[cell.seatId] ?? const <Passenger>[])
                : const <Passenger>[];
            return RepaintBoundary(
              child: SeatChartTile(
                cell: cell,
                occupants: occupants,
                groupColors: groupColors,
                onTapBooked: occupants.isEmpty
                    ? null
                    : () => onSeatTap(occupants.first),
              ),
            );
          },
        ),
      ),
    );
  }
}

// ─── Legend ────────────────────────────────────────────────────────────

/// The SHARED seat-chart legend (Free / Booked / Priority-forward / One-way /
/// Held) — the same swatches bus_status uses, so the browser reads exactly like
/// the rest of the app's charts.
class _Legend extends StatelessWidget {
  const _Legend();

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: UgamSpacing.gutter),
      child: Wrap(
        spacing: UgamSpacing.md,
        runSpacing: 6,
        alignment: WrapAlignment.center,
        children: [
          _LegendItem(
            swatch: _LegendSwatch.dashed,
            label: tr('seat_detail.legend.free'),
            c: c,
          ),
          _LegendItem(
            swatch: _LegendSwatch.filled,
            label: tr('app.label.booked'),
            c: c,
          ),
          _LegendItem(
            swatch: _LegendSwatch.warmRing,
            label: tr('seat_detail.legend.priority_forward'),
            c: c,
          ),
          _LegendItem(
            swatch: _LegendSwatch.oneWay,
            label: tr('seat_detail.legend.one_way'),
            c: c,
          ),
          _LegendItem(
            swatch: _LegendSwatch.held,
            label: tr('seat_detail.legend.held'),
            c: c,
          ),
        ],
      ),
    );
  }
}

enum _LegendSwatch { dashed, filled, warmRing, oneWay, held }

class _LegendItem extends StatelessWidget {
  final _LegendSwatch swatch;
  final String label;
  final UgamColorSet c;

  const _LegendItem({
    required this.swatch,
    required this.label,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    Widget dot;
    switch (swatch) {
      case _LegendSwatch.dashed:
        dot = CustomPaint(
          painter: SeatDashedBorderPainter(
            color: c.ink3.withValues(alpha: 0.7),
            radius: 3,
          ),
          child: const SizedBox(width: 12, height: 12),
        );
      case _LegendSwatch.filled:
        dot = Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            color: c.cardElev,
            borderRadius: BorderRadius.circular(3),
            border: Border.all(color: c.border),
          ),
        );
      case _LegendSwatch.warmRing:
        dot = Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            color: c.cardElev,
            borderRadius: BorderRadius.circular(3),
            border: Border.all(color: c.warm, width: 2),
          ),
        );
      case _LegendSwatch.oneWay:
        dot = Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            color: kOneWayTint.withValues(alpha: 0.18),
            borderRadius: BorderRadius.circular(3),
            border: Border.all(color: kOneWayTint, width: 1.5),
          ),
        );
      case _LegendSwatch.held:
        dot = Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            color: c.cardElev.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(3),
            border: Border.all(color: c.border),
          ),
          alignment: Alignment.center,
          child: Icon(Icons.lock_outline_rounded, size: 8, color: c.ink3),
        );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        dot,
        const SizedBox(width: 6),
        Text(label, style: UgamText.micro.copyWith(color: c.ink2)),
      ],
    );
  }
}

// ─── Occupant sheet row ────────────────────────────────────────────────

class _SheetRow extends StatelessWidget {
  final String label;
  final String value;
  final UgamColorSet c;

  const _SheetRow({required this.label, required this.value, required this.c});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 130,
            child: Text(label, style: UgamText.caption.copyWith(color: c.ink2)),
          ),
          Expanded(
            child: Text(
              value.isEmpty ? '—' : value,
              style: UgamText.bodyStrong.copyWith(color: c.ink),
            ),
          ),
        ],
      ),
    );
  }
}
