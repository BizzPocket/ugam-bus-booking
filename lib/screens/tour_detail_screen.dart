import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:google_fonts/google_fonts.dart';

import '../config/theme.dart';
import '../controllers/tour_controller.dart';
import '../models/tour.dart';
import '../models/tour_status.dart';
import '../models/payment_status.dart';
import 'edit_tour_screen.dart';
import 'manage_buses_screen.dart';
import 'tour_seat_assignment_screen.dart';

class TourDetailScreen extends StatelessWidget {
  final String tourId;
  const TourDetailScreen({super.key, required this.tourId});

  @override
  Widget build(BuildContext context) {
    final tourCtrl = Get.find<TourController>();

    return Obx(() {
      final tour = tourCtrl.getTour(tourId);
      if (tour == null) {
        return Scaffold(
          appBar: AppBar(title: Text(tr('tour_detail.not_found_title'))),
          body: Center(child: Text(tr('tour_detail.not_found_body'))),
        );
      }

      final booked = tour.passengers
          .where((p) => p.paymentStatus == PaymentStatus.paid)
          .length;
      final pending = tour.passengers
          .where((p) => p.paymentStatus == PaymentStatus.notPaid)
          .length;
      final declined = 0; // Logic for declined not yet in model, keeping 0

      return Scaffold(
        backgroundColor: AppTheme.bgLight,
        appBar: AppBar(
          backgroundColor: Colors.white,
          elevation: 0,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back, color: AppTheme.textPrimary),
            onPressed: () => Get.back(),
          ),
          title: Text(
            tr('tour_detail.title'),
            style: GoogleFonts.inter(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: AppTheme.textPrimary,
            ),
          ),
          centerTitle: true,
          actions: [
            IconButton(
              icon: const Icon(Icons.edit_outlined,
                  color: AppTheme.textPrimary),
              tooltip: tr('tour_detail.tooltip_edit'),
              onPressed: () => Get.to(
                () => EditTourScreen(tourId: tourId),
                transition: Transition.cupertino,
              ),
            ),
          ],
        ),
        body: RefreshIndicator(
          onRefresh: tourCtrl.refreshTours,
          color: AppTheme.brand,
          child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(
            parent: BouncingScrollPhysics(),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 16),

              // ── Tour Title & Basic Info ──────────────────────────
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppTheme.borderLight),
                    boxShadow: [AppTheme.subtleShadow[0]],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Expanded(
                            child: Text(
                              tour.title,
                              style: GoogleFonts.inter(
                                fontSize: 22,
                                fontWeight: FontWeight.w700,
                                color: AppTheme.textPrimary,
                              ),
                            ),
                          ),
                          _StatusBadge(status: tour.status),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          Expanded(
                            child: _InfoItem(
                              label: tr('tour_detail.label_date_range'),
                              value: _formatDateRange(tour),
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: _InfoItem(
                              label: tr('tour_detail.label_route'),
                              value: tour.route,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      _InfoItem(
                        label: tr('tour_detail.label_price'),
                        value: tr('tour_detail.price_per_seat', namedArgs: {'price': tour.pricePerSeat.toStringAsFixed(0)}),
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 24),

              // ── Passenger Summary Header ────────────────────────
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  tr('tour_detail.section_passenger_summary'),
                  style: GoogleFonts.inter(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.textPrimary,
                  ),
                ),
              ),

              const SizedBox(height: 12),

              // ── Passenger Summary Cards ────────────────────────
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    Expanded(
                      child: _SummaryStatCard(
                        count: booked,
                        label: tr('tour_detail.stat_booked'),
                        color: AppTheme.success,
                        bgColor: AppTheme.successLight,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _SummaryStatCard(
                        count: pending,
                        label: tr('tour_detail.stat_pending'),
                        color: AppTheme.warning,
                        bgColor: AppTheme.warningLight,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _SummaryStatCard(
                        count: declined,
                        label: tr('tour_detail.stat_declined'),
                        color: AppTheme.danger,
                        bgColor: AppTheme.dangerLight,
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 24),

              // ── Bus Information Header ────────────────────────
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  tr('tour_detail.section_bus_information'),
                  style: GoogleFonts.inter(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.textPrimary,
                  ),
                ),
              ),

              const SizedBox(height: 12),

              // ── Bus Info List ────────────────────────
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: tour.buses.isEmpty
                    ? _EmptyBusInfo()
                    : Column(
                        children: tour.buses.map((bus) => _BusInfoCard(bus: bus)).toList(),
                      ),
              ),

              const SizedBox(height: 12),

              // ── Manage Buses CTA ──────────────────────
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: ElevatedButton.icon(
                    onPressed: () => Get.to(
                      () => ManageBusesScreen(tourId: tourId),
                      transition: Transition.cupertino,
                    ),
                    icon: const Icon(Icons.directions_bus_rounded, size: 18),
                    label: Text(
                      tour.buses.isEmpty
                          ? tr('tour_detail.btn_add_bus')
                          : tr('tour_detail.btn_manage_buses', namedArgs: {'count': tour.buses.length.toString()}),
                      style: GoogleFonts.inter(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                        height: 1.2,
                      ),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.brand,
                      foregroundColor: Colors.white,
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  ),
                ),
              ),

              if (tour.buses.isNotEmpty) ...[
                const SizedBox(height: 10),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: OutlinedButton.icon(
                      onPressed: () => Get.to(
                        () => TourSeatAssignmentScreen(tourId: tourId),
                        transition: Transition.cupertino,
                      ),
                      icon: const Icon(
                        Icons.grid_view_rounded,
                        size: 18,
                      ),
                      label: Text(
                        tr('tour_detail.btn_assign_seats', namedArgs: {'assigned': tour.totalSeatsAssigned.toString(), 'total': tour.totalSeatsRequested.toString()}),
                        style: GoogleFonts.inter(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: AppTheme.brand,
                          height: 1.2,
                        ),
                      ),
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(
                          color: AppTheme.brand,
                          width: 1.5,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                    ),
                  ),
                ),
              ],

              const SizedBox(height: 32),
            ],
          ),
          ),
        ),
      );
    });
  }

  String _formatDateRange(Tour tour) {
    final fmt = DateFormat('MMM d, yyyy');
    final start = fmt.format(tour.departureDate);
    if (tour.returnDate != null) {
      final end = fmt.format(tour.returnDate!);
      return '$start - $end';
    }
    return start;
  }
}

class _StatusBadge extends StatelessWidget {
  final TourStatus status;
  const _StatusBadge({required this.status});

  @override
  Widget build(BuildContext context) {
    final isActive = status != TourStatus.completed;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: isActive ? AppTheme.successLight : AppTheme.borderLight,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              color: isActive ? AppTheme.success : AppTheme.textSecondary,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            isActive ? tr('tour_detail.status_active') : tr('tour_detail.status_completed'),
            style: GoogleFonts.inter(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: isActive ? AppTheme.success : AppTheme.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoItem extends StatelessWidget {
  final String label;
  final String value;

  const _InfoItem({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: GoogleFonts.inter(
            fontSize: 10,
            fontWeight: FontWeight.w600,
            color: AppTheme.textMuted,
            letterSpacing: 0.5,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: GoogleFonts.inter(
            fontSize: 15,
            fontWeight: FontWeight.w500,
            color: AppTheme.textSecondary,
          ),
        ),
      ],
    );
  }
}

class _SummaryStatCard extends StatelessWidget {
  final int count;
  final String label;
  final Color color;
  final Color bgColor;

  const _SummaryStatCard({
    required this.count,
    required this.label,
    required this.color,
    required this.bgColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 20),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          Text(
            count.toString(),
            style: GoogleFonts.inter(
              fontSize: 24,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: GoogleFonts.inter(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

class _BusInfoCard extends StatelessWidget {
  final dynamic bus; // Replace with actual Bus model if available

  const _BusInfoCard({required this.bus});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.borderLight),
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: AppTheme.brandLight,
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(Icons.directions_bus_rounded, color: AppTheme.brand),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  bus.name ?? 'GJ-01-AB-1234',
                  style: GoogleFonts.inter(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  tr('tour_detail.driver_label', namedArgs: {'name': bus.driverName ?? ''}),
                  style: GoogleFonts.inter(
                    fontSize: 12,
                    color: AppTheme.textSecondary,
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

class _EmptyBusInfo extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.borderLight),
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: AppTheme.bgLight,
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(Icons.bus_alert_rounded, color: AppTheme.textMuted),
          ),
          const SizedBox(width: 14),
          Text(
            tr('tour_detail.no_bus_assigned'),
            style: GoogleFonts.inter(
              fontSize: 14,
              color: AppTheme.textMuted,
            ),
          ),
        ],
      ),
    );
  }
}
