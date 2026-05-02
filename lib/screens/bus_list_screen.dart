import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:google_fonts/google_fonts.dart';
import '../config/theme.dart';
import '../controllers/tour_controller.dart';
import '../utils/app_snackbar.dart';
import 'add_bus_form_screen.dart';

/// Unified bus display data used for both real and fallback buses.
class _BusDisplayData {
  final String id;
  final String name;
  final String driverName;
  final bool isAc;
  final String type;
  final int totalSeats;
  final int assignedSeats;

  const _BusDisplayData({
    required this.id,
    required this.name,
    required this.driverName,
    required this.isAc,
    required this.type,
    required this.totalSeats,
    required this.assignedSeats,
  });
}

class BusListScreen extends StatelessWidget {
  const BusListScreen({super.key});

  // Fallback data shown when no tours have bus details
  static const List<_BusDisplayData> _fallbackBuses = [
    _BusDisplayData(
      id: 'BUS-001',
      name: 'GJ-05-AB-1234',
      driverName: 'Ramesh Patel',
      isAc: true,
      type: 'Sleeper',
      totalSeats: 45,
      assignedSeats: 32,
    ),
    _BusDisplayData(
      id: 'BUS-002',
      name: 'GJ-05-CD-5678',
      driverName: 'Suresh Kumar',
      isAc: true,
      type: 'Seater',
      totalSeats: 52,
      assignedSeats: 52,
    ),
    _BusDisplayData(
      id: 'BUS-003',
      name: 'GJ-01-EF-9012',
      driverName: 'Mahesh Singh',
      isAc: false,
      type: 'Mixed',
      totalSeats: 40,
      assignedSeats: 18,
    ),
    _BusDisplayData(
      id: 'BUS-004',
      name: 'GJ-03-GH-3456',
      driverName: 'Dinesh Sharma',
      isAc: true,
      type: 'Sleeper',
      totalSeats: 36,
      assignedSeats: 0,
    ),
  ];

  /// Build display data from tours that have busDetails attached.
  List<_BusDisplayData> _busesFromTours(TourController tourCtrl) {
    final List<_BusDisplayData> result = [];
    for (final tour in tourCtrl.tours) {
      final bd = tour.busDetails;
      if (bd != null) {
        result.add(_BusDisplayData(
          id: bd.id,
          name: bd.busNumber,
          driverName: bd.driverName,
          isAc: bd.isAC,
          type: bd.busType,
          totalSeats: bd.totalSeats,
          assignedSeats: tour.totalSeatsAssigned,
        ));
      }
    }
    return result;
  }

  @override
  Widget build(BuildContext context) {
    final tourCtrl = Get.find<TourController>();

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: SafeArea(
        child: Obx(() {
          final realBuses = _busesFromTours(tourCtrl);
          final buses = realBuses.isNotEmpty ? realBuses : _fallbackBuses;
          final bool usingFallback = realBuses.isEmpty;

          final int totalBuses = buses.length;
          final int totalSeats = buses.fold(0, (sum, b) => sum + b.totalSeats);
          final int totalAssigned = buses.fold(0, (sum, b) => sum + b.assignedSeats);

          // Try to get a subtitle from the first active tour
          String subtitle = 'Your fleet';
          final activeTour = tourCtrl.tours.firstWhereOrNull(
            (t) => t.status.name != 'completed',
          );
          if (activeTour != null) {
            final months = [
              'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
              'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
            ];
            final dep = activeTour.departureDate;
            subtitle = '${activeTour.title} · ${months[dep.month - 1]} ${dep.day}';
            if (activeTour.returnDate != null) {
              subtitle += '–${activeTour.returnDate!.day}';
            }
          }

          return Column(
            children: [
              // -- Header --
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                child: Row(
                  children: [
                    _buildBackButton(),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Manage Buses',
                            style: GoogleFonts.inter(
                              fontSize: 20,
                              fontWeight: FontWeight.w700,
                              color: AppTheme.textPrimary,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            subtitle,
                            style: GoogleFonts.inter(
                              fontSize: 13,
                              fontWeight: FontWeight.w400,
                              color: AppTheme.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 16),

              // Fallback banner
              if (usingFallback)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    margin: const EdgeInsets.only(bottom: 12),
                    decoration: BoxDecoration(
                      color: AppTheme.warningLight,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      'Showing sample buses - add bus details to your tours',
                      style: GoogleFonts.inter(
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                        color: AppTheme.warning,
                      ),
                    ),
                  ),
                ),

              // -- Summary Bar --
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(
                    color: const Color(0xFFEFF6FF),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.directions_bus_filled_rounded,
                        size: 18,
                        color: AppTheme.brand,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '$totalBuses Buses · $totalSeats Total Seats · $totalAssigned Assigned',
                          style: GoogleFonts.inter(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: AppTheme.brand,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 16),

              // -- Bus Cards List --
              Expanded(
                child: ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  itemCount: buses.length,
                  itemBuilder: (_, index) {
                    final bus = buses[index];
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: _buildBusCard(bus),
                    );
                  },
                ),
              ),

              // -- Add New Bus Button --
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: GestureDetector(
                  onTap: () {
                    Get.to(() => const AddBusFormScreen());
                  },
                  child: Container(
                    width: double.infinity,
                    height: 52,
                    decoration: BoxDecoration(
                      color: AppTheme.brand,
                      borderRadius: BorderRadius.circular(4),
                      boxShadow: AppTheme.brandShadow,
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.add_rounded, size: 20, color: Colors.white),
                        const SizedBox(width: 8),
                        Text(
                          'Add New Bus',
                          style: GoogleFonts.inter(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            color: Colors.white,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),

              // -- Bottom padding for nav bar --
              const SizedBox(height: 80),
            ],
          );
        }),
      ),
    );
  }

  Widget _buildBackButton() {
    return GestureDetector(
      onTap: () => Get.back(),
      child: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: Colors.white,
          shape: BoxShape.circle,
          boxShadow: AppTheme.subtleShadow,
        ),
        child: const Icon(
          Icons.arrow_back_rounded,
          size: 18,
          color: AppTheme.textPrimary,
        ),
      ),
    );
  }

  void _showEditBusDialog(_BusDisplayData bus) {
    final nameCtrl = TextEditingController(text: bus.name);
    final driverCtrl = TextEditingController(text: bus.driverName);

    Get.dialog(
      AlertDialog(
        title: Text(
          'Edit Bus',
          style: GoogleFonts.inter(
            fontWeight: FontWeight.w700,
            fontSize: 18,
            color: AppTheme.textPrimary,
          ),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtrl,
              decoration: InputDecoration(
                labelText: 'Bus Number',
                labelStyle: GoogleFonts.inter(
                  fontSize: 13,
                  color: AppTheme.textSecondary,
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: driverCtrl,
              decoration: InputDecoration(
                labelText: 'Driver Name',
                labelStyle: GoogleFonts.inter(
                  fontSize: 13,
                  color: AppTheme.textSecondary,
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Get.back(),
            child: Text(
              'Cancel',
              style: GoogleFonts.inter(color: AppTheme.textSecondary),
            ),
          ),
          TextButton(
            onPressed: () {
              Get.back();
              AppSnackBar.success('Bus "${nameCtrl.text}" updated');
            },
            child: Text(
              'Save',
              style: GoogleFonts.inter(
                color: AppTheme.brand,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBusCard(_BusDisplayData bus) {
    final double occupancyPercent =
        bus.totalSeats > 0 ? bus.assignedSeats / bus.totalSeats : 0.0;

    Color progressColor;
    if (occupancyPercent >= 1.0) {
      progressColor = AppTheme.success;
    } else if (occupancyPercent >= 0.7) {
      progressColor = AppTheme.warning;
    } else if (occupancyPercent > 0) {
      progressColor = AppTheme.brand;
    } else {
      progressColor = AppTheme.textMuted;
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(6),
        boxShadow: AppTheme.cardShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // -- Top row: icon + name/driver + edit --
          Row(
            children: [
              Icon(
                Icons.directions_bus_filled_rounded,
                size: 20,
                color: AppTheme.brand,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      bus.name,
                      style: GoogleFonts.inter(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: AppTheme.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      bus.driverName,
                      style: GoogleFonts.inter(
                        fontSize: 13,
                        fontWeight: FontWeight.w400,
                        color: AppTheme.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              GestureDetector(
                onTap: () {
                  _showEditBusDialog(bus);
                },
                child: Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: AppTheme.bgLight,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.edit_outlined,
                    size: 16,
                    color: AppTheme.textSecondary,
                  ),
                ),
              ),
            ],
          ),

          const SizedBox(height: 12),

          // -- Badge row: AC pill + type pill --
          Row(
            children: [
              if (bus.isAc)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: AppTheme.successLight,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    'AC',
                    style: GoogleFonts.inter(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.success,
                    ),
                  ),
                ),
              if (bus.isAc) const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: const Color(0xFFEFF6FF),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  bus.type,
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

          // -- Occupancy row --
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Occupancy',
                style: GoogleFonts.inter(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: AppTheme.textMuted,
                ),
              ),
              Text(
                '${bus.assignedSeats}/${bus.totalSeats} seats',
                style: GoogleFonts.inter(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.textSecondary,
                ),
              ),
            ],
          ),

          const SizedBox(height: 6),

          // -- Progress bar --
          Container(
            height: 6,
            width: double.infinity,
            decoration: BoxDecoration(
              color: AppTheme.borderLight,
              borderRadius: BorderRadius.circular(3),
            ),
            child: FractionallySizedBox(
              alignment: Alignment.centerLeft,
              widthFactor: occupancyPercent.clamp(0.0, 1.0),
              child: Container(
                decoration: BoxDecoration(
                  color: progressColor,
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
