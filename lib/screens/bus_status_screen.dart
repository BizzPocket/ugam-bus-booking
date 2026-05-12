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
  int _deck = 0; // 0 = lower, 1 = upper

  @override
  Widget build(BuildContext context) {
    final tourCtrl = Get.find<TourController>();
    return Scaffold(
      backgroundColor: AppTheme.bgLight,
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

          // Build seatId → passenger map for this bus.
          final assignments = <String, Passenger>{};
          for (final p in tour.passengers) {
            for (final a in p.assignedSeats) {
              if (a.busId == bus.id) assignments[a.seatId] = p;
            }
          }

          final totalSeats = layout.totalSeats;
          final assignedCount = assignments.length;

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
              _DeckTabs(
                deck: _deck,
                hasUpper: layout.upperDeck.any((c) => c.hasSeat),
                onChanged: (v) => setState(() => _deck = v),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
                  physics: const AlwaysScrollableScrollPhysics(
                    parent: BouncingScrollPhysics(),
                  ),
                  child: _SeatGrid(
                    layout: layout,
                    isUpper: _deck == 1,
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
      backgroundColor: Colors.white,
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
                  color: AppTheme.borderDefault,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Text(
              passenger.displayName,
              style: GoogleFonts.inter(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: AppTheme.textPrimary,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              passenger.phone,
              style: GoogleFonts.inter(
                fontSize: 13,
                color: AppTheme.textSecondary,
              ),
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
                    color: AppTheme.textMuted,
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
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.borderLight),
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
                  color: AppTheme.textPrimary,
                ),
              ),
              const Spacer(),
              Text(
                '${(ratio * 100).round()}%',
                style: GoogleFonts.inter(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.textMuted,
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
              backgroundColor: AppTheme.bgLight,
              valueColor: AlwaysStoppedAnimation(AppTheme.brand),
            ),
          ),
        ],
      ),
    );
  }
}

class _DeckTabs extends StatelessWidget {
  final int deck;
  final bool hasUpper;
  final ValueChanged<int> onChanged;

  const _DeckTabs({
    required this.deck,
    required this.hasUpper,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    if (!hasUpper) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Container(
        height: 38,
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: AppTheme.bgLight,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            _DeckChip(label: tr('bus_status.deck_lower'), isActive: deck == 0, onTap: () => onChanged(0)),
            _DeckChip(label: tr('bus_status.deck_upper'), isActive: deck == 1, onTap: () => onChanged(1)),
          ],
        ),
      ),
    );
  }
}

class _DeckChip extends StatelessWidget {
  final String label;
  final bool isActive;
  final VoidCallback onTap;

  const _DeckChip({
    required this.label,
    required this.isActive,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          decoration: BoxDecoration(
            color: isActive ? AppTheme.brand : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
          ),
          alignment: Alignment.center,
          child: Text(
            label,
            style: GoogleFonts.inter(
              fontSize: 13,
              fontWeight: isActive ? FontWeight.w700 : FontWeight.w500,
              color: isActive ? Colors.white : AppTheme.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}

class _SeatGrid extends StatelessWidget {
  final BusLayout layout;
  final bool isUpper;
  final Map<String, Passenger> assignments;
  final ValueChanged<Passenger> onSeatTap;

  const _SeatGrid({
    required this.layout,
    required this.isUpper,
    required this.assignments,
    required this.onSeatTap,
  });

  @override
  Widget build(BuildContext context) {
    final deck = isUpper ? layout.upperDeck : layout.lowerDeck;
    final cols = layout.cols;
    var maxRow = 0;
    for (final c in deck) {
      if (c.hasSeat && c.row > maxRow) maxRow = c.row;
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.borderLight),
      ),
      child: Column(
        children: [
          // Front-of-bus marker.
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              Icon(Icons.account_circle_rounded,
                  size: 22, color: AppTheme.textMuted),
              const SizedBox(width: 6),
              Text(
                tr('bus_status.driver_label'),
                style: GoogleFonts.inter(
                  fontSize: 9,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1,
                  color: AppTheme.textMuted,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          const Divider(height: 1, color: AppTheme.borderLight),
          const SizedBox(height: 10),
          for (int r = 0; r <= maxRow; r++) ...[
            _row(deck, r, cols),
            if (r < maxRow) const SizedBox(height: 8),
          ],
        ],
      ),
    );
  }

  Widget _row(List<SeatCell> deck, int row, int cols) {
    final children = <Widget>[];
    final leftCols = cols ~/ 2;
    for (int c = 0; c < cols; c++) {
      if (c == leftCols) {
        children.add(const SizedBox(width: 24));
      }
      final cell = deck.firstWhere(
        (s) => s.row == row && s.col == c,
        orElse: () => SeatCell(row: row, col: c),
      );
      if (cell.isEmpty) {
        children.add(const SizedBox(width: 60, height: 48));
      } else {
        final passenger = assignments[cell.seatId];
        children.add(_Cell(cell: cell, passenger: passenger, onTap: onSeatTap));
      }
      if (c < cols - 1 && c != leftCols - 1) {
        children.add(const SizedBox(width: 8));
      }
    }
    return Row(mainAxisAlignment: MainAxisAlignment.center, children: children);
  }
}

class _Cell extends StatelessWidget {
  final SeatCell cell;
  final Passenger? passenger;
  final ValueChanged<Passenger> onTap;

  const _Cell({
    required this.cell,
    required this.passenger,
    required this.onTap,
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

  Color get _typeBorder {
    switch (cell.seatType) {
      case SeatType.singleSofa:
        return const Color(0xFF22C55E);
      case SeatType.doubleSofa:
        return const Color(0xFF0EA5E9);
      case SeatType.seater:
        return AppTheme.textMuted;
      case null:
        return AppTheme.borderLight;
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
    final taken = passenger != null;
    final bg = taken ? AppTheme.brand : _typeTint;
    final border = taken ? AppTheme.brand : _typeBorder;
    final textColor = taken ? Colors.white : AppTheme.textPrimary;

    return GestureDetector(
      onTap: taken ? () => onTap(passenger!) : null,
      child: Container(
        width: 60,
        height: 48,
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
                    style: GoogleFonts.inter(
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      color: textColor,
                    ),
                  ),
                  if (taken)
                    Text(
                      _initials(passenger!.displayName),
                      style: GoogleFonts.inter(
                        fontSize: 11,
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
                  style: GoogleFonts.inter(
                    fontSize: 9,
                    fontWeight: FontWeight.w700,
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
          _LegendDot(color: const Color(0xFFF1F5F9), border: AppTheme.textMuted, label: tr('bus_status.legend_seater')),
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
            color: AppTheme.textSecondary,
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
                color: AppTheme.textMuted,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value.isEmpty ? '—' : value,
              style: GoogleFonts.inter(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: AppTheme.textPrimary,
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
