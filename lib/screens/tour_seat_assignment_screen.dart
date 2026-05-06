import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:google_fonts/google_fonts.dart';

import '../config/theme.dart';
import '../controllers/tour_controller.dart';
import '../models/bus_details.dart';
import '../models/passenger.dart';
import '../models/seat_assignment.dart';
import '../models/seat_layout.dart';
import '../models/seat_type.dart';
import '../models/tour.dart';
import '../models/tour_status.dart';
import '../utils/app_snackbar.dart';
import 'manage_buses_screen.dart';

/// Tour-scoped seat assignment. Mirrors the Pencil "Seat Assignment" screen:
/// bus tabs, deck tabs, visual seat grid, and a bottom card for the current
/// passenger being assigned.
class TourSeatAssignmentScreen extends StatefulWidget {
  final String tourId;

  const TourSeatAssignmentScreen({super.key, required this.tourId});

  @override
  State<TourSeatAssignmentScreen> createState() =>
      _TourSeatAssignmentScreenState();
}

class _TourSeatAssignmentScreenState extends State<TourSeatAssignmentScreen> {
  String? _selectedBusId;
  bool _showUpperDeck = false;
  String? _selectedPassengerId;

  TourController get _ctrl => Get.find<TourController>();

  Tour? get _tour => _ctrl.getTour(widget.tourId);

  Bus? _selectedBus(Tour tour) {
    if (tour.buses.isEmpty) return null;
    final id = _selectedBusId;
    if (id != null) {
      final match = tour.buses.where((b) => b.id == id).toList();
      if (match.isNotEmpty) return match.first;
    }
    return tour.buses.first;
  }

  Passenger? _selectedPassenger(Tour tour) {
    if (tour.passengers.isEmpty) return null;
    final id = _selectedPassengerId;
    if (id != null) {
      final match = tour.passengers.where((p) => p.id == id).toList();
      if (match.isNotEmpty) return match.first;
    }
    // Default to the first un- or partially-assigned passenger.
    final partial =
        tour.passengers.where((p) => !p.isFullyAssigned).toList();
    if (partial.isNotEmpty) return partial.first;
    return tour.passengers.first;
  }

  /// All seats assigned to anyone for the given bus.
  Map<String, String> _assignmentMap(Tour tour, String busId) {
    final map = <String, String>{};
    for (final p in tour.passengers) {
      for (final a in p.assignedSeats) {
        if (a.busId == busId) map[a.seatId] = p.id;
      }
    }
    return map;
  }

  /// Pending request lines for the passenger after subtracting what's
  /// already been assigned.
  List<_PendingLine> _pendingLines(Passenger passenger) {
    final pending = <_PendingLine>[];
    for (final line in passenger.requestLines) {
      pending.add(_PendingLine(
        seatType: line.seatType,
        position: line.position,
        remaining: line.qty,
        totalRequested: line.qty,
      ));
    }
    // Subtract already-assigned counts by walking decks.
    final tour = _tour;
    if (tour != null) {
      for (final assignment in passenger.assignedSeats) {
        final bus = tour.buses
            .where((b) => b.id == assignment.busId)
            .toList();
        if (bus.isEmpty) continue;
        final layout = bus.first.layout;
        if (layout == null) continue;
        SeatCell? cell;
        for (final c in layout.lowerDeck) {
          if (c.seatId == assignment.seatId) {
            cell = c;
            break;
          }
        }
        cell ??= layout.upperDeck
            .where((c) => c.seatId == assignment.seatId)
            .cast<SeatCell?>()
            .firstWhere((_) => true, orElse: () => null);
        if (cell == null) continue;
        final idx = pending.indexWhere(
          (l) =>
              l.seatType == cell!.seatType &&
              l.position == cell.position &&
              l.remaining > 0,
        );
        if (idx >= 0) {
          pending[idx] = pending[idx].copyDecremented();
        }
      }
    }
    return pending;
  }

  Future<void> _onSeatTapped(SeatCell cell, Bus bus, Tour tour) async {
    if (cell.isEmpty || cell.seatId == null) return;
    final passenger = _selectedPassenger(tour);
    if (passenger == null) {
      AppSnackBar.error('No passengers to assign — add one first.');
      return;
    }

    final assignmentMap = _assignmentMap(tour, bus.id);
    final ownerId = assignmentMap[cell.seatId];

    // Tap on own assigned seat → unassign it.
    if (ownerId == passenger.id) {
      final next = List<SeatAssignment>.from(passenger.assignedSeats)
        ..removeWhere(
            (a) => a.busId == bus.id && a.seatId == cell.seatId);
      await _ctrl.assignSeats(tour.id, passenger.id, next);
      return;
    }

    // Tap on someone else's seat → ask before reassigning.
    if (ownerId != null) {
      final other = tour.passengers
          .where((p) => p.id == ownerId)
          .toList()
          .firstOrNull;
      AppSnackBar.warning(
        '${cell.seatId} is currently with '
        '${other?.name ?? 'another passenger'}. '
        'Unassign there before reassigning.',
      );
      return;
    }

    // Free seat. Check it matches a pending request line.
    final pending = _pendingLines(passenger);
    final matchIdx = pending.indexWhere((l) =>
        l.seatType == cell.seatType &&
        l.position == cell.position &&
        l.remaining > 0);
    if (matchIdx < 0) {
      AppSnackBar.warning(
        '${passenger.name} did not request a '
        '${seatTypeLabel(cell.seatType!, cell.position)}. '
        'Edit their request first.',
      );
      return;
    }

    final next = List<SeatAssignment>.from(passenger.assignedSeats)
      ..add(SeatAssignment(busId: bus.id, seatId: cell.seatId!));
    await _ctrl.assignSeats(tour.id, passenger.id, next);

    // Auto-advance to next unassigned passenger when current is done.
    final updatedPassenger = _ctrl
        .getTour(tour.id)
        ?.passengers
        .firstWhere((p) => p.id == passenger.id, orElse: () => passenger);
    if (updatedPassenger != null && updatedPassenger.isFullyAssigned) {
      final nextUnassigned = _ctrl
          .getTour(tour.id)!
          .passengers
          .where((p) => !p.isFullyAssigned)
          .toList();
      if (nextUnassigned.isNotEmpty) {
        setState(() => _selectedPassengerId = nextUnassigned.first.id);
      }
    }
  }

  Future<void> _lockTour(Tour tour) async {
    if (!tour.allSeatsAssigned) {
      AppSnackBar.error('All passengers must be fully assigned first.');
      return;
    }
    if (tour.handlerId == null) {
      AppSnackBar.error('Pick a handler before locking.');
      return;
    }
    await _ctrl.lockTour(tour.id);
    AppSnackBar.success('Tour locked. Notifications next.');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      body: SafeArea(
        child: Obx(() {
          final tour = _tour;
          if (tour == null) {
            return const Center(child: Text('Tour not found'));
          }
          if (tour.buses.isEmpty) {
            return _NoBuses(tourId: widget.tourId);
          }
          if (tour.passengers.isEmpty) {
            return _NoPassengers();
          }

          final bus = _selectedBus(tour)!;
          final passenger = _selectedPassenger(tour);
          final assignmentMap = _assignmentMap(tour, bus.id);

          return Column(
            children: [
              _Header(
                title: 'Seat Assignment',
                tourId: widget.tourId,
              ),
              _Subtitle(tour: tour),
              const SizedBox(height: 12),
              _BusTabs(
                buses: tour.buses,
                selectedBusId: bus.id,
                seatsAssignedFor: (id) => _assignmentMap(tour, id).length,
                onTap: (id) {
                  setState(() {
                    _selectedBusId = id;
                    _showUpperDeck = false;
                  });
                },
              ),
              const SizedBox(height: 10),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: _BusHeader(
                  bus: bus,
                  assignedSeats: assignmentMap.length,
                ),
              ),
              const SizedBox(height: 10),
              if (bus.layout?.upperDeck.any((c) => c.hasSeat) ?? false)
                _DeckTabs(
                  showUpperDeck: _showUpperDeck,
                  onChanged: (v) => setState(() => _showUpperDeck = v),
                ),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                  physics: const BouncingScrollPhysics(),
                  child: Column(
                    children: [
                      _SeatGrid(
                        layout: bus.layout,
                        showUpper: _showUpperDeck,
                        assignmentMap: assignmentMap,
                        currentPassengerId: passenger?.id,
                        onTap: (cell) => _onSeatTapped(cell, bus, tour),
                      ),
                      const SizedBox(height: 14),
                      _Legend(),
                    ],
                  ),
                ),
              ),
              if (passenger != null)
                _PassengerCard(
                  passenger: passenger,
                  pending: _pendingLines(passenger),
                  allPassengers: tour.passengers,
                  onChange: (id) =>
                      setState(() => _selectedPassengerId = id),
                  onLockTour: tour.status == TourStatus.assigning &&
                          tour.allSeatsAssigned
                      ? () => _lockTour(tour)
                      : null,
                ),
            ],
          );
        }),
      ),
    );
  }
}

class _PendingLine {
  final SeatType seatType;
  final SeatPosition? position;
  final int remaining;
  final int totalRequested;

  const _PendingLine({
    required this.seatType,
    this.position,
    required this.remaining,
    required this.totalRequested,
  });

  _PendingLine copyDecremented() => _PendingLine(
        seatType: seatType,
        position: position,
        remaining: remaining > 0 ? remaining - 1 : 0,
        totalRequested: totalRequested,
      );

  String get label => seatTypeLabel(seatType, position);

  String get progress => '${totalRequested - remaining}/$totalRequested';
}

class _Header extends StatelessWidget {
  final String title;
  final String tourId;
  const _Header({required this.title, required this.tourId});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 16, 4),
      child: Row(
        children: [
          IconButton(
            icon: Icon(Icons.arrow_back, color: theme.colorScheme.onSurface),
            onPressed: () => Get.back(),
          ),
          Expanded(
            child: Text(
              title,
              style: GoogleFonts.inter(
                fontSize: 19,
                fontWeight: FontWeight.w700,
                color: theme.colorScheme.onSurface,
              ),
            ),
          ),
          GestureDetector(
            onTap: () => Get.to(() => ManageBusesScreen(tourId: tourId)),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
              child: Text(
                'Fleet',
                style: GoogleFonts.inter(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.brand,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Subtitle extends StatelessWidget {
  final Tour tour;
  const _Subtitle({required this.tour});

  @override
  Widget build(BuildContext context) {
    final assigned = tour.totalSeatsAssigned;
    final capacity = tour.totalBusSeats;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          '${tour.title} · ${tour.buses.length} '
          '${tour.buses.length == 1 ? 'Bus' : 'Buses'} · '
          '$assigned/$capacity Seats Assigned',
          style: GoogleFonts.inter(
            fontSize: 12,
            color: AppTheme.textMuted,
          ),
        ),
      ),
    );
  }
}

class _BusTabs extends StatelessWidget {
  final List<Bus> buses;
  final String selectedBusId;
  final int Function(String) seatsAssignedFor;
  final ValueChanged<String> onTap;

  const _BusTabs({
    required this.buses,
    required this.selectedBusId,
    required this.seatsAssignedFor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 60,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        scrollDirection: Axis.horizontal,
        itemCount: buses.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (ctx, i) {
          final bus = buses[i];
          final selected = bus.id == selectedBusId;
          final assigned = seatsAssignedFor(bus.id);
          final capacity = bus.totalSeats;
          return GestureDetector(
            onTap: () => onTap(bus.id),
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 14,
                vertical: 10,
              ),
              decoration: BoxDecoration(
                color: selected ? AppTheme.brand : Colors.white,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: selected ? AppTheme.brand : AppTheme.borderLight,
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    bus.name,
                    style: GoogleFonts.inter(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: selected ? Colors.white : AppTheme.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '$assigned/$capacity ${bus.isAC ? 'AC' : 'Non-AC'}',
                    style: GoogleFonts.inter(
                      fontSize: 10,
                      color: selected
                          ? Colors.white.withValues(alpha: 0.8)
                          : AppTheme.textMuted,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _BusHeader extends StatelessWidget {
  final Bus bus;
  final int assignedSeats;

  const _BusHeader({required this.bus, required this.assignedSeats});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final capacity = bus.totalSeats;
    final percent =
        capacity > 0 ? ((assignedSeats / capacity) * 100).round() : 0;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.brandLight,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.brand.withValues(alpha: 0.18)),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.directions_bus_rounded,
            size: 18,
            color: AppTheme.brand,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '${bus.busNumber} · ${bus.isAC ? 'AC' : 'Non-AC'} '
                  '${bus.busTypeEnum.displayName}',
                  style: GoogleFonts.inter(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.brandDark,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  'Driver: ${bus.driverName.isEmpty ? '—' : bus.driverName}',
                  style: GoogleFonts.inter(
                    fontSize: 11,
                    color: isDark ? Colors.white70 : AppTheme.textSecondary,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '$assignedSeats/$capacity',
                style: GoogleFonts.inter(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: AppTheme.brandDark,
                ),
              ),
              Text(
                '$percent% full',
                style: GoogleFonts.inter(
                  fontSize: 10,
                  color: AppTheme.textMuted,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _DeckTabs extends StatelessWidget {
  final bool showUpperDeck;
  final ValueChanged<bool> onChanged;

  const _DeckTabs({required this.showUpperDeck, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          Expanded(
            child: _DeckTab(
              label: 'Lower Deck',
              selected: !showUpperDeck,
              onTap: () => onChanged(false),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _DeckTab(
              label: 'Upper Deck',
              selected: showUpperDeck,
              onTap: () => onChanged(true),
            ),
          ),
        ],
      ),
    );
  }
}

class _DeckTab extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _DeckTab({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 38,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? AppTheme.brand : Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected ? AppTheme.brand : AppTheme.borderLight,
          ),
        ),
        child: Text(
          label,
          style: GoogleFonts.inter(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: selected ? Colors.white : AppTheme.textPrimary,
          ),
        ),
      ),
    );
  }
}

class _SeatGrid extends StatelessWidget {
  final BusLayout? layout;
  final bool showUpper;
  final Map<String, String> assignmentMap;
  final String? currentPassengerId;
  final ValueChanged<SeatCell> onTap;

  const _SeatGrid({
    required this.layout,
    required this.showUpper,
    required this.assignmentMap,
    required this.currentPassengerId,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final l = layout;
    if (l == null) {
      return _NoLayout();
    }
    final cells = showUpper ? l.upperDeck : l.lowerDeck;
    final seatCells = cells.where((c) => c.hasSeat).toList();
    if (seatCells.isEmpty) {
      return _NoLayout();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            const Icon(
              Icons.person_outline_rounded,
              size: 14,
              color: AppTheme.textMuted,
            ),
            const SizedBox(width: 4),
            Text(
              showUpper ? 'UPPER' : 'DRIVER',
              style: GoogleFonts.inter(
                fontSize: 9,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.8,
                color: AppTheme.textMuted,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: AppTheme.borderLight),
          ),
          child: GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 4,
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
              childAspectRatio: 1.1,
            ),
            itemCount: seatCells.length,
            itemBuilder: (ctx, i) {
              final cell = seatCells[i];
              final ownerId = assignmentMap[cell.seatId];
              final isMine =
                  ownerId != null && ownerId == currentPassengerId;
              final isOther = ownerId != null && ownerId != currentPassengerId;
              return _SeatTile(
                cell: cell,
                isMine: isMine,
                isOther: isOther,
                onTap: () => onTap(cell),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _SeatTile extends StatelessWidget {
  final SeatCell cell;
  final bool isMine;
  final bool isOther;
  final VoidCallback onTap;

  const _SeatTile({
    required this.cell,
    required this.isMine,
    required this.isOther,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    Color bg;
    Color border;
    Color textColor;
    if (isMine) {
      bg = AppTheme.brandAccent;
      border = AppTheme.brandAccent;
      textColor = Colors.white;
    } else if (isOther) {
      bg = const Color(0xFFE5E7EB);
      border = const Color(0xFFD1D5DB);
      textColor = AppTheme.textSecondary;
    } else {
      bg = AppTheme.brand;
      border = AppTheme.brand;
      textColor = Colors.white;
    }
    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: border),
        ),
        alignment: Alignment.center,
        child: Text(
          cell.seatId ?? '',
          style: GoogleFonts.inter(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: textColor,
          ),
        ),
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _LegendDot(color: Colors.white, border: AppTheme.borderLight, label: 'Available'),
        const SizedBox(width: 16),
        _LegendDot(color: const Color(0xFFE5E7EB), border: const Color(0xFFD1D5DB), label: 'Booked'),
        const SizedBox(width: 16),
        _LegendDot(color: AppTheme.brandAccent, border: AppTheme.brandAccent, label: 'Selected'),
      ],
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
      children: [
        Container(
          width: 14,
          height: 14,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(3),
            border: Border.all(color: border),
          ),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: GoogleFonts.inter(fontSize: 11, color: AppTheme.textMuted),
        ),
      ],
    );
  }
}

class _PassengerCard extends StatelessWidget {
  final Passenger passenger;
  final List<_PendingLine> pending;
  final List<Passenger> allPassengers;
  final ValueChanged<String> onChange;
  final VoidCallback? onLockTour;

  const _PassengerCard({
    required this.passenger,
    required this.pending,
    required this.allPassengers,
    required this.onChange,
    required this.onLockTour,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final selectedSeats = passenger.assignedSeats.isEmpty
        ? '—'
        : passenger.assignedSeats.map((a) => a.seatId).join(', ');
    final stillNeeded =
        pending.fold<int>(0, (sum, l) => sum + l.remaining);

    return Container(
      decoration: BoxDecoration(
        color: isDark ? AppTheme.cardDark : Colors.white,
        border: Border(top: BorderSide(color: AppTheme.borderLight)),
      ),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Passenger picker (horizontal chips).
          SizedBox(
            height: 30,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: allPassengers.length,
              separatorBuilder: (_, _) => const SizedBox(width: 6),
              itemBuilder: (ctx, i) {
                final p = allPassengers[i];
                final selected = p.id == passenger.id;
                return GestureDetector(
                  onTap: () => onChange(p.id),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: selected ? AppTheme.brand : AppTheme.bgLight,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: selected
                            ? AppTheme.brand
                            : AppTheme.borderLight,
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (p.isFullyAssigned)
                          Padding(
                            padding: const EdgeInsets.only(right: 4),
                            child: Icon(
                              Icons.check_circle_rounded,
                              size: 12,
                              color:
                                  selected ? Colors.white : AppTheme.success,
                            ),
                          ),
                        Text(
                          p.name,
                          style: GoogleFonts.inter(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: selected
                                ? Colors.white
                                : AppTheme.textPrimary,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              CircleAvatar(
                radius: 16,
                backgroundColor: AppTheme.brandLight,
                child: Text(
                  passenger.name.isNotEmpty
                      ? passenger.name[0].toUpperCase()
                      : '?',
                  style: GoogleFonts.inter(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.brand,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      passenger.name,
                      style: GoogleFonts.inter(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: theme.colorScheme.onSurface,
                      ),
                    ),
                    if (passenger.phone.isNotEmpty)
                      Text(
                        passenger.phone,
                        style: GoogleFonts.inter(
                          fontSize: 11,
                          color: AppTheme.textMuted,
                        ),
                      ),
                  ],
                ),
              ),
              Text(
                '${passenger.totalSeatsAssigned}/${passenger.totalSeatsRequested}',
                style: GoogleFonts.inter(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: theme.colorScheme.onSurface,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: pending.map((line) {
              return Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: AppTheme.bgLight,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  '${line.label}  ${line.progress}',
                  style: GoogleFonts.inter(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    color: line.remaining == 0
                        ? AppTheme.success
                        : AppTheme.textPrimary,
                  ),
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Text(
                  'Seats: $selectedSeats',
                  style: GoogleFonts.inter(
                    fontSize: 12,
                    color: AppTheme.textSecondary,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (stillNeeded > 0)
                Text(
                  '$stillNeeded more needed',
                  style: GoogleFonts.inter(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.warning,
                  ),
                ),
            ],
          ),
          if (onLockTour != null) ...[
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              height: 44,
              child: ElevatedButton.icon(
                onPressed: onLockTour,
                icon: const Icon(Icons.lock_rounded, size: 16),
                label: const Text('Lock Tour & Notify'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.success,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _NoBuses extends StatelessWidget {
  final String tourId;
  const _NoBuses({required this.tourId});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.directions_bus_outlined,
              size: 56,
              color: AppTheme.textMuted,
            ),
            const SizedBox(height: 14),
            Text(
              'No buses on this tour yet',
              style: GoogleFonts.inter(
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Add at least one bus before assigning seats.',
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(
                fontSize: 12,
                color: AppTheme.textMuted,
              ),
            ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: () => Get.to(
                () => ManageBusesScreen(tourId: tourId),
              ),
              icon: const Icon(Icons.add_rounded, size: 18),
              label: const Text('Add Bus'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.brand,
                foregroundColor: Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NoPassengers extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.people_outline_rounded,
              size: 56,
              color: AppTheme.textMuted,
            ),
            const SizedBox(height: 14),
            Text(
              'No passengers yet',
              style: GoogleFonts.inter(
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Once customers submit requests for this tour, they appear here.',
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(
                fontSize: 12,
                color: AppTheme.textMuted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NoLayout extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 32),
      alignment: Alignment.center,
      child: Text(
        'This bus has no seat layout — open the bus to add one.',
        textAlign: TextAlign.center,
        style: GoogleFonts.inter(fontSize: 12, color: AppTheme.textMuted),
      ),
    );
  }
}
