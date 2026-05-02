import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:google_fonts/google_fonts.dart';

import '../config/theme.dart';
import '../controllers/tour_controller.dart';
import '../models/tour.dart';
import '../models/passenger.dart';
import '../models/payment_status.dart';
import '../utils/app_dialogs.dart';
import '../utils/app_snackbar.dart';

// ── Screen ───────────────────────────────────────────────────────────────────

class RequestsScreen extends StatefulWidget {
  const RequestsScreen({super.key});

  @override
  State<RequestsScreen> createState() => _RequestsScreenState();
}

class _RequestsScreenState extends State<RequestsScreen> {
  int _selectedTourIndex = 0;

  @override
  Widget build(BuildContext context) {
    final tourCtrl = Get.find<TourController>();

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: SafeArea(
        child: Obx(() {
          final activeTours = tourCtrl.activeTours;

          if (activeTours.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(40),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.inbox_rounded,
                        size: 48, color: AppTheme.textMuted),
                    const SizedBox(height: 16),
                    Text(
                      'No Active Tours',
                      style: GoogleFonts.inter(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                        color: AppTheme.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Create a tour first to manage passenger requests.',
                      textAlign: TextAlign.center,
                      style: GoogleFonts.inter(
                        fontSize: 14,
                        color: AppTheme.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
            );
          }

          // Clamp index
          if (_selectedTourIndex >= activeTours.length) {
            _selectedTourIndex = 0;
          }

          final selectedTour = activeTours[_selectedTourIndex];
          final passengers = selectedTour.passengers;

          final newCount =
              passengers.where((p) => !p.isSeatsAssigned).length;
          final assignedCount =
              passengers.where((p) => p.isSeatsAssigned).length;
          final paidCount =
              passengers.where((p) => p.paymentStatus == PaymentStatus.paid).length;

          return Column(
            children: [
              // ── Header ───────────────────────────────────────────────
              Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: 20, vertical: 16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Requests',
                      style: GoogleFonts.inter(
                        fontSize: 28,
                        fontWeight: FontWeight.w700,
                        color: AppTheme.textPrimary,
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 8),
                      decoration: BoxDecoration(
                        color: AppTheme.brandLight,
                        borderRadius: BorderRadius.circular(9999),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.people_outline,
                              size: 16, color: AppTheme.brand),
                          const SizedBox(width: 6),
                          Text(
                            '${passengers.length} total',
                            style: GoogleFonts.inter(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: AppTheme.brand,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),

              // ── Tour Selector Chips ──────────────────────────────────
              SizedBox(
                height: 36,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  itemCount: activeTours.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 8),
                  itemBuilder: (_, i) {
                    final isActive = _selectedTourIndex == i;
                    return GestureDetector(
                      onTap: () => setState(() => _selectedTourIndex = i),
                      child: Container(
                        padding:
                            const EdgeInsets.symmetric(horizontal: 16),
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: isActive
                              ? AppTheme.brand
                              : AppTheme.cardLight,
                          borderRadius: BorderRadius.circular(9999),
                          border: isActive
                              ? null
                              : Border.all(color: AppTheme.borderLight),
                        ),
                        child: Text(
                          activeTours[i].title,
                          style: GoogleFonts.inter(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: isActive
                                ? Colors.white
                                : AppTheme.textSecondary,
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),

              const SizedBox(height: 16),

              // ── Stats Row ────────────────────────────────────────────
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Row(
                  children: [
                    Expanded(
                      child: _StatBox(
                        value: newCount.toString(),
                        label: 'PENDING',
                        bgColor: AppTheme.infoLight,
                        valueColor: AppTheme.info,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _StatBox(
                        value: assignedCount.toString(),
                        label: 'ASSIGNED',
                        bgColor: AppTheme.successLight,
                        valueColor: AppTheme.success,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _StatBox(
                        value: paidCount.toString(),
                        label: 'PAID',
                        bgColor: AppTheme.warningLight,
                        valueColor: AppTheme.warning,
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 16),

              // ── Passenger Request List ────────────────────────────────
              Expanded(
                child: passengers.isEmpty
                    ? Center(
                        child: Text(
                          'No passengers yet. Add passengers from the tour detail page.',
                          textAlign: TextAlign.center,
                          style: GoogleFonts.inter(
                            fontSize: 14,
                            color: AppTheme.textMuted,
                          ),
                        ),
                      )
                    : ListView.separated(
                        padding:
                            const EdgeInsets.fromLTRB(20, 0, 20, 24),
                        itemCount: passengers.length,
                        separatorBuilder: (_, _) =>
                            const SizedBox(height: 12),
                        itemBuilder: (_, i) => _PassengerRequestCard(
                          tour: selectedTour,
                          passenger: passengers[i],
                        ),
                      ),
              ),
            ],
          );
        }),
      ),
    );
  }
}

// ── Stat Box ─────────────────────────────────────────────────────────────────

class _StatBox extends StatelessWidget {
  final String value;
  final String label;
  final Color bgColor;
  final Color valueColor;

  const _StatBox({
    required this.value,
    required this.label,
    required this.bgColor,
    required this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 14),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        children: [
          Text(
            value,
            style: GoogleFonts.inter(
              fontSize: 22,
              fontWeight: FontWeight.w700,
              color: valueColor,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: GoogleFonts.inter(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              letterSpacing: 1,
              color: valueColor,
            ),
          ),
        ],
      ),
    );
  }
}

// ── Passenger Request Card ──────────────────────────────────────────────────

class _PassengerRequestCard extends StatelessWidget {
  final Tour tour;
  final Passenger passenger;

  const _PassengerRequestCard({
    required this.tour,
    required this.passenger,
  });

  @override
  Widget build(BuildContext context) {
    final isAssigned = passenger.isSeatsAssigned;
    final isPaid = passenger.paymentStatus == PaymentStatus.paid;
    final initials = _getInitials(passenger.name);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.cardLight,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: isAssigned ? AppTheme.success : AppTheme.borderLight,
          width: isAssigned ? 1.5 : 1,
        ),
        boxShadow: AppTheme.cardShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Card Header ──────────────────────────────────────
          Row(
            children: [
              // Avatar
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: (isAssigned ? AppTheme.success : AppTheme.brand)
                      .withAlpha(30),
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: Text(
                  initials,
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: isAssigned ? AppTheme.success : AppTheme.brand,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              // Name + phone
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      passenger.name,
                      style: GoogleFonts.inter(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: AppTheme.textPrimary,
                      ),
                    ),
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
              // Status badge
              _buildStatusBadge(isAssigned, isPaid),
            ],
          ),

          const SizedBox(height: 12),

          // ── Request Tags ──────────────────────────────────────
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              _Tag(
                icon: Icons.event_seat_rounded,
                text: '${passenger.requestedSeats} Seat${passenger.requestedSeats > 1 ? 's' : ''}',
                bgColor:
                    isAssigned ? AppTheme.successLight : AppTheme.brandLight,
                color: isAssigned ? AppTheme.success : AppTheme.brand,
              ),
              _Tag(
                icon: Icons.chair_rounded,
                text: passenger.seatPreference.name == 'singleSofa'
                    ? 'Single Sofa'
                    : 'Double Sofa',
                bgColor:
                    isAssigned ? AppTheme.successLight : AppTheme.brandLight,
                color: isAssigned ? AppTheme.success : AppTheme.brand,
              ),
              if (isPaid)
                _Tag(
                  icon: Icons.check_circle_outline,
                  text: 'Paid',
                  bgColor: AppTheme.successLight,
                  color: AppTheme.success,
                ),
            ],
          ),

          // ── Assignment Info ───────────────────────────────────
          if (isAssigned) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                const Icon(Icons.grid_view_rounded,
                    size: 14, color: AppTheme.textMuted),
                const SizedBox(width: 6),
                Text(
                  'Seats: ${passenger.assignedSeats.join(', ')}',
                  style: GoogleFonts.inter(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: AppTheme.textSecondary,
                  ),
                ),
              ],
            ),
          ],

          const SizedBox(height: 12),

          // ── Action Buttons ────────────────────────────────────
          if (!isAssigned)
            _PendingActions(tour: tour, passenger: passenger)
          else
            _AssignedLabel(),
        ],
      ),
    );
  }

  Widget _buildStatusBadge(bool isAssigned, bool isPaid) {
    final String label;
    final Color bgColor;
    final Color textColor;

    if (isAssigned) {
      label = 'ASSIGNED';
      bgColor = AppTheme.successLight;
      textColor = AppTheme.success;
    } else {
      label = 'PENDING';
      bgColor = AppTheme.infoLight;
      textColor = AppTheme.info;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(9999),
      ),
      child: Text(
        label,
        style: GoogleFonts.inter(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.5,
          color: textColor,
        ),
      ),
    );
  }

  String _getInitials(String name) {
    final parts = name.trim().split(' ');
    if (parts.length >= 2) {
      return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
    }
    return name.isNotEmpty ? name[0].toUpperCase() : '?';
  }
}

// ── Tags ─────────────────────────────────────────────────────────────────────

class _Tag extends StatelessWidget {
  final IconData icon;
  final String text;
  final Color bgColor;
  final Color color;

  const _Tag({
    required this.icon,
    required this.text,
    required this.bgColor,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(9999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 5),
          Text(
            text,
            style: GoogleFonts.inter(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

// ── Pending Actions ─────────────────────────────────────────────────────────

class _PendingActions extends StatelessWidget {
  final Tour tour;
  final Passenger passenger;

  const _PendingActions({required this.tour, required this.passenger});

  @override
  Widget build(BuildContext context) {
    final tourCtrl = Get.find<TourController>();

    return Row(
      children: [
        // Assign Seats
        Expanded(
          child: GestureDetector(
            onTap: () {
              // Navigate to seat assignment for this passenger
              Get.toNamed('/seat-assignment', arguments: {
                'tourId': tour.id,
                'passengerId': passenger.id,
              });
            },
            child: Container(
              height: 40,
              decoration: BoxDecoration(
                color: AppTheme.brand,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.grid_view_rounded,
                      size: 14, color: Colors.white),
                  const SizedBox(width: 6),
                  Text(
                    'Assign Seats',
                    style: GoogleFonts.inter(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(width: 10),
        // Remove
        GestureDetector(
          onTap: () async {
            final confirmed = await AppDialogs.confirm(
              title: 'Remove Passenger',
              message:
                  'Are you sure you want to remove ${passenger.name} from this tour?',
              confirmText: 'Remove',
              isDestructive: true,
            );
            if (confirmed) {
              await tourCtrl.removePassenger(tour.id, passenger.id);
              AppSnackBar.info('${passenger.name} removed from tour');
            }
          },
          child: Container(
            height: 40,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: AppTheme.borderLight),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.close_rounded,
                    size: 14, color: AppTheme.textSecondary),
                const SizedBox(width: 5),
                Text(
                  'Remove',
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

// ── Assigned Label ──────────────────────────────────────────────────────────

class _AssignedLabel extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      height: 40,
      decoration: BoxDecoration(
        color: AppTheme.successLight,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: AppTheme.success.withAlpha(80)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.check_circle_outline,
              size: 16, color: AppTheme.success),
          const SizedBox(width: 6),
          Text(
            'Seats Assigned',
            style: GoogleFonts.inter(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: AppTheme.success,
            ),
          ),
        ],
      ),
    );
  }
}
