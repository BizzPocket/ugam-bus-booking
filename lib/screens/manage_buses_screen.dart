import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:google_fonts/google_fonts.dart';

import '../config/theme.dart';
import '../controllers/tour_controller.dart';
import '../models/bus_details.dart';
import '../models/tour.dart';
import 'add_bus_screen.dart';

/// List of buses attached to a tour. Mirrors the Pencil "Manage Buses"
/// screen: header with tour context, capacity tally, and a card per bus
/// with occupancy bar.
class ManageBusesScreen extends StatelessWidget {
  final String tourId;

  const ManageBusesScreen({super.key, required this.tourId});

  TourController get _tourCtrl => Get.find<TourController>();

  String _formatDateRange(Tour tour) {
    final months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    final dep = tour.departureDate;
    var label = '${months[dep.month - 1]} ${dep.day}';
    if (tour.returnDate != null) {
      label += '–${tour.returnDate!.day}';
    }
    return label;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      body: SafeArea(
        child: Obx(() {
          final tour = _tourCtrl.getTour(tourId);
          if (tour == null) {
            return const Center(child: Text('Tour not found'));
          }

          final assigned = tour.totalSeatsAssigned;
          final totalCapacity = tour.totalBusSeats;

          return Column(
            children: [
              _Header(
                title: tour.title,
                subtitle: _formatDateRange(tour),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                child: _Tally(
                  busCount: tour.buses.length,
                  totalSeats: totalCapacity,
                  assignedSeats: assigned,
                ),
              ),
              Expanded(
                child: tour.buses.isEmpty
                    ? const _EmptyState()
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                        itemCount: tour.buses.length,
                        itemBuilder: (ctx, i) {
                          final bus = tour.buses[i];
                          final assignedForBus = _seatsAssignedForBus(
                            tour,
                            bus.id,
                          );
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: _BusCard(
                              bus: bus,
                              assigned: assignedForBus,
                              onEdit: () {
                                // Edit flow lands in a later phase.
                              },
                            ),
                          );
                        },
                      ),
              ),
            ],
          );
        }),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => Get.to(() => AddBusScreen(tourId: tourId)),
        icon: const Icon(Icons.add_rounded),
        label: const Text('Add Bus'),
        backgroundColor: AppTheme.brand,
        foregroundColor: Colors.white,
      ),
    );
  }

  int _seatsAssignedForBus(Tour tour, String busId) {
    return tour.passengers.fold<int>(
      0,
      (sum, p) =>
          sum + p.assignedSeats.where((a) => a.busId == busId).length,
    );
  }
}

class _Header extends StatelessWidget {
  final String title;
  final String subtitle;

  const _Header({required this.title, required this.subtitle});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 20, 0),
      child: Row(
        children: [
          IconButton(
            icon: Icon(Icons.arrow_back, color: theme.colorScheme.onSurface),
            onPressed: () => Get.back(),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Manage Buses',
                  style: GoogleFonts.inter(
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
                Text(
                  '$title · $subtitle',
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
  final int busCount;
  final int totalSeats;
  final int assignedSeats;

  const _Tally({
    required this.busCount,
    required this.totalSeats,
    required this.assignedSeats,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppTheme.brandLight,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.directions_bus_rounded,
            size: 16,
            color: AppTheme.brand,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '$busCount ${busCount == 1 ? 'Bus' : 'Buses'} · '
              '$totalSeats Total Seats · '
              '$assignedSeats Assigned',
              style: GoogleFonts.inter(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: AppTheme.brandDark,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.directions_bus_outlined,
              size: 56,
              color: AppTheme.textMuted.withValues(alpha: 0.5),
            ),
            const SizedBox(height: 16),
            Text(
              'No buses yet',
              style: GoogleFonts.inter(
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Once your bus owner confirms, tap "Add Bus" to enter '
              'the driver and seat details.',
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(
                fontSize: 13,
                color: AppTheme.textMuted,
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BusCard extends StatelessWidget {
  final Bus bus;
  final int assigned;
  final VoidCallback onEdit;

  const _BusCard({
    required this.bus,
    required this.assigned,
    required this.onEdit,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final capacity = bus.totalSeats;
    final ratio = capacity > 0 ? (assigned / capacity).clamp(0.0, 1.0) : 0.0;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.cardDark : Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isDark ? AppTheme.borderDark : AppTheme.borderLight,
        ),
        boxShadow: isDark ? [] : AppTheme.subtleShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 36,
                height: 36,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: AppTheme.brandLight,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(
                  Icons.directions_bus_rounded,
                  size: 18,
                  color: AppTheme.brand,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Bus #${bus.busNumber.isEmpty ? '—' : bus.busNumber}',
                      style: GoogleFonts.inter(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: theme.colorScheme.onSurface,
                      ),
                    ),
                    if (bus.driverName.isNotEmpty)
                      Text(
                        bus.driverName,
                        style: GoogleFonts.inter(
                          fontSize: 12,
                          color: AppTheme.textMuted,
                        ),
                      ),
                  ],
                ),
              ),
              IconButton(
                onPressed: onEdit,
                visualDensity: VisualDensity.compact,
                icon: Icon(
                  Icons.edit_outlined,
                  size: 18,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              _Tag(
                label: bus.isAC ? 'AC' : 'Non-AC',
                color: bus.isAC ? AppTheme.success : AppTheme.warning,
              ),
              const SizedBox(width: 6),
              _Tag(
                label: bus.busTypeEnum.displayName,
                color: AppTheme.brand,
              ),
            ],
          ),
          const SizedBox(height: 12),
          _OccupancyBar(ratio: ratio),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Occupancy',
                style: GoogleFonts.inter(
                  fontSize: 11,
                  color: AppTheme.textMuted,
                ),
              ),
              Text(
                '$assigned/$capacity seats',
                style: GoogleFonts.inter(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: theme.colorScheme.onSurface,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  final String label;
  final Color color;

  const _Tag({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: GoogleFonts.inter(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          color: color,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}

class _OccupancyBar extends StatelessWidget {
  final double ratio;

  const _OccupancyBar({required this.ratio});

  @override
  Widget build(BuildContext context) {
    final color = ratio < 0.5
        ? AppTheme.success
        : ratio < 0.85
            ? AppTheme.warning
            : AppTheme.danger;
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: LinearProgressIndicator(
        value: ratio,
        minHeight: 6,
        backgroundColor: AppTheme.borderLight,
        valueColor: AlwaysStoppedAnimation<Color>(color),
      ),
    );
  }
}
