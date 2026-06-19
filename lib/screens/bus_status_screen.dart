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
import '../widgets/occupant_action_sheet.dart';
import 'add_bus_screen.dart';
import 'bus_money_screen.dart';
import 'collection_screen.dart';
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
            return Column(
              children: [
                UgamAppBar(title: tr('bus_status.bus_not_found')),
                Expanded(
                  child: UgamEmpty(
                    icon: Icons.directions_bus_filled_outlined,
                    title: tr('bus_status.bus_not_found'),
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

          final totalSeats = layout.totalSeats;
          final assignedCount = assignments.values.fold<int>(
            0,
            (sum, list) => sum + list.length,
          );

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
              UgamSeatChartLegend(c: c),
              const SizedBox(height: UgamSpacing.sm + 2),
              _BottomActions(tourId: tour.id, bus: bus),
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
            onPressed: () {
              Navigator.of(sheetCtx).pop();
              final tour = Get.find<TourController>().getTour(tourId);
              if (tour == null) {
                AppSnackBar.error(tr('bus_status.tour_not_found_refresh'));
                return;
              }
              Get.to(
                () => CollectionScreen(tour: tour, bus: bus),
                transition: Transition.cupertino,
              );
            },
          ),
          const SizedBox(height: UgamSpacing.sm),
          UgamButton(
            kind: UgamButtonKind.neutral,
            expand: true,
            icon: Icons.payments_rounded,
            label: tr('bus_status.action.collection_money'),
            onPressed: () {
              Navigator.of(sheetCtx).pop();
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

  /// Bottom sheet that shows passenger details when a booked seat is
  /// tapped. Business logic preserved verbatim — same seat-list build,
  /// same handler-badge surfacing, same phone-call CTA.
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

class _StatusAppBar extends StatelessWidget {
  final Bus bus;
  final String tourTitle;

  /// Opens the money actions sheet (Collect / Bus money). Null hides the action
  /// (e.g. the not-found / no-layout app bars that reuse this widget elsewhere).
  final VoidCallback? onMoney;

  const _StatusAppBar({
    required this.bus,
    required this.tourTitle,
    this.onMoney,
  });

  @override
  Widget build(BuildContext context) {
    return UgamAppBar(
      title: bus.name,
      subtitle:
          '$tourTitle'
          '${bus.busNumber.isNotEmpty ? ' · ${bus.busNumber}' : ''}',
      actions: [
        if (onMoney != null)
          UgamAppBarAction(
            icon: Icons.payments_rounded,
            onTap: onMoney!,
            tooltip: tr('bus_status.action.collection_money'),
          ),
      ],
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

  /// The tapped seat's id + its occupants (berth-accurate, so a whole double
  /// held solo arrives as the rider twice) — the handler de-dupes and shows one
  /// or all.
  final void Function(String seatId, List<Passenger> occupants) onSeatTap;

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
                // Read-only: a booked seat surfaces the passenger sheet; a free
                // seat is inert here (re-seating lives in the unified grid).
                onTapBooked: occupants.isEmpty
                    ? null
                    : () => onSeatTap(cell.seatId!, occupants),
              ),
            );
          },
        ),
      ),
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
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Flexible(
            flex: 2,
            child: Text(label, style: UgamText.caption.copyWith(color: c.ink2)),
          ),
          const SizedBox(width: UgamSpacing.md),
          Expanded(
            flex: 3,
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
    return UgamCard.media(
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
                  bus.displayLabel,
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
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: UgamSpacing.gutter),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: UgamButton(
                  kind: UgamButtonKind.neutral,
                  expand: true,
                  icon: Icons.edit_rounded,
                  label: tr('bus_status.action.edit_bus'),
                  onPressed: () => Get.to(
                    () => AddBusScreen(tourId: tourId, existing: bus),
                    transition: Transition.cupertino,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: UgamButton(
                  kind: UgamButtonKind.neutral,
                  expand: true,
                  icon: Icons.grid_view_rounded,
                  label: tr('bus_status.action.open_seat_assignment'),
                  onPressed: () => Get.to(
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
          // Money/collection actions reachable in ONE push each (no longer
          // chained Bus money → Collect): "Collect" jumps straight into the
          // per-bus CollectionScreen — the SAME canonical destination the
          // Tour money board's "Collect" shortcut uses — and "Bus money"
          // opens the per-bus ledger directly. Both are demoted to neutral
          // (not solid champagne) per the accent-rationing law.
          Row(
            children: [
              Expanded(
                child: UgamButton(
                  kind: UgamButtonKind.neutral,
                  expand: true,
                  icon: Icons.groups_rounded,
                  label: tr('tour_money_board.collect'),
                  onPressed: () {
                    final tour = Get.find<TourController>().getTour(tourId);
                    if (tour == null) {
                      AppSnackBar.error(
                        tr('bus_status.tour_not_found_refresh'),
                      );
                      return;
                    }
                    Get.to(
                      () => CollectionScreen(tour: tour, bus: bus),
                      transition: Transition.cupertino,
                    );
                  },
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: UgamButton(
                  kind: UgamButtonKind.neutral,
                  expand: true,
                  icon: Icons.payments_rounded,
                  label: tr('bus_status.action.collection_money'),
                  onPressed: () {
                    final tour = Get.find<TourController>().getTour(tourId);
                    if (tour == null) {
                      AppSnackBar.error(
                        tr('bus_status.tour_not_found_refresh'),
                      );
                      return;
                    }
                    Get.to(
                      () => BusMoneyScreen(tour: tour, bus: bus),
                      transition: Transition.cupertino,
                    );
                  },
                ),
              ),
            ],
          ),
        ],
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
