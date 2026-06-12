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
import '../models/seat_layout.dart';
import '../services/whatsapp_service.dart';
import '../utils/app_snackbar.dart';
import '../utils/passenger_display.dart';
import '../utils/phone_dialer.dart';
import '../utils/tour_group_colors.dart';
import '../widgets/chart_expand_button.dart';
import 'add_bus_screen.dart';
import 'bus_money_screen.dart';
import 'fullscreen_chart_screen.dart';
import 'seats_screen.dart';

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
  Widget build(BuildContext context) {
    final tourCtrl = Get.find<TourController>();
    final c = UgamColors.of(context);
    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        child: Obx(() {
          final tour = tourCtrl.getTour(widget.tourId);
          final bus = tour?.buses.firstWhereOrNull((b) => b.id == widget.busId);
          if (tour == null || bus == null) {
            return Center(
              child: Text(
                tr('bus_status.bus_not_found'),
                style: UgamText.body.copyWith(color: c.ink2),
              ),
            );
          }
          final layout = bus.layout;
          if (layout == null) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(40),
                child: Text(
                  tr('bus_status.no_layout'),
                  textAlign: TextAlign.center,
                  style: UgamText.body.copyWith(color: c.ink2),
                ),
              ),
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

          final totalSeats = layout.totalSeats;
          final assignedCount = assignments.values.fold<int>(
            0,
            (sum, list) => sum + list.length,
          );

          return Column(
            children: [
              _Header(bus: bus, tourTitle: tour.title),
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
                        onSeatTap: (passenger) => _showPassengerSheet(
                          context,
                          passenger,
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
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: UgamSpacing.sm),
              const _Legend(),
              const SizedBox(height: UgamSpacing.sm + 2),
              _BottomActions(tourId: tour.id, bus: bus),
              const SizedBox(height: UgamSpacing.md),
            ],
          );
        }),
      ),
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

class _Header extends StatelessWidget {
  final Bus bus;
  final String tourTitle;

  const _Header({required this.bus, required this.tourTitle});

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        UgamSpacing.md,
        UgamSpacing.sm,
        UgamSpacing.md,
        UgamSpacing.md,
      ),
      child: Row(
        children: [
          UgamIconButton(
            icon: Icons.arrow_back_rounded,
            size: 42,
            onTap: () => Get.back(),
          ),
          const SizedBox(width: UgamSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(bus.name, style: UgamText.titleL.copyWith(color: c.ink)),
                Text(
                  '$tourTitle'
                  '${bus.busNumber.isNotEmpty ? ' · ${bus.busNumber}' : ''}',
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

/// Compact tally row: big tabular count (assigned / total), label
/// underneath, and a thin Ugam-tinted progress bar.
class _Tally extends StatelessWidget {
  final int assigned;
  final int total;

  const _Tally({required this.assigned, required this.total});

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
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
                tr('bus_status.legend_booked').toUpperCase(),
                style: UgamText.caption.copyWith(
                  color: c.ink2,
                  fontSize: 10.5,
                  letterSpacing: 0.6,
                  fontWeight: FontWeight.w600,
                ),
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
                    UgamText.bodyStrong.copyWith(color: c.ink2, fontSize: 12),
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

/// The rounded card containing the bus chart. Renders the CANONICAL
/// [SeatChartTile] (read-only) so the status chart reads identically to the
/// auto-fill / assign / handler charts — same tile look, same group/priority
/// rings, same one-way leg colours — just without the drag/drop wiring.
class _SeatChartCard extends StatelessWidget {
  final BusLayout layout;
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
    if (layout.totalCells == 0) {
      return UgamCard.plain(
        child: Center(
          child: Text(
            tr('bus_status.no_layout'),
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
          layout: layout,
          cellWidth: kSeatTileW,
          cellHeight: kSeatTileH,
          colGap: 6,
          rowGap: 6,
          driverLabel: tr('bus_status.driver_label'),
          tileBuilder: (ctx, cell) {
            final occupants = cell.seatId != null
                ? (assignments[cell.seatId] ?? const <Passenger>[])
                : const <Passenger>[];
            return RepaintBoundary(
              child: SeatChartTile(
                cell: cell,
                occupants: occupants,
                groupColors: groupColors,
                // Read-only: a booked seat surfaces the passenger sheet; a free
                // seat is inert here (re-seating lives in the unified grid).
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

/// Bottom-of-screen legend — the SHARED seat-chart legend (Free / Booked /
/// Priority-forward / One-way / Held) so the status screen reads exactly like
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

class _SheetRow extends StatelessWidget {
  final String label;
  final String value;

  const _SheetRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
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
              style: UgamText.bodyStrong.copyWith(color: c.ink, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}

/// Hero card at the top of the bus status screen. Bus backdrop + bus
/// number + driver name/phone with quick-call and WhatsApp circle
/// buttons on the right.
class _DriverHeroCard extends StatelessWidget {
  final Bus bus;

  const _DriverHeroCard({required this.bus});

  Future<void> _openWhatsApp(String phone) async {
    final cleaned = phone.replaceAll(RegExp(r'[^\d+]'), '');
    if (cleaned.isEmpty) return;
    try {
      final ok = await WhatsAppService().openChat(phone: phone, message: '');
      if (!ok) {
        AppSnackBar.error(
          tr('bus_status.wa_open_failed', namedArgs: {'phone': phone}),
          title: tr('bus_status.wa_failed_title'),
        );
      }
    } catch (e) {
      AppSnackBar.error(
        tr('bus_status.wa_open_error', namedArgs: {'error': '$e'}),
        title: tr('bus_status.wa_failed_title'),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final phone = bus.driverPhone;
    final hasPhone = phone.trim().isNotEmpty;
    return Container(
      padding: const EdgeInsets.all(UgamSpacing.sm),
      decoration: BoxDecoration(
        color: c.cardElev,
        borderRadius: BorderRadius.circular(UgamRadius.card),
      ),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(UgamRadius.photo),
            child: SizedBox(
              width: 84,
              height: 84,
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
                  style: UgamText.titleM.copyWith(color: c.ink),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  bus.driverName.isEmpty
                      ? tr('bus_status.driver_pending')
                      : bus.driverName,
                  style: UgamText.bodyStrong.copyWith(
                    color: c.ink2,
                    fontSize: 13,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (hasPhone)
                  Text(
                    phone,
                    style: UgamText.tabular(
                      UgamText.caption.copyWith(color: c.ink3, fontSize: 12),
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
          const SizedBox(width: UgamSpacing.sm),
          _CircleAction(
            icon: Icons.phone_rounded,
            tint: c.accent,
            fill: c.accentFill,
            enabled: hasPhone,
            onTap: () => PhoneDialer.call(phone),
          ),
          const SizedBox(width: 6),
          _CircleAction(
            icon: Icons.chat_rounded,
            tint: c.good,
            fill: c.goodFill,
            enabled: hasPhone,
            onTap: () => _openWhatsApp(phone),
          ),
        ],
      ),
    );
  }
}

class _CircleAction extends StatelessWidget {
  final IconData icon;
  final Color tint;
  final Color fill;
  final bool enabled;
  final VoidCallback onTap;

  const _CircleAction({
    required this.icon,
    required this.tint,
    required this.fill,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return GestureDetector(
      onTap: enabled ? onTap : null,
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: 42,
        height: 42,
        decoration: BoxDecoration(
          color: enabled ? fill : c.card,
          shape: BoxShape.circle,
        ),
        alignment: Alignment.center,
        child: Icon(icon, size: 18, color: enabled ? tint : c.ink3),
      ),
    );
  }
}

/// Below-the-grid row with two outlined pill links: "Edit bus details"
/// and "Open seat assignment". Surfaces the next contextual actions an
/// agent typically wants after eyeballing the chart.
class _BottomActions extends StatelessWidget {
  final String tourId;
  final Bus bus;

  const _BottomActions({required this.tourId, required this.bus});

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: UgamSpacing.gutter),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: _OutlinedPill(
                  c: c,
                  icon: Icons.edit_rounded,
                  label: tr('bus_status.action.edit_bus'),
                  onTap: () => Get.to(
                    () => AddBusScreen(tourId: tourId, existing: bus),
                    transition: Transition.cupertino,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _OutlinedPill(
                  c: c,
                  icon: Icons.grid_view_rounded,
                  label: tr('bus_status.action.open_seat_assignment'),
                  onTap: () => Get.to(
                    () => SeatsScreen(
                      tourId: tourId,
                      initialMode: SeatsMode.grid,
                      initialBusId: bus.id,
                    ),
                    transition: Transition.cupertino,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _OutlinedPill(
            c: c,
            icon: Icons.payments_rounded,
            label: tr('bus_status.action.collection_money'),
            onTap: () {
              final tour = Get.find<TourController>().getTour(tourId);
              if (tour == null) {
                AppSnackBar.error(tr('bus_status.tour_not_found_refresh'));
                return;
              }
              Get.to(
                () => BusMoneyScreen(tour: tour, bus: bus),
                transition: Transition.cupertino,
              );
            },
          ),
        ],
      ),
    );
  }
}

class _OutlinedPill extends StatelessWidget {
  final UgamColorSet c;
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _OutlinedPill({
    required this.c,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: UgamSpacing.md,
          vertical: UgamSpacing.md,
        ),
        decoration: BoxDecoration(
          color: c.card,
          borderRadius: BorderRadius.circular(UgamRadius.chip),
          border: Border.all(color: c.border),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 15, color: c.ink),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                label,
                style: UgamText.bodyStrong.copyWith(
                  color: c.ink,
                  fontSize: 12.5,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HandlerBadge extends StatelessWidget {
  const _HandlerBadge();

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: c.warmFill,
        borderRadius: BorderRadius.circular(9999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.workspace_premium_rounded, size: 14, color: c.warm),
          const SizedBox(width: 6),
          Text(
            tr('bus_status.handler_badge'),
            style: UgamText.micro.copyWith(
              color: c.warm,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}
