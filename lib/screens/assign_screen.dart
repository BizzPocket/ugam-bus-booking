import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:google_fonts/google_fonts.dart';
import '../config/theme.dart';
import '../controllers/tour_controller.dart';
import '../utils/app_snackbar.dart';
import '../models/tour.dart';
import '../models/tour_status.dart';
import 'seat_assignment_screen.dart';
import 'bus_list_screen.dart';
import 'handler_assignment_screen.dart';

class AssignScreen extends StatelessWidget {
  const AssignScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final tourCtrl = Get.find<TourController>();

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Text(
              'Assign',
              style: GoogleFonts.inter(
                fontSize: 28,
                fontWeight: FontWeight.w700,
                color: AppTheme.textPrimary,
              ),
            ),
            const SizedBox(height: 20),

            // Active Tour Selector
            Obx(() {
              final activeTours = tourCtrl.tours
                  .where((t) =>
                      t.status == TourStatus.assigning ||
                      t.status == TourStatus.booked)
                  .toList();

              if (activeTours.isEmpty) {
                return _EmptyState();
              }

              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'ACTIVE TOURS',
                    style: GoogleFonts.inter(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 1,
                      color: AppTheme.textMuted,
                    ),
                  ),
                  const SizedBox(height: 10),
                  ...activeTours.map((tour) => Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: _TourCard(tour: tour),
                      )),
                ],
              );
            }),
            const SizedBox(height: 24),

            // Quick Actions Section
            Text(
              'QUICK ACTIONS',
              style: GoogleFonts.inter(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                letterSpacing: 1,
                color: AppTheme.textMuted,
              ),
            ),
            const SizedBox(height: 10),
            _QuickActionCard(
              icon: Icons.grid_view_rounded,
              iconBgColor: AppTheme.brand,
              title: 'Seat Assignment',
              description: 'Assign seats to passengers on the bus layout',
              onTap: () {
                final tourCtrl = Get.find<TourController>();
                final activeTour = tourCtrl.tours.firstWhereOrNull((t) =>
                    t.status == TourStatus.assigning ||
                    t.status == TourStatus.booked);
                if (activeTour != null) {
                  Get.to(() => SeatAssignmentScreen(tourId: activeTour.id));
                } else {
                  AppSnackBar.warning('Create a tour and advance it to assigning status first.', title: 'No Active Tour');
                }
              },
            ),
            const SizedBox(height: 10),
            _QuickActionCard(
              icon: Icons.directions_bus_rounded,
              iconBgColor: AppTheme.brand,
              title: 'Manage Buses',
              description: 'Add, edit or remove buses from your fleet',
              onTap: () => Get.to(() => const BusListScreen()),
            ),
            const SizedBox(height: 10),
            _QuickActionCard(
              icon: Icons.shield_outlined,
              iconBgColor: AppTheme.brand,
              title: 'Assign Handler',
              description: 'Assign tour manager, driver and assistants',
              onTap: () {
                final tourCtrl = Get.find<TourController>();
                final activeTour = tourCtrl.tours.firstWhereOrNull((t) =>
                    t.status == TourStatus.assigning ||
                    t.status == TourStatus.booked);
                if (activeTour != null) {
                  Get.to(() => HandlerAssignmentScreen(tourId: activeTour.id));
                } else {
                  AppSnackBar.warning('Create a tour and add passengers first.', title: 'No Active Tour');
                }
              },
            ),
            const SizedBox(height: 24),

            // Recent Assignments
            Text(
              'RECENT ASSIGNMENTS',
              style: GoogleFonts.inter(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                letterSpacing: 1,
                color: AppTheme.textMuted,
              ),
            ),
            const SizedBox(height: 10),
            _RecentAssignmentsList(),
            const SizedBox(height: 100),
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.borderLight),
        boxShadow: AppTheme.cardShadow,
      ),
      child: Column(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: AppTheme.brandLight,
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: const Icon(
              Icons.event_seat_rounded,
              color: AppTheme.brand,
              size: 24,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'No Active Tours',
            style: GoogleFonts.inter(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: AppTheme.textPrimary,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Tours in "Booked" or "Assigning" status will appear here',
            textAlign: TextAlign.center,
            style: GoogleFonts.inter(
              fontSize: 13,
              color: AppTheme.textMuted,
            ),
          ),
        ],
      ),
    );
  }
}

class _TourCard extends StatelessWidget {
  final Tour tour;

  const _TourCard({required this.tour});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: AppTheme.borderLight),
        boxShadow: AppTheme.cardShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      tour.title,
                      style: GoogleFonts.inter(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: AppTheme.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      tour.route,
                      style: GoogleFonts.inter(
                        fontSize: 13,
                        color: AppTheme.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _formatDate(tour.departureDate),
                      style: GoogleFonts.inter(
                        fontSize: 12,
                        color: AppTheme.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              _StatusBadge(status: tour.status),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            height: 36,
            child: ElevatedButton.icon(
              onPressed: () {
                Get.to(() => SeatAssignmentScreen(tourId: tour.id));
              },
              icon: const Icon(Icons.grid_view_rounded, size: 16),
              label: Text(
                'Manage Seats',
                style: GoogleFonts.inter(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.brand,
                foregroundColor: Colors.white,
                elevation: 0,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(6),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _formatDate(DateTime date) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    return '${date.day} ${months[date.month - 1]} ${date.year}';
  }
}

class _StatusBadge extends StatelessWidget {
  final TourStatus status;

  const _StatusBadge({required this.status});

  @override
  Widget build(BuildContext context) {
    Color bg;
    Color fg;

    switch (status) {
      case TourStatus.assigning:
        bg = AppTheme.brandLight;
        fg = AppTheme.brand;
        break;
      case TourStatus.booked:
        bg = AppTheme.successLight;
        fg = AppTheme.success;
        break;
      default:
        bg = const Color(0xFFF1F5F9);
        fg = AppTheme.textMuted;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        status.displayName,
        style: GoogleFonts.inter(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: fg,
        ),
      ),
    );
  }
}

class _QuickActionCard extends StatelessWidget {
  final IconData icon;
  final Color iconBgColor;
  final String title;
  final String description;
  final VoidCallback onTap;

  const _QuickActionCard({
    required this.icon,
    required this.iconBgColor,
    required this.title,
    required this.description,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppTheme.borderLight),
          boxShadow: AppTheme.cardShadow,
        ),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: iconBgColor,
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: Icon(icon, size: 20, color: Colors.white),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: GoogleFonts.inter(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    description,
                    style: GoogleFonts.inter(
                      fontSize: 12,
                      color: AppTheme.textMuted,
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              Icons.chevron_right_rounded,
              size: 20,
              color: AppTheme.textMuted,
            ),
          ],
        ),
      ),
    );
  }
}

class _RecentAssignmentsList extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final tourCtrl = Get.find<TourController>();

    return Obx(() {
      // Collect passengers with assigned seats from all tours
      final assigned = <Map<String, String>>[];
      for (final tour in tourCtrl.tours) {
        for (final p in tour.passengers) {
          if (p.assignedSeats.isNotEmpty) {
            assigned.add({
              'name': p.name,
              'seats': p.assignedSeats.join(', '),
              'tour': tour.title,
            });
          }
        }
      }

      if (assigned.isEmpty) {
        return Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 14),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AppTheme.borderLight),
          ),
          child: Center(
            child: Text(
              'No seat assignments yet',
              style: GoogleFonts.inter(
                fontSize: 13,
                color: AppTheme.textMuted,
              ),
            ),
          ),
        );
      }

      // Show most recent first (last added = most recent)
      final display = assigned.reversed.take(10).toList();

      return Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppTheme.borderLight),
        ),
        child: Column(
          children: List.generate(display.length, (index) {
            final a = display[index];
            final name = a['name']!;
            final seats = a['seats']!;
            final tour = a['tour']!;
            return Column(
              children: [
                if (index > 0)
                  const Divider(height: 1, color: AppTheme.borderLight),
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  child: Row(
                    children: [
                      Container(
                        width: 32,
                        height: 32,
                        decoration: BoxDecoration(
                          color: AppTheme.brandLight,
                          shape: BoxShape.circle,
                        ),
                        alignment: Alignment.center,
                        child: Text(
                          name.split(' ').map((w) => w[0]).take(2).join(),
                          style: GoogleFonts.inter(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: AppTheme.brand,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              name,
                              style: GoogleFonts.inter(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: AppTheme.textPrimary,
                              ),
                            ),
                            Text(
                              'Seats: $seats',
                              style: GoogleFonts.inter(
                                fontSize: 12,
                                color: AppTheme.textMuted,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Text(
                        tour,
                        style: GoogleFonts.inter(
                          fontSize: 11,
                          color: AppTheme.textMuted,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            );
          }),
        ),
      );
    });
  }
}
