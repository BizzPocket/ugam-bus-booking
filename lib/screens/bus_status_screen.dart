import 'dart:math' as math;

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:url_launcher/url_launcher.dart';

import '../controllers/tour_controller.dart';
import '../design/ugam.dart';
import '../models/bus_details.dart';
import '../models/passenger.dart';
import '../models/seat_layout.dart';
import '../models/seat_type.dart';
import '../utils/app_snackbar.dart';
import '../utils/passenger_display.dart';
import '../utils/phone_dialer.dart';
import 'add_bus_screen.dart';
import 'tour_seat_assignment_screen.dart';

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

  const BusStatusScreen({
    super.key,
    required this.tourId,
    required this.busId,
  });

  @override
  State<BusStatusScreen> createState() => _BusStatusScreenState();
}

class _BusStatusScreenState extends State<BusStatusScreen> {
  // Deck toggle state (only meaningful when the bus actually has an
  // upper deck). Mirrors seat_assignment_screen's `_showUpper` flag.
  bool _showUpper = false;

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
          final assignedCount = assignments.values
              .fold<int>(0, (sum, list) => sum + list.length);

          final hasUpper = layout.upperDeck.any((cell) => cell.hasSeat);

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
                child: _Tally(
                  assigned: assignedCount,
                  total: totalSeats,
                ),
              ),
              if (hasUpper)
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    UgamSpacing.gutter,
                    0,
                    UgamSpacing.gutter,
                    UgamSpacing.sm,
                  ),
                  child: UgamTabPills(
                    currentIndex: _showUpper ? 1 : 0,
                    onChanged: (i) => setState(() => _showUpper = i == 1),
                    items: [
                      UgamTabItem(
                        label: tr('bus_status.deck_lower'),
                        icon: Icons.event_seat_rounded,
                      ),
                      UgamTabItem(
                        label: tr('bus_status.deck_upper'),
                        icon: Icons.single_bed_rounded,
                      ),
                    ],
                  ),
                ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: UgamSpacing.gutter,
                  ),
                  child: _SeatChartCard(
                    layout: layout,
                    showUpper: hasUpper && _showUpper,
                    assignments: assignments,
                    onSeatTap: (passenger) =>
                        _showPassengerSheet(context, passenger, bus, tour.id),
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
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: c.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(UgamRadius.sheet),
        ),
      ),
      builder: (_) => Padding(
        padding: const EdgeInsets.fromLTRB(
          UgamSpacing.gutter,
          UgamSpacing.sm + 4,
          UgamSpacing.gutter,
          UgamSpacing.lg,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: UgamSpacing.md),
                decoration: BoxDecoration(
                  color: c.border,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
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
                      child: Icon(
                        Icons.phone_rounded,
                        size: 18,
                        color: c.accent,
                      ),
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
          GestureDetector(
            onTap: () => Get.back(),
            behavior: HitTestBehavior.opaque,
            child: Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: c.cardElev,
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: Icon(Icons.arrow_back_rounded, size: 19, color: c.ink),
            ),
          ),
          const SizedBox(width: UgamSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(bus.name,
                    style: UgamText.titleL.copyWith(color: c.ink)),
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

/// The rounded card containing the bus chart. Mirrors
/// `_SeatChartCard` from seat_assignment_screen — same `UgamCard.plain`
/// wrapper, same `LayoutBuilder` width math, same `_frontLabel` row at
/// the top and `REAR` label at the bottom — but renders read-only
/// tiles via `_SeatTile`.
class _SeatChartCard extends StatelessWidget {
  final BusLayout layout;
  final bool showUpper;
  final Map<String, List<Passenger>> assignments;
  final ValueChanged<Passenger> onSeatTap;

  const _SeatChartCard({
    required this.layout,
    required this.showUpper,
    required this.assignments,
    required this.onSeatTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final deck = showUpper ? layout.upperDeck : layout.lowerDeck;
    final seatCells = deck.where((cell) => cell.hasSeat).toList();
    if (seatCells.isEmpty) {
      return UgamCard.plain(
        child: Center(
          child: Text(
            tr('bus_status.no_layout'),
            style: UgamText.body.copyWith(color: c.ink2),
          ),
        ),
      );
    }

    final maxRow =
        seatCells.map((cell) => cell.row).reduce((a, b) => a > b ? a : b);
    final cols = layout.cols;
    final leftCols = cols ~/ 2;

    return UgamCard.plain(
      padding: const EdgeInsets.symmetric(
        horizontal: UgamSpacing.md,
        vertical: UgamSpacing.lg,
      ),
      child: LayoutBuilder(
        builder: (ctx, constraints) {
          const cellGap = 4.0;
          const aisleGap = 12.0;
          final innerWidth = constraints.maxWidth;
          final leftGapCount = math.max(0, leftCols - 1);
          final rightGapCount = math.max(0, (cols - leftCols) - 1);
          final usableWidth = innerWidth -
              aisleGap -
              (leftGapCount + rightGapCount) * cellGap;
          const double minCellWidth = 56.0;
          final double calculatedCellWidth = usableWidth / cols;
          final bool useScroll = calculatedCellWidth < minCellWidth;
          final cellWidth = (useScroll ? minCellWidth : calculatedCellWidth).clamp(0.0, 120.0);
          final tileHeight = math.min(84.0, cellWidth * 1.05);

          final gridContent = Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _frontLabel(c),
              const SizedBox(height: UgamSpacing.sm),
              for (int r = 0; r <= maxRow; r++) ...[
                _SeatRow(
                  row: r,
                  cols: cols,
                  leftCols: leftCols,
                  deck: deck,
                  cellWidth: cellWidth,
                  cellHeight: tileHeight,
                  aisleGap: aisleGap,
                  cellGap: cellGap,
                  assignments: assignments,
                  onSeatTap: onSeatTap,
                ),
                if (r < maxRow) const SizedBox(height: 6),
              ],
              const SizedBox(height: UgamSpacing.sm),
              Container(height: 1, color: c.border),
              const SizedBox(height: UgamSpacing.xs),
              Text(
                'REAR',
                style: UgamText.micro.copyWith(color: c.ink3),
              ),
            ],
          );

          return SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(
              parent: BouncingScrollPhysics(),
            ),
            child: useScroll
                ? SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    physics: const BouncingScrollPhysics(),
                    child: gridContent,
                  )
                : gridContent,
          );
        },
      ),
    );
  }

  Widget _frontLabel(UgamColorSet c) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        Icon(Icons.directions_bus_filled_rounded, size: 14, color: c.ink3),
        const SizedBox(width: 4),
        Text(
          tr('bus_status.driver_label'),
          style: UgamText.micro.copyWith(color: c.ink3),
        ),
      ],
    );
  }
}

class _SeatRow extends StatelessWidget {
  final int row;
  final int cols;
  final int leftCols;
  final List<SeatCell> deck;
  final double cellWidth;
  final double cellHeight;
  final double aisleGap;
  final double cellGap;
  final Map<String, List<Passenger>> assignments;
  final ValueChanged<Passenger> onSeatTap;

  const _SeatRow({
    required this.row,
    required this.cols,
    required this.leftCols,
    required this.deck,
    required this.cellWidth,
    required this.cellHeight,
    required this.aisleGap,
    required this.cellGap,
    required this.assignments,
    required this.onSeatTap,
  });

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[];
    for (int col = 0; col < cols; col++) {
      // Insert the aisle right before the first right-of-aisle column.
      if (col == leftCols && col > 0) {
        children.add(SizedBox(width: aisleGap));
      } else if (col > 0) {
        children.add(SizedBox(width: cellGap));
      }
      final cell = deck.firstWhere(
        (s) => s.row == row && s.col == col,
        orElse: () => SeatCell(row: row, col: col),
      );
      if (cell.isEmpty || cell.seatId == null) {
        children.add(SizedBox(width: cellWidth, height: cellHeight));
      } else {
        final occupants = assignments[cell.seatId] ?? const <Passenger>[];
        // RepaintBoundary isolates each tile's paint surface — tapping
        // a tile to open the sheet won't invalidate the whole chart.
        children.add(
          RepaintBoundary(
            child: _SeatTile(
              width: cellWidth,
              height: cellHeight,
              cell: cell,
              passengers: occupants,
              onTap: onSeatTap,
            ),
          ),
        );
      }
    }
    return Row(mainAxisAlignment: MainAxisAlignment.center, children: children);
  }
}

/// Read-only tile. Mirrors `_SeatTile` from seat_assignment_screen —
/// same booked/free color rules — but skips DragTarget /
/// LongPressDraggable. Tapping a booked tile fires `onTap(passenger)`;
/// tapping a free tile is a no-op.
class _SeatTile extends StatelessWidget {
  final double width;
  final double height;
  final SeatCell cell;

  /// Occupants of this seat. `length == 0` → free, `length == 1` →
  /// owned, `length == 2` → shared doubleSofa. Shared shows the first
  /// passenger's name only on a single tile background (no split
  /// halves); the handler can long-tap to see both occupants by
  /// reopening the sheet for each one if needed.
  final List<Passenger> passengers;

  final ValueChanged<Passenger> onTap;

  const _SeatTile({
    required this.width,
    required this.height,
    required this.cell,
    required this.passengers,
    required this.onTap,
  });

  String get seatId => cell.seatId!;
  SeatType? get seatType => cell.seatType;

  bool get _isBooked => passengers.isNotEmpty;
  bool get _isDouble => seatType == SeatType.doubleSofa;
  bool get _isSleeper =>
      seatType == SeatType.singleSofa || seatType == SeatType.doubleSofa;

  IconData get _icon {
    switch (seatType) {
      case SeatType.singleSofa:
        return Icons.single_bed_rounded;
      case SeatType.doubleSofa:
        return Icons.king_bed_rounded;
      case SeatType.seater:
        return Icons.event_seat_rounded;
      case null:
        return Icons.crop_square_rounded;
    }
  }

  /// Drop +91 / 91 prefix + any non-digits, return the local 10-digit
  /// number. Falls back to whatever's there. Mirrors the same helper
  /// in seat_assignment_screen.
  String? _phoneDisplay(String? phone) {
    if (phone == null || phone.isEmpty) return null;
    final digits = phone.replaceAll(RegExp(r'\D'), '');
    if (digits.isEmpty) return null;
    if (digits.length > 10 && digits.startsWith('91')) {
      return digits.substring(digits.length - 10);
    }
    return digits;
  }

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);

    final Color bg;
    final Color fg;
    final Color border;
    final double borderWidth;

    if (_isBooked) {
      bg = c.accent;
      fg = c.onAccent;
      border = c.accent;
      borderWidth = 0;
    } else if (_isDouble) {
      bg = c.accentFill;
      fg = c.ink;
      border = c.accent.withValues(alpha: 0.45);
      borderWidth = 1.2;
    } else if (seatType == SeatType.singleSofa) {
      bg = c.goodFill;
      fg = c.ink;
      border = c.good.withValues(alpha: 0.55);
      borderWidth = 1.2;
    } else {
      bg = c.cardElev;
      fg = c.ink;
      border = c.border;
      borderWidth = 1.2;
    }

    final tile = Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(UgamRadius.seat + 2),
        border: Border.all(color: border, width: borderWidth),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      child: _isBooked ? _bookedBody(fg) : _freeBody(fg),
    );

    // Free tile → swallow taps silently. Booked tile → first passenger
    // opens the sheet. (Shared doubles only expose one passenger via
    // tap; the agent must open the other half from the seat
    // assignment screen to act on the second occupant.)
    return GestureDetector(
      onTap: _isBooked ? () => onTap(passengers.first) : null,
      behavior: HitTestBehavior.opaque,
      child: tile,
    );
  }

  Widget _bookedBody(Color fg) {
    final passenger = passengers.first;
    final phoneText = _phoneDisplay(passenger.phone);
    // FittedBox(scaleDown) keeps long names + 10-digit phones readable
    // on the smallest tile size the LayoutBuilder may produce.
    return Column(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              seatId,
              style: UgamText.micro.copyWith(
                color: fg.withValues(alpha: 0.75),
                fontSize: 8.5,
              ),
            ),
            Icon(_icon, size: 11, color: fg.withValues(alpha: 0.75)),
          ],
        ),
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            passenger.displayName,
            maxLines: 1,
            textAlign: TextAlign.center,
            style: UgamText.bodyStrong.copyWith(
              color: fg,
              fontSize: 11,
              height: 1.1,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        if (phoneText != null)
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              phoneText,
              maxLines: 1,
              style: UgamText.tabular(
                UgamText.caption.copyWith(
                  color: fg.withValues(alpha: 0.85),
                  fontSize: 9.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _freeBody(Color fg) {
    if (_isSleeper) {
      return Column(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          Icon(_icon, size: 18, color: fg.withValues(alpha: 0.8)),
          Text(
            seatId,
            style: UgamText.bodyStrong.copyWith(
              color: fg,
              fontSize: 12,
              height: 1,
            ),
          ),
        ],
      );
    }
    return Stack(
      children: [
        Positioned(
          top: 2,
          left: 4,
          child: Icon(_icon, size: 10, color: fg.withValues(alpha: 0.7)),
        ),
        Center(
          child: Text(
            seatId,
            style: UgamText.bodyStrong.copyWith(color: fg, fontSize: 11),
          ),
        ),
      ],
    );
  }
}

/// Bottom-of-screen legend — 4 dots mapping the chart's bg colors to
/// their meanings. Pulled straight from the Ugam token set so the
/// dots match `_SeatTile`'s bg exactly.
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
          _LegendDot(
            fill: c.accent,
            border: c.accent,
            label: tr('bus_status.legend_booked'),
          ),
          _LegendDot(
            fill: c.accentFill,
            border: c.accent.withValues(alpha: 0.45),
            label: tr('bus_status.legend_double'),
          ),
          _LegendDot(
            fill: c.goodFill,
            border: c.good.withValues(alpha: 0.55),
            label: tr('bus_status.legend_single'),
          ),
          _LegendDot(
            fill: c.cardElev,
            border: c.border,
            label: tr('bus_status.legend_seater'),
          ),
        ],
      ),
    );
  }
}

class _LegendDot extends StatelessWidget {
  final Color fill;
  final Color border;
  final String label;

  const _LegendDot({
    required this.fill,
    required this.border,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            color: fill,
            borderRadius: BorderRadius.circular(3),
            border: Border.all(color: border, width: 1.2),
          ),
        ),
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
            child: Text(
              label,
              style: UgamText.caption.copyWith(color: c.ink2),
            ),
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
    // Normalize to international form (default +91 for 10-digit local).
    var wa = cleaned.startsWith('+') ? cleaned.substring(1) : cleaned;
    if (!cleaned.startsWith('+') && wa.length == 10) wa = '91$wa';
    final uri = Uri.parse('https://wa.me/$wa');
    try {
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!ok) {
        AppSnackBar.error('Could not open WhatsApp for $phone.',
            title: 'WhatsApp failed');
      }
    } catch (e) {
      AppSnackBar.error('Could not open WhatsApp. $e',
          title: 'WhatsApp failed');
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
                  bus.driverName.isEmpty ? 'Driver pending' : bus.driverName,
                  style: UgamText.bodyStrong
                      .copyWith(color: c.ink2, fontSize: 13),
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
        child: Icon(
          icon,
          size: 18,
          color: enabled ? tint : c.ink3,
        ),
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
      child: Row(
        children: [
          Expanded(
            child: _OutlinedPill(
              c: c,
              icon: Icons.edit_rounded,
              label: 'Edit bus details',
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
              label: 'Open seat assignment',
              onTap: () => Get.to(
                () => TourSeatAssignmentScreen(tourId: tourId),
                transition: Transition.cupertino,
              ),
            ),
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
                style:
                    UgamText.bodyStrong.copyWith(color: c.ink, fontSize: 12.5),
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
