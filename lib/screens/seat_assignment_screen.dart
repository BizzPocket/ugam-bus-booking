import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:google_fonts/google_fonts.dart';

import '../config/theme.dart';
import '../controllers/tour_controller.dart';
import '../models/passenger.dart';
import '../models/seat_assignment.dart';
import '../models/seat_layout.dart';
import '../models/tour.dart';
import '../utils/passenger_display.dart';

class SeatAssignmentScreen extends StatefulWidget {
  const SeatAssignmentScreen({super.key});

  @override
  State<SeatAssignmentScreen> createState() => _SeatAssignmentScreenState();
}

class _SeatAssignmentScreenState extends State<SeatAssignmentScreen> {
  final tourCtrl = Get.find<TourController>();
  int _selectedTourIndex = 0;
  int _selectedBusIndex = 0;
  int _selectedDeck = 0; // 0 = lower, 1 = upper
  String? _selectedPassengerId;
  final Set<String> _selectedSeatIds = {};

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bgLight,
      body: SafeArea(
        child: Obx(() {
          final activeTours = tourCtrl.activeTours;
          if (activeTours.isEmpty) {
            return const _Empty(
              icon: Icons.grid_view_rounded,
              title: 'No active tours',
              body: 'Create a tour and add buses to start assigning seats.',
            );
          }

          if (_selectedTourIndex >= activeTours.length) {
            _selectedTourIndex = 0;
          }

          final tour = activeTours[_selectedTourIndex];

          if (tour.buses.isEmpty) {
            return _buildTourHeader(tour, activeTours, withBody: const _Empty(
              icon: Icons.directions_bus_rounded,
              title: 'No buses added',
              body: 'Add a bus to this tour before assigning seats.',
            ));
          }

          if (_selectedBusIndex >= tour.buses.length) {
            _selectedBusIndex = 0;
          }

          final bus = tour.buses[_selectedBusIndex];
          final passengers = tour.passengers;

          // Build set of booked seat IDs for this bus
          final bookedSeatMap = <String, String>{}; // seatId -> passengerName
          for (final p in passengers) {
            for (final a in p.assignedSeats) {
              if (a.busId == bus.id) {
                bookedSeatMap[a.seatId] = p.displayName;
              }
            }
          }

          final assignedCount = bookedSeatMap.length;
          final totalSeats = bus.totalSeats;
          final pct = totalSeats > 0 ? (assignedCount * 100 ~/ totalSeats) : 0;

          return Column(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(height: 16),

                      // ── Header ──
                      Row(
                        children: [
                          Text(
                            'Seat Assignment',
                            style: GoogleFonts.inter(
                              fontSize: 20,
                              fontWeight: FontWeight.w700,
                              color: AppTheme.textPrimary,
                            ),
                          ),
                          const Spacer(),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 6),
                            decoration: BoxDecoration(
                              color: AppTheme.brandLight,
                              borderRadius: BorderRadius.circular(9999),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.directions_bus_rounded,
                                    size: 14, color: AppTheme.brand),
                                const SizedBox(width: 4),
                                Text(
                                  'Fleet',
                                  style: GoogleFonts.inter(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    color: AppTheme.brand,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),

                      const SizedBox(height: 4),

                      // ── Tour subtitle ──
                      Text(
                        '${tour.title} · ${tour.buses.length} Buses · '
                        '${tour.totalSeatsAssigned}/${tour.totalBusSeats} Seats Assigned',
                        style: GoogleFonts.newsreader(
                          fontSize: 14,
                          color: AppTheme.textSecondary,
                        ),
                      ),

                      const SizedBox(height: 14),

                      // ── Bus Selector ──
                      SizedBox(
                        height: 56,
                        child: ListView.separated(
                          scrollDirection: Axis.horizontal,
                          itemCount: tour.buses.length,
                          separatorBuilder: (_, _) =>
                              const SizedBox(width: 8),
                          itemBuilder: (context, i) {
                            final b = tour.buses[i];
                            final isActive = i == _selectedBusIndex;
                            final bAssigned = passengers.fold<int>(
                              0,
                              (sum, p) =>
                                  sum +
                                  p.assignedSeats
                                      .where((a) => a.busId == b.id)
                                      .length,
                            );
                            return GestureDetector(
                              onTap: () => setState(() {
                                _selectedBusIndex = i;
                                _selectedSeatIds.clear();
                              }),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 14, vertical: 8),
                                decoration: BoxDecoration(
                                  color: isActive
                                      ? AppTheme.brand
                                      : Colors.white,
                                  borderRadius: BorderRadius.circular(12),
                                  border: isActive
                                      ? null
                                      : Border.all(
                                          color: AppTheme.borderLight),
                                ),
                                child: Column(
                                  mainAxisAlignment:
                                      MainAxisAlignment.center,
                                  children: [
                                    Text(
                                      b.name,
                                      style: GoogleFonts.inter(
                                        fontSize: 12,
                                        fontWeight: isActive
                                            ? FontWeight.w700
                                            : FontWeight.w600,
                                        color: isActive
                                            ? Colors.white
                                            : AppTheme.textPrimary,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(
                                          '$bAssigned/${b.totalSeats}',
                                          style: GoogleFonts.inter(
                                            fontSize: 10,
                                            fontWeight: FontWeight.w500,
                                            color: isActive
                                                ? Colors.white
                                                    .withValues(alpha: 0.8)
                                                : AppTheme.textMuted,
                                          ),
                                        ),
                                        Text(
                                          ' · ${b.isAC ? "AC" : "Non-AC"}',
                                          style: GoogleFonts.inter(
                                            fontSize: 10,
                                            fontWeight: FontWeight.w500,
                                            color: isActive
                                                ? Colors.white
                                                    .withValues(alpha: 0.8)
                                                : AppTheme.textMuted,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                      ),

                      const SizedBox(height: 14),

                      // ── Selected Bus Info ──
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 10),
                        decoration: BoxDecoration(
                          color: AppTheme.brandLight,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                              color: AppTheme.brand.withValues(alpha: 0.12)),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.directions_bus_rounded,
                                size: 16, color: AppTheme.brand),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Column(
                                crossAxisAlignment:
                                    CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '${bus.busNumber} · ${bus.isAC ? "AC" : "Non-AC"} ${bus.busType}',
                                    style: GoogleFonts.inter(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                      color: AppTheme.textPrimary,
                                    ),
                                  ),
                                  const SizedBox(height: 1),
                                  Text(
                                    'Driver: ${bus.driverName} · $totalSeats seats',
                                    style: GoogleFonts.inter(
                                      fontSize: 10,
                                      color: AppTheme.textSecondary,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                Text(
                                  '$assignedCount/$totalSeats',
                                  style: GoogleFonts.inter(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w700,
                                    color: AppTheme.brand,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  '$pct% full',
                                  style: GoogleFonts.inter(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w500,
                                    color: AppTheme.success,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(height: 14),

                      // ── Deck Tabs (only if bus has upper deck) ──
                      if (bus.layout != null &&
                          bus.layout!.upperDeck
                              .any((c) => c.hasSeat)) ...[
                        Container(
                          height: 40,
                          padding: const EdgeInsets.all(4),
                          decoration: BoxDecoration(
                            color: AppTheme.brandLight,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Row(
                            children: [
                              _DeckTab(
                                label: 'Lower Deck',
                                isActive: _selectedDeck == 0,
                                onTap: () => setState(
                                    () => _selectedDeck = 0),
                              ),
                              _DeckTab(
                                label: 'Upper Deck',
                                isActive: _selectedDeck == 1,
                                onTap: () => setState(
                                    () => _selectedDeck = 1),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 14),
                      ],

                      // ── Seat Grid ──
                      if (bus.layout != null)
                        _SeatGrid(
                          layout: bus.layout!,
                          isUpperDeck: _selectedDeck == 1,
                          bookedSeatMap: bookedSeatMap,
                          selectedSeatIds: _selectedSeatIds,
                          onSeatTap: (seatId) {
                            if (_selectedPassengerId == null) {
                              Get.snackbar(
                                'Select a passenger',
                                'Choose a passenger below before selecting seats.',
                                snackPosition: SnackPosition.BOTTOM,
                              );
                              return;
                            }
                            if (bookedSeatMap.containsKey(seatId)) return;
                            setState(() {
                              if (_selectedSeatIds.contains(seatId)) {
                                _selectedSeatIds.remove(seatId);
                              } else {
                                _selectedSeatIds.add(seatId);
                              }
                            });
                          },
                        )
                      else
                        Container(
                          padding: const EdgeInsets.all(24),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: AppTheme.borderLight),
                          ),
                          child: Center(
                            child: Text(
                              'No seat layout configured for this bus.',
                              style: GoogleFonts.inter(
                                fontSize: 13,
                                color: AppTheme.textMuted,
                              ),
                            ),
                          ),
                        ),

                      const SizedBox(height: 12),

                      // ── Legend ──
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          _LegendItem(
                            color: AppTheme.brandLight,
                            border: AppTheme.borderDefault,
                            label: 'Available',
                          ),
                          const SizedBox(width: 16),
                          _LegendItem(
                            color: AppTheme.brand,
                            label: 'Booked',
                          ),
                          const SizedBox(width: 16),
                          _LegendItem(
                            color: AppTheme.brandAccent,
                            label: 'Selected',
                            hasShadow: true,
                          ),
                        ],
                      ),

                      const SizedBox(height: 14),

                      // ── Passenger selector + Assign Panel ──
                      _AssignPanel(
                        passengers: passengers,
                        selectedPassengerId: _selectedPassengerId,
                        selectedSeatIds: _selectedSeatIds,
                        busId: bus.id,
                        tourId: tour.id,
                        onPassengerSelected: (id) {
                          setState(() {
                            _selectedPassengerId =
                                id.isEmpty ? null : id;
                            _selectedSeatIds.clear();
                          });
                        },
                        onAssign: _handleAssign,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          );
        }),
      ),
    );
  }

  Widget _buildTourHeader(Tour tour, List<Tour> activeTours,
      {required Widget withBody}) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(20),
          child: Text(
            'Seat Assignment',
            style: GoogleFonts.inter(
              fontSize: 20,
              fontWeight: FontWeight.w700,
              color: AppTheme.textPrimary,
            ),
          ),
        ),
        Expanded(child: withBody),
      ],
    );
  }

  Future<void> _handleAssign() async {
    if (_selectedPassengerId == null || _selectedSeatIds.isEmpty) return;

    final tour = tourCtrl.activeTours[_selectedTourIndex];
    final bus = tour.buses[_selectedBusIndex];

    final assignments = _selectedSeatIds
        .map((seatId) => SeatAssignment(busId: bus.id, seatId: seatId))
        .toList();

    await tourCtrl.assignSeats(tour.id, _selectedPassengerId!, assignments);

    setState(() {
      _selectedSeatIds.clear();
    });

    Get.snackbar(
      'Seats Assigned',
      '${assignments.length} seat(s) assigned successfully.',
      snackPosition: SnackPosition.BOTTOM,
    );
  }
}

// ── Deck Tab ──────────────────────────────────────────────────
class _DeckTab extends StatelessWidget {
  final String label;
  final bool isActive;
  final VoidCallback onTap;

  const _DeckTab({
    required this.label,
    required this.isActive,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            color: isActive ? AppTheme.brand : Colors.transparent,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Center(
            child: Text(
              label,
              style: GoogleFonts.inter(
                fontSize: 13,
                fontWeight: isActive ? FontWeight.w600 : FontWeight.w500,
                color: isActive ? Colors.white : AppTheme.textMuted,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ── Seat Grid ─────────────────────────────────────────────────
class _SeatGrid extends StatelessWidget {
  final BusLayout layout;
  final bool isUpperDeck;
  final Map<String, String> bookedSeatMap;
  final Set<String> selectedSeatIds;
  final ValueChanged<String> onSeatTap;

  const _SeatGrid({
    required this.layout,
    required this.isUpperDeck,
    required this.bookedSeatMap,
    required this.selectedSeatIds,
    required this.onSeatTap,
  });

  @override
  Widget build(BuildContext context) {
    final deck = isUpperDeck ? layout.upperDeck : layout.lowerDeck;
    final seatCells = deck.where((c) => c.hasSeat).toList();

    if (seatCells.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppTheme.borderLight),
        ),
        child: Center(
          child: Text(
            'No seats on this deck.',
            style: GoogleFonts.inter(fontSize: 13, color: AppTheme.textMuted),
          ),
        ),
      );
    }

    // Build rows from the flat list
    final maxRow = seatCells.map((c) => c.row).reduce((a, b) => a > b ? a : b);
    final cols = layout.cols;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: const [
          BoxShadow(
            color: Color(0x08000000),
            offset: Offset(0, 1),
            blurRadius: 3,
          ),
        ],
      ),
      child: Column(
        children: [
          // Driver row
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              Icon(Icons.account_circle_rounded,
                  size: 28, color: AppTheme.textMuted),
              const SizedBox(width: 8),
              Text(
                'DRIVER',
                style: GoogleFonts.inter(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1,
                  color: AppTheme.textMuted,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          const Divider(height: 1, color: AppTheme.borderLight),
          const SizedBox(height: 12),
          // Seat rows
          for (int r = 0; r <= maxRow; r++) ...[
            _buildSeatRow(r, cols, deck),
            if (r < maxRow) const SizedBox(height: 8),
          ],
        ],
      ),
    );
  }

  Widget _buildSeatRow(int row, int cols, List<SeatCell> deck) {
    // Get cells for this row, filling gaps
    final rowCells = <Widget>[];
    final leftCols = cols ~/ 2;

    for (int c = 0; c < cols; c++) {
      // Insert aisle gap between left and right halves
      if (c == leftCols) {
        rowCells.add(const SizedBox(width: 24));
      }

      final cell = deck.where((s) => s.row == row && s.col == c).firstOrNull;

      if (cell == null || cell.isEmpty) {
        rowCells.add(const SizedBox(width: 60, height: 44));
      } else {
        final seatId = cell.seatId!;
        final isBooked = bookedSeatMap.containsKey(seatId);
        final isSelected = selectedSeatIds.contains(seatId);

        rowCells.add(
          GestureDetector(
            onTap: () => onSeatTap(seatId),
            child: _SeatCell(
              seatId: seatId,
              isBooked: isBooked,
              isSelected: isSelected,
            ),
          ),
        );
      }

      if (c < cols - 1 && c != leftCols - 1) {
        rowCells.add(const SizedBox(width: 8));
      }
    }

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: rowCells,
    );
  }
}

// ── Single Seat Cell ──────────────────────────────────────────
class _SeatCell extends StatelessWidget {
  final String seatId;
  final bool isBooked;
  final bool isSelected;

  const _SeatCell({
    required this.seatId,
    required this.isBooked,
    required this.isSelected,
  });

  @override
  Widget build(BuildContext context) {
    Color bgColor;
    Color textColor;
    BoxDecoration decoration;

    if (isSelected) {
      bgColor = AppTheme.brandAccent;
      textColor = Colors.white;
      decoration = BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(6),
        boxShadow: [
          BoxShadow(
            color: AppTheme.brandAccent.withValues(alpha: 0.25),
            offset: const Offset(0, 2),
            blurRadius: 8,
          ),
        ],
      );
    } else if (isBooked) {
      bgColor = AppTheme.brand;
      textColor = Colors.white;
      decoration = BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(6),
      );
    } else {
      bgColor = AppTheme.brandLight;
      textColor = AppTheme.textSecondary;
      decoration = BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: AppTheme.borderDefault, width: 1.5),
      );
    }

    return Container(
      width: 60,
      height: 44,
      decoration: decoration,
      child: Center(
        child: Text(
          seatId,
          style: GoogleFonts.inter(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: textColor,
          ),
        ),
      ),
    );
  }
}

// ── Legend Item ────────────────────────────────────────────────
class _LegendItem extends StatelessWidget {
  final Color color;
  final Color? border;
  final String label;
  final bool hasShadow;

  const _LegendItem({
    required this.color,
    this.border,
    required this.label,
    this.hasShadow = false,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 16,
          height: 16,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(4),
            border:
                border != null ? Border.all(color: border!, width: 1.5) : null,
            boxShadow: hasShadow
                ? [
                    BoxShadow(
                      color: color.withValues(alpha: 0.25),
                      offset: const Offset(0, 1),
                      blurRadius: 4,
                    ),
                  ]
                : null,
          ),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: GoogleFonts.inter(
            fontSize: 11,
            fontWeight: FontWeight.w500,
            color: AppTheme.textMuted,
          ),
        ),
      ],
    );
  }
}

// ── Assign Panel ──────────────────────────────────────────────
class _AssignPanel extends StatelessWidget {
  final List<Passenger> passengers;
  final String? selectedPassengerId;
  final Set<String> selectedSeatIds;
  final String busId;
  final String tourId;
  final ValueChanged<String> onPassengerSelected;
  final VoidCallback onAssign;

  const _AssignPanel({
    required this.passengers,
    required this.selectedPassengerId,
    required this.selectedSeatIds,
    required this.busId,
    required this.tourId,
    required this.onPassengerSelected,
    required this.onAssign,
  });

  String _initials(String name) {
    final parts = name.trim().split(RegExp(r'\s+'));
    if (parts.length >= 2) {
      return '${parts.first[0]}${parts.last[0]}'.toUpperCase();
    }
    return name.isNotEmpty ? name[0].toUpperCase() : '?';
  }

  @override
  Widget build(BuildContext context) {
    // Get unassigned or partially assigned passengers
    final assignable = passengers
        .where((p) => !p.isFullyAssigned)
        .toList();

    if (assignable.isEmpty && passengers.isNotEmpty) {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppTheme.successLight,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppTheme.success),
        ),
        child: Row(
          children: [
            const Icon(Icons.check_circle_rounded,
                size: 20, color: AppTheme.success),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'All passengers are fully assigned!',
                style: GoogleFonts.inter(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.success,
                ),
              ),
            ),
          ],
        ),
      );
    }

    if (assignable.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppTheme.borderLight),
        ),
        child: Center(
          child: Text(
            'No passengers to assign. Add passengers first.',
            style: GoogleFonts.inter(
              fontSize: 13,
              color: AppTheme.textMuted,
            ),
          ),
        ),
      );
    }

    // If no passenger selected, show passenger picker
    if (selectedPassengerId == null) {
      return _PassengerPicker(
        passengers: assignable,
        onSelected: onPassengerSelected,
      );
    }

    final pax = assignable.cast<Passenger?>().firstWhere(
          (p) => p!.id == selectedPassengerId,
          orElse: () => null,
        );

    if (pax == null) {
      return _PassengerPicker(
        passengers: assignable,
        onSelected: onPassengerSelected,
      );
    }

    final remaining = pax.totalSeatsRequested - pax.totalSeatsAssigned;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.borderLight),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Passenger info
          Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: const BoxDecoration(
                  color: AppTheme.brand,
                  shape: BoxShape.circle,
                ),
                child: Center(
                  child: Text(
                    _initials(pax.name),
                    style: GoogleFonts.inter(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      pax.name,
                      style: GoogleFonts.inter(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: AppTheme.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      pax.phone,
                      style: GoogleFonts.inter(
                        fontSize: 11,
                        color: AppTheme.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
              // Change passenger button
              GestureDetector(
                onTap: () => onPassengerSelected(''),
                child: Text(
                  'Change',
                  style: GoogleFonts.inter(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.brand,
                  ),
                ),
              ),
            ],
          ),

          const SizedBox(height: 12),

          // Request info badges
          if (pax.requestLines.isNotEmpty)
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                _InfoChip(
                  icon: Icons.event_seat_rounded,
                  label: '${pax.totalSeatsRequested} Seats',
                ),
                _InfoChip(
                  label: pax.requestLines.map((l) => l.label).join(' + '),
                ),
              ],
            ),

          // Preference note
          if (pax.note != null && pax.note!.isNotEmpty) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                const Icon(Icons.star_rounded,
                    size: 12, color: AppTheme.brandAccent),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    'Pref: ${pax.note}',
                    style: GoogleFonts.inter(
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      color: const Color(0xFFD97706),
                    ),
                  ),
                ),
              ],
            ),
          ],

          const SizedBox(height: 12),

          // Selected seats row
          Row(
            children: [
              Text(
                'Selected:',
                style: GoogleFonts.inter(
                  fontSize: 13,
                  color: AppTheme.textSecondary,
                ),
              ),
              const SizedBox(width: 8),
              if (selectedSeatIds.isEmpty)
                Text(
                  'Tap seats above',
                  style: GoogleFonts.inter(
                    fontSize: 11,
                    fontStyle: FontStyle.italic,
                    color: AppTheme.textMuted,
                  ),
                )
              else ...[
                ...selectedSeatIds.map(
                  (id) => Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFEF3C7),
                        borderRadius: BorderRadius.circular(9999),
                      ),
                      child: Text(
                        id,
                        style: GoogleFonts.inter(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: const Color(0xFF92400E),
                        ),
                      ),
                    ),
                  ),
                ),
                if (remaining - selectedSeatIds.length > 0) ...[
                  const SizedBox(width: 4),
                  Text(
                    '${remaining - selectedSeatIds.length} more needed',
                    style: GoogleFonts.inter(
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      color: AppTheme.danger,
                    ),
                  ),
                ],
              ],
            ],
          ),

          const SizedBox(height: 12),

          // Assign button
          GestureDetector(
            onTap: selectedSeatIds.isNotEmpty ? onAssign : null,
            child: Container(
              width: double.infinity,
              height: 48,
              decoration: BoxDecoration(
                color: selectedSeatIds.isNotEmpty
                    ? AppTheme.brand
                    : AppTheme.brand.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.grid_view_rounded,
                      size: 18, color: Colors.white),
                  const SizedBox(width: 8),
                  Text(
                    'Assign ${selectedSeatIds.length} of ${pax.totalSeatsRequested} Seats',
                    style: GoogleFonts.inter(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Passenger Picker ──────────────────────────────────────────
class _PassengerPicker extends StatelessWidget {
  final List<Passenger> passengers;
  final ValueChanged<String> onSelected;

  const _PassengerPicker({
    required this.passengers,
    required this.onSelected,
  });

  String _initials(String name) {
    final parts = name.trim().split(RegExp(r'\s+'));
    if (parts.length >= 2) {
      return '${parts.first[0]}${parts.last[0]}'.toUpperCase();
    }
    return name.isNotEmpty ? name[0].toUpperCase() : '?';
  }

  Color _avatarColor(String name) {
    const colors = [
      AppTheme.brand,
      Color(0xFFD97706),
      AppTheme.success,
      Color(0xFF7C3AED),
      Color(0xFFDB2777),
      Color(0xFF0891B2),
    ];
    final hash = name.codeUnits.fold(0, (prev, c) => prev + c);
    return colors[hash % colors.length];
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.borderLight),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Select a passenger to assign',
            style: GoogleFonts.inter(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: AppTheme.textPrimary,
            ),
          ),
          const SizedBox(height: 12),
          ...passengers.map(
            (p) => Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: GestureDetector(
                onTap: () => onSelected(p.id),
                child: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: AppTheme.bgLight,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 30,
                        height: 30,
                        decoration: BoxDecoration(
                          color: _avatarColor(p.name),
                          shape: BoxShape.circle,
                        ),
                        child: Center(
                          child: Text(
                            _initials(p.name),
                            style: GoogleFonts.inter(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              p.displayName,
                              style: GoogleFonts.inter(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: AppTheme.textPrimary,
                              ),
                            ),
                            Text(
                              '${p.totalSeatsAssigned}/${p.totalSeatsRequested} assigned',
                              style: GoogleFonts.inter(
                                fontSize: 10,
                                color: AppTheme.textMuted,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const Icon(Icons.chevron_right_rounded,
                          size: 18, color: AppTheme.textMuted),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Info Chip ─────────────────────────────────────────────────
class _InfoChip extends StatelessWidget {
  final IconData? icon;
  final String label;

  const _InfoChip({this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: AppTheme.brandLight,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: AppTheme.brand),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: GoogleFonts.inter(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: AppTheme.brand,
            ),
          ),
        ],
      ),
    );
  }
}

// ── Empty State ───────────────────────────────────────────────
class _Empty extends StatelessWidget {
  final IconData icon;
  final String title;
  final String body;

  const _Empty({required this.icon, required this.title, required this.body});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 56,
              color: AppTheme.textMuted.withValues(alpha: 0.5),
            ),
            const SizedBox(height: 16),
            Text(
              title,
              style: GoogleFonts.inter(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: AppTheme.textPrimary,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              body,
              style: GoogleFonts.inter(
                fontSize: 13,
                color: AppTheme.textMuted,
                height: 1.4,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
