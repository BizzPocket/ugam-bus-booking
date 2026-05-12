import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:google_fonts/google_fonts.dart';

import '../config/theme.dart';
import '../controllers/tour_controller.dart';
import '../models/bus_details.dart';
import '../models/passenger.dart';
import '../models/seat_layout.dart';
import '../models/seat_type.dart';
import '../utils/passenger_display.dart';
import '../utils/phone_dialer.dart';

/// Read-only seat layout for a single bus on a tour. Renders each seat
/// in the layout grid with the assigned passenger's initials overlaid
/// when taken. Tapping a booked seat surfaces a sheet with the
/// passenger's full name, phone, and seat list — useful for last-minute
/// checks before locking. No re-assignment happens here; that flow
/// lives in TourSeatAssignmentScreen.
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
  @override
  Widget build(BuildContext context) {
    final tourCtrl = Get.find<TourController>();
    return Scaffold(
      backgroundColor: AppColors.bg(context),
      body: SafeArea(
        child: Obx(() {
          final tour = tourCtrl.getTour(widget.tourId);
          final bus = tour?.buses.firstWhereOrNull((b) => b.id == widget.busId);
          if (tour == null || bus == null) {
            return Center(child: Text(tr('bus_status.bus_not_found')));
          }
          final layout = bus.layout;
          if (layout == null) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(40),
                child: Text(
                  tr('bus_status.no_layout'),
                  textAlign: TextAlign.center,
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

          return Column(
            children: [
              _Header(bus: bus, tourTitle: tour.title),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                child: _Tally(
                  assigned: assignedCount,
                  total: totalSeats,
                ),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
                  physics: const AlwaysScrollableScrollPhysics(
                    parent: BouncingScrollPhysics(),
                  ),
                  // Handler-friendly chart: both decks rendered side by side
                  // so the full bus is visible without a deck toggle. Falls
                  // back to a single-deck render when no upper deck exists.
                  child: _SeatGrid(
                    layout: layout,
                    assignments: assignments,
                    onSeatTap: (passenger) =>
                        _showPassengerSheet(context, passenger, bus, tour.id),
                  ),
                ),
              ),
              const _Legend(),
              const SizedBox(height: 12),
            ],
          );
        }),
      ),
    );
  }

  void _showPassengerSheet(
    BuildContext context,
    Passenger passenger,
    Bus bus,
    String tourId,
  ) {
    final tour = Get.find<TourController>().getTour(tourId);
    final seatsOnBus = passenger.assignedSeats
        .where((a) => a.busId == bus.id)
        .map((a) => a.seatId)
        .join(', ');
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface(context),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 14),
                decoration: BoxDecoration(
                  color: AppColors.border(context),
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
                        style: GoogleFonts.inter(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                          color: AppColors.text(context),
                        ),
                      ),
                      if (passenger.phone.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          passenger.phone,
                          style: GoogleFonts.inter(
                            fontSize: 13,
                            color: AppColors.textMuted(context),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                // Quick-call CTA — handler taps to dial the passenger
                // directly when something's wrong with their booking.
                if (passenger.phone.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  InkResponse(
                    onTap: () => PhoneDialer.call(passenger.phone),
                    radius: 24,
                    child: Container(
                      width: 40,
                      height: 40,
                      decoration: const BoxDecoration(
                        color: AppTheme.brandLight,
                        shape: BoxShape.circle,
                      ),
                      alignment: Alignment.center,
                      child: const Icon(
                        Icons.phone_rounded,
                        size: 18,
                        color: AppTheme.brand,
                      ),
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 14),
            _SheetRow(label: tr('bus_status.sheet_bus'), value: bus.name),
            _SheetRow(label: tr('bus_status.sheet_seats_on_bus'), value: seatsOnBus),
            if (tour != null && tour.handlerId == passenger.id)
              Padding(
                padding: const EdgeInsets.only(top: 10),
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 20, 8),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => Get.back(),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  bus.name,
                  style: GoogleFonts.inter(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  '$tourTitle'
                  '${bus.busNumber.isNotEmpty ? ' · ${bus.busNumber}' : ''}',
                  style: GoogleFonts.inter(
                    fontSize: 12,
                    color: AppColors.textMuted(context),
                  ),
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

class _Tally extends StatelessWidget {
  final int assigned;
  final int total;

  const _Tally({required this.assigned, required this.total});

  @override
  Widget build(BuildContext context) {
    final ratio = total == 0 ? 0.0 : assigned / total;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.surface(context),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.border(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                tr('bus_status.seats_assigned', namedArgs: {'assigned': '$assigned', 'total': '$total'}),
                style: GoogleFonts.inter(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: AppColors.text(context),
                ),
              ),
              const Spacer(),
              Text(
                '${(ratio * 100).round()}%',
                style: GoogleFonts.inter(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textMuted(context),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: ratio.clamp(0.0, 1.0),
              minHeight: 6,
              backgroundColor: AppColors.bg(context),
              valueColor: AlwaysStoppedAnimation(AppTheme.brand),
            ),
          ),
        ],
      ),
    );
  }
}

class _SeatGrid extends StatelessWidget {
  final BusLayout layout;
  final Map<String, List<Passenger>> assignments;
  final ValueChanged<Passenger> onSeatTap;

  const _SeatGrid({
    required this.layout,
    required this.assignments,
    required this.onSeatTap,
  });

  @override
  Widget build(BuildContext context) {
    final hasUpper = layout.upperDeck.any((c) => c.hasSeat);
    // When both decks render side-by-side on a phone we have to shrink
    // cells to fit. Single-deck buses keep the roomier 60×48.
    final cellWidth  = hasUpper ? 38.0 : 60.0;
    final cellHeight = hasUpper ? 42.0 : 48.0;
    final seatGap    = hasUpper ? 4.0  : 8.0;
    final aisleGap   = hasUpper ? 10.0 : 24.0;

    final lowerPanel = _DeckPanel(
      title: tr('bus_status.deck_lower'),
      deck: layout.lowerDeck,
      cols: layout.cols,
      assignments: assignments,
      onSeatTap: onSeatTap,
      cellWidth: cellWidth,
      cellHeight: cellHeight,
      seatGap: seatGap,
      aisleGap: aisleGap,
    );

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface(context),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border(context)),
      ),
      child: Column(
        children: [
          // Front-of-bus marker.
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              Icon(Icons.account_circle_rounded,
                  size: 22, color: AppColors.textMuted(context)),
              const SizedBox(width: 6),
              Text(
                tr('bus_status.driver_label'),
                style: GoogleFonts.inter(
                  fontSize: 9,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1,
                  color: AppColors.textMuted(context),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Divider(height: 1, color: AppColors.border(context)),
          const SizedBox(height: 10),
          if (!hasUpper)
            lowerPanel
          else
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: lowerPanel),
                Container(
                  width: 1,
                  margin: const EdgeInsets.symmetric(horizontal: 8),
                  // Roughly matches the panel's intrinsic height. Using a
                  // sized divider keeps it lined up without forcing the
                  // panels into IntrinsicHeight (which is expensive).
                  constraints: const BoxConstraints(minHeight: 200),
                  color: AppColors.border(context),
                ),
                Expanded(
                  child: _DeckPanel(
                    title: tr('bus_status.deck_upper'),
                    deck: layout.upperDeck,
                    cols: layout.cols,
                    assignments: assignments,
                    onSeatTap: onSeatTap,
                    cellWidth: cellWidth,
                    cellHeight: cellHeight,
                    seatGap: seatGap,
                    aisleGap: aisleGap,
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

class _DeckPanel extends StatelessWidget {
  final String title;
  final List<SeatCell> deck;
  final int cols;
  final Map<String, List<Passenger>> assignments;
  final ValueChanged<Passenger> onSeatTap;
  final double cellWidth;
  final double cellHeight;
  final double seatGap;
  final double aisleGap;

  const _DeckPanel({
    required this.title,
    required this.deck,
    required this.cols,
    required this.assignments,
    required this.onSeatTap,
    required this.cellWidth,
    required this.cellHeight,
    required this.seatGap,
    required this.aisleGap,
  });

  @override
  Widget build(BuildContext context) {
    var maxRow = 0;
    for (final c in deck) {
      if (c.hasSeat && c.row > maxRow) maxRow = c.row;
    }
    return Column(
      children: [
        Text(
          title,
          style: GoogleFonts.inter(
            fontSize: 10,
            fontWeight: FontWeight.w700,
            letterSpacing: 1,
            color: AppColors.textMuted(context),
          ),
        ),
        const SizedBox(height: 8),
        for (int r = 0; r <= maxRow; r++) ...[
          _row(r),
          if (r < maxRow) SizedBox(height: seatGap),
        ],
      ],
    );
  }

  Widget _row(int row) {
    final children = <Widget>[];
    final leftCols = cols ~/ 2;
    for (int c = 0; c < cols; c++) {
      if (c == leftCols) {
        children.add(SizedBox(width: aisleGap));
      }
      final cell = deck.firstWhere(
        (s) => s.row == row && s.col == c,
        orElse: () => SeatCell(row: row, col: c),
      );
      if (cell.isEmpty) {
        children.add(SizedBox(width: cellWidth, height: cellHeight));
      } else {
        final occupants = assignments[cell.seatId] ?? const <Passenger>[];
        // RepaintBoundary keeps an occupant tap from invalidating the
        // whole chart layer — only the tapped tile repaints.
        children.add(RepaintBoundary(
          child: _Cell(
            cell: cell,
            passengers: occupants,
            onTap: onSeatTap,
            width: cellWidth,
            height: cellHeight,
          ),
        ));
      }
      if (c < cols - 1 && c != leftCols - 1) {
        children.add(SizedBox(width: seatGap));
      }
    }
    // FittedBox scales the row down uniformly when the deck panel is
    // narrower than the natural row width. Two-deck phones can hit this
    // because each panel only gets ~half the screen — without scaleDown
    // Flutter complains "RIGHT OVERFLOWED BY N PIXELS" in debug.
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.center,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: children,
      ),
    );
  }
}

class _Cell extends StatelessWidget {
  final SeatCell cell;
  /// Occupants of this seat. `length == 0` → empty, `length == 1` → fully
  /// owned (current behavior), `length == 2` → shared doubleSofa rendered
  /// as two side-by-side halves.
  final List<Passenger> passengers;
  final ValueChanged<Passenger> onTap;
  final double width;
  final double height;

  const _Cell({
    required this.cell,
    required this.passengers,
    required this.onTap,
    this.width = 60,
    this.height = 48,
  });

  Color get _typeTint {
    switch (cell.seatType) {
      case SeatType.singleSofa:
        return const Color(0xFFE7F8EE);
      case SeatType.doubleSofa:
        return const Color(0xFFE0F2FE);
      case SeatType.seater:
        return const Color(0xFFF1F5F9);
      case null:
        return Colors.white;
    }
  }

  Color _typeBorder(BuildContext context) {
    switch (cell.seatType) {
      case SeatType.singleSofa:
        return const Color(0xFF22C55E);
      case SeatType.doubleSofa:
        return const Color(0xFF0EA5E9);
      case SeatType.seater:
        return AppColors.textMuted(context);
      case null:
        return AppColors.border(context);
    }
  }

  String? get _typeMark {
    switch (cell.seatType) {
      case SeatType.singleSofa:
        return 'S';
      case SeatType.doubleSofa:
        return 'D';
      case SeatType.seater:
        return 'T';
      case null:
        return null;
    }
  }

  String _initials(String name) {
    final parts = name.trim().split(RegExp(r'\s+'));
    if (parts.length >= 2) return '${parts.first[0]}${parts.last[0]}'.toUpperCase();
    return name.isEmpty ? '?' : name[0].toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final compact = width < 50;

    // Shared doubleSofa — render two halves with the two passengers'
    // initials so the handler can see at a glance both occupants. Tap on
    // either half opens that occupant's sheet. A single passenger
    // holding both berths (whole-double-as-2-singles) renders as a
    // normal "owned" tile below — split is only for two DIFFERENT
    // passengers.
    final uniquePassengers = <Passenger>[];
    final seenIds = <String>{};
    for (final p in passengers) {
      if (seenIds.add(p.id)) uniquePassengers.add(p);
    }

    // Half-occupied doubleSofa (1 unique passenger holding 1 berth — the
    // other berth is still up for sale). Render as split so the handler
    // can see at a glance there's a free half.
    final isHalfOccupiedDouble = cell.seatType == SeatType.doubleSofa &&
        uniquePassengers.length == 1 &&
        passengers.length == 1;
    if (isHalfOccupiedDouble) {
      final occupant = uniquePassengers.first;
      return SizedBox(
        width: width,
        height: height,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: _typeBorder(context), width: 1.5),
          ),
          clipBehavior: Clip.antiAlias,
          child: Row(
            children: [
              Expanded(
                child: GestureDetector(
                  onTap: () => onTap(occupant),
                  child: Container(
                    color: AppTheme.brand,
                    alignment: Alignment.center,
                    child: Text(
                      _initials(occupant.displayName),
                      style: AppText.badge.copyWith(
                        fontSize: compact ? 9 : 11,
                        fontWeight: FontWeight.w800,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              ),
              Container(width: 1, color: Colors.white),
              Expanded(
                child: Container(
                  color: _typeTint,
                  alignment: Alignment.center,
                  child: Text(
                    cell.seatId ?? '',
                    style: AppText.badgeSm.copyWith(
                      fontSize: compact ? 8 : 9,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textMuted(context),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (uniquePassengers.length >= 2) {
      final left = uniquePassengers[0];
      final right = uniquePassengers[1];
      return SizedBox(
        width: width,
        height: height,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: AppTheme.brand, width: 1.5),
          ),
          clipBehavior: Clip.antiAlias,
          child: Row(
            children: [
              Expanded(
                child: GestureDetector(
                  onTap: () => onTap(left),
                  child: Container(
                    color: AppTheme.brand,
                    alignment: Alignment.center,
                    child: Text(
                      _initials(left.displayName),
                      style: AppText.badge.copyWith(
                        fontSize: compact ? 9 : 11,
                        fontWeight: FontWeight.w800,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              ),
              Container(width: 1, color: Colors.white),
              Expanded(
                child: GestureDetector(
                  onTap: () => onTap(right),
                  child: Container(
                    color: AppTheme.brand,
                    alignment: Alignment.center,
                    child: Text(
                      _initials(right.displayName),
                      style: AppText.badge.copyWith(
                        fontSize: compact ? 9 : 11,
                        fontWeight: FontWeight.w800,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    final passenger = passengers.isNotEmpty ? passengers.first : null;
    final taken = passenger != null;
    final bg = taken ? AppTheme.brand : _typeTint;
    final border = taken ? AppTheme.brand : _typeBorder(context);
    final textColor = taken ? Colors.white : AppColors.text(context);

    return GestureDetector(
      onTap: taken ? () => onTap(passenger) : null,
      child: Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: border, width: 1.5),
        ),
        child: Stack(
          children: [
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    cell.seatId ?? '',
                    style: AppText.cardLabel.copyWith(
                      fontSize: compact ? 9 : 10,
                      fontWeight: FontWeight.w600,
                      color: textColor,
                    ),
                  ),
                  if (taken)
                    Text(
                      _initials(passenger.displayName),
                      style: AppText.badge.copyWith(
                        fontSize: compact ? 9 : 11,
                        fontWeight: FontWeight.w800,
                        color: textColor,
                      ),
                    ),
                ],
              ),
            ),
            if (_typeMark != null)
              Positioned(
                top: 2,
                right: 4,
                child: Text(
                  _typeMark!,
                  style: AppText.badgeSm.copyWith(
                    color: textColor.withValues(alpha: 0.75),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Wrap(
        spacing: 14,
        runSpacing: 6,
        alignment: WrapAlignment.center,
        children: [
          _LegendDot(color: const Color(0xFFE7F8EE), border: const Color(0xFF22C55E), label: tr('bus_status.legend_single')),
          _LegendDot(color: const Color(0xFFE0F2FE), border: const Color(0xFF0EA5E9), label: tr('bus_status.legend_double')),
          _LegendDot(color: const Color(0xFFF1F5F9), border: AppColors.textMuted(context), label: tr('bus_status.legend_seater')),
          _LegendDot(color: AppTheme.brand, border: AppTheme.brand, label: tr('bus_status.legend_booked')),
        ],
      ),
    );
  }
}

class _LegendDot extends StatelessWidget {
  final Color color;
  final Color border;
  final String label;

  const _LegendDot({
    required this.color,
    required this.border,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 14,
          height: 14,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(3),
            border: Border.all(color: border, width: 1.5),
          ),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: GoogleFonts.inter(
            fontSize: 11,
            fontWeight: FontWeight.w500,
            color: AppColors.textMuted(context),
          ),
        ),
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
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 130,
            child: Text(
              label,
              style: GoogleFonts.inter(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: AppColors.textMuted(context),
              ),
            ),
          ),
          Expanded(
            child: Text(
              value.isEmpty ? '—' : value,
              style: GoogleFonts.inter(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: AppColors.text(context),
              ),
            ),
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
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFFFEF3C7),
        borderRadius: BorderRadius.circular(9999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.workspace_premium_rounded,
              size: 14, color: Color(0xFFB45309)),
          const SizedBox(width: 6),
          Text(
            tr('bus_status.handler_badge'),
            style: GoogleFonts.inter(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: const Color(0xFFB45309),
            ),
          ),
        ],
      ),
    );
  }
}
