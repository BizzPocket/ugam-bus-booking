import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';
import 'package:google_fonts/google_fonts.dart';

import '../config/theme.dart';
import '../controllers/tour_controller.dart';
import '../models/tour.dart';
import '../models/tour_status.dart';
import '../models/payment_status.dart';
import '../components/passenger_tile.dart';
import 'manage_buses_screen.dart';

class TourDetailScreen extends StatelessWidget {
  final String tourId;
  const TourDetailScreen({super.key, required this.tourId});

  @override
  Widget build(BuildContext context) {
    final tourCtrl = Get.find<TourController>();
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final colorScheme = theme.colorScheme;

    return Obx(() {
      final tour = tourCtrl.getTour(tourId);
      if (tour == null) {
        return Scaffold(
          appBar: AppBar(title: const Text('Not Found')),
          body: const Center(child: Text('Tour not found')),
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
            'Tour Detail',
            style: GoogleFonts.inter(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: AppTheme.textPrimary,
            ),
          ),
          centerTitle: true,
        ),
        body: SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Hero Image ────────────────────────────
              Container(
                margin: const EdgeInsets.all(16),
                width: double.infinity,
                height: 200,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  image: const DecorationImage(
                    image: NetworkImage(
                        'https://images.unsplash.com/photo-1596422846543-75c6fc18a5ce?q=80&w=2070&auto=format&fit=crop'),
                    fit: BoxFit.cover,
                  ),
                ),
              ),

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
                              label: 'DATE RANGE',
                              value: _formatDateRange(tour),
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: _InfoItem(
                              label: 'ROUTE',
                              value: tour.route,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      _InfoItem(
                        label: 'PRICE',
                        value: '₹${tour.pricePerSeat.toStringAsFixed(0)}/seat',
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
                  'Passenger Summary',
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
                        label: 'Booked',
                        color: AppTheme.success,
                        bgColor: AppTheme.successLight,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _SummaryStatCard(
                        count: pending,
                        label: 'Pending',
                        color: AppTheme.warning,
                        bgColor: AppTheme.warningLight,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _SummaryStatCard(
                        count: declined,
                        label: 'Declined',
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
                  'Bus Information',
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

              const SizedBox(height: 32),
            ],
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
            isActive ? 'Active' : 'Completed',
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
                  'Driver: ${bus.driverName ?? "Ramesh Patel"}',
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
            'No bus assigned yet',
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
