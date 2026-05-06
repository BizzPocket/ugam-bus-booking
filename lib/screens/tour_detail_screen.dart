import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';

import '../config/theme.dart';
import '../controllers/tour_controller.dart';
import '../models/tour.dart';
import '../models/tour_status.dart';
import '../models/payment_status.dart';
import '../components/passenger_tile.dart';

class TourDetailScreen extends StatelessWidget {
  final String tourId;
  const TourDetailScreen({super.key, required this.tourId});

  @override
  Widget build(BuildContext context) {
    final tourCtrl = Get.find<TourController>();
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final textTheme = theme.textTheme;
    final colorScheme = theme.colorScheme;

    return Obx(() {
      final tour = tourCtrl.getTour(tourId);
      if (tour == null) {
        return Scaffold(
          appBar: AppBar(),
          body: const Center(child: Text('Tour not found')),
        );
      }

      final booked = tour.passengers
          .where((p) => p.paymentStatus == PaymentStatus.paid)
          .length;
      final pending = tour.passengers
          .where((p) => p.paymentStatus == PaymentStatus.notPaid)
          .length;
      final declined = 0;

      return Scaffold(
        backgroundColor: colorScheme.surfaceContainerHighest,
        body: SafeArea(
          child: Column(
            children: [
              // ── Header ───────────────────────────────────────
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                decoration: BoxDecoration(
                  color: colorScheme.surface,
                  border: Border(
                    bottom:
                        BorderSide(color: colorScheme.outline, width: 1),
                  ),
                ),
                child: Row(
                  children: [
                    IconButton(
                      icon: Icon(
                        Icons.arrow_back,
                        color: colorScheme.onSurface,
                      ),
                      onPressed: () => Get.back(),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      'Tour Detail',
                      style: textTheme.titleLarge,
                    ),
                  ],
                ),
              ),

              // ── Scrollable Body ──────────────────────────────
              Expanded(
                child: SingleChildScrollView(
                  physics: const BouncingScrollPhysics(),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // ── Hero Area ────────────────────────────
                      Container(
                        width: double.infinity,
                        height: 200,
                        decoration: BoxDecoration(
                          gradient: AppTheme.brandGradient,
                          borderRadius: const BorderRadius.only(
                            bottomLeft: Radius.circular(6),
                            bottomRight: Radius.circular(6),
                          ),
                        ),
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            Text(
                              tour.title,
                              style: textTheme.headlineLarge?.copyWith(
                                color: Colors.white,
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                const Icon(Icons.location_on_outlined,
                                    size: 16, color: Colors.white70),
                                const SizedBox(width: 4),
                                Text(
                                  tour.route,
                                  style: textTheme.bodyMedium?.copyWith(
                                    color: Colors.white70,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),

                      // ── Detail Card ──────────────────────────
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
                        child: Container(
                          padding: const EdgeInsets.all(20),
                          decoration: BoxDecoration(
                            color: isDark ? AppTheme.cardDark : Colors.white,
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: colorScheme.outline),
                            boxShadow: isDark ? [] : AppTheme.cardShadow,
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      tour.title,
                                      style: textTheme.headlineMedium,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  _ActiveBadge(status: tour.status),
                                ],
                              ),

                              const SizedBox(height: 16),

                              Row(
                                children: [
                                  Expanded(
                                    child: _InfoCell(
                                      label: 'DATE RANGE',
                                      value: _formatDateRange(tour),
                                    ),
                                  ),
                                  const SizedBox(width: 16),
                                  Expanded(
                                    child: _InfoCell(
                                      label: 'ROUTE',
                                      value: tour.route,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 12),
                              Row(
                                children: [
                                  Expanded(
                                    child: _InfoCell(
                                      label: 'PRICE',
                                      value:
                                          '\u20B9${tour.pricePerSeat.toStringAsFixed(0)} /seat',
                                    ),
                                  ),
                                  Expanded(
                                    child: _InfoCell(
                                      label: 'PASSENGERS',
                                      value: '${tour.passengerCount}',
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),

                      const SizedBox(height: 16),

                      // ── Passenger Summary (3 cards) ──────────
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: Row(
                          children: [
                            Expanded(
                              child: _SummaryCard(
                                count: booked,
                                label: 'Booked',
                                bgColor: AppTheme.successLight,
                                textColor: AppTheme.success,
                                isDark: isDark,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: _SummaryCard(
                                count: pending,
                                label: 'Pending',
                                bgColor: AppTheme.warningLight,
                                textColor: AppTheme.warning,
                                isDark: isDark,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: _SummaryCard(
                                count: declined,
                                label: 'Declined',
                                bgColor: AppTheme.dangerLight,
                                textColor: AppTheme.danger,
                                isDark: isDark,
                              ),
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(height: 16),

                      // ── Bus Info Card ────────────────────────
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: isDark ? AppTheme.cardDark : Colors.white,
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: colorScheme.outline),
                            boxShadow: isDark ? [] : AppTheme.cardShadow,
                          ),
                          child: Row(
                            children: [
                              Container(
                                width: 44,
                                height: 44,
                                decoration: BoxDecoration(
                                  color: AppTheme.infoLight,
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: const Icon(
                                  Icons.directions_bus_rounded,
                                  size: 22,
                                  color: AppTheme.info,
                                ),
                              ),
                              const SizedBox(width: 14),
                              Expanded(
                                child: tour.buses.isNotEmpty
                                    ? Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            tour.buses.map((b) => b.name).join(', '),
                                            style: textTheme.titleMedium,
                                          ),
                                          const SizedBox(height: 2),
                                          Text(
                                            '${tour.buses.length} bus${tour.buses.length > 1 ? "es" : ""} \u2022 ${tour.totalBusSeats} seats',
                                            style: textTheme.bodySmall,
                                          ),
                                        ],
                                      )
                                    : Text(
                                        'No bus assigned yet',
                                        style: textTheme.bodyMedium?.copyWith(
                                          color: AppTheme.textMuted,
                                        ),
                                      ),
                              ),
                            ],
                          ),
                        ),
                      ),

                      const SizedBox(height: 20),

                      // ── Action Buttons ──────────────────────
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: Column(
                          children: [
                            SizedBox(
                              width: double.infinity,
                              height: 48,
                              child: ElevatedButton.icon(
                                onPressed: () {
                                  // Navigate to seat chart
                                },
                                icon: const Icon(
                                    Icons.grid_view_rounded,
                                    size: 18),
                                label: const Text('View Seat Chart'),
                              ),
                            ),

                            const SizedBox(height: 10),

                            SizedBox(
                              width: double.infinity,
                              height: 48,
                              child: OutlinedButton.icon(
                                onPressed: () {
                                  // Navigate to manage passengers
                                },
                                icon: const Icon(
                                    Icons.people_outline_rounded,
                                    size: 18),
                                label: const Text('Manage Passengers'),
                              ),
                            ),

                            const SizedBox(height: 10),

                            SizedBox(
                              width: double.infinity,
                              height: 48,
                              child: OutlinedButton.icon(
                                onPressed: () {
                                  // Navigate to edit tour
                                },
                                icon: Icon(
                                    Icons.edit_outlined,
                                    size: 18,
                                    color: AppTheme.textSecondary),
                                label: Text(
                                  'Edit Tour',
                                  style: textTheme.titleMedium?.copyWith(
                                    color: AppTheme.textSecondary,
                                  ),
                                ),
                                style: OutlinedButton.styleFrom(
                                  side: const BorderSide(
                                      color: AppTheme.borderLight,
                                      width: 1.5),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(height: 24),

                      // ── Passenger List ───────────────────────
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              'Passengers',
                              style: textTheme.headlineSmall,
                            ),
                            Text(
                              '${tour.passengerCount} total',
                              style: textTheme.titleSmall?.copyWith(
                                color: AppTheme.textMuted,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),

                      if (tour.passengers.isEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 20, vertical: 32),
                          child: Center(
                            child: Column(
                              children: [
                                Icon(
                                  Icons.people_outline_rounded,
                                  size: 40,
                                  color: AppTheme.textMuted.withAlpha(100),
                                ),
                                const SizedBox(height: 12),
                                Text(
                                  'No passengers yet',
                                  style: textTheme.bodyMedium?.copyWith(
                                    color: AppTheme.textMuted,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        )
                      else
                        Padding(
                          padding:
                              const EdgeInsets.symmetric(horizontal: 20),
                          child: Column(
                            children: tour.passengers
                                .map(
                                  (p) => Padding(
                                    padding:
                                        const EdgeInsets.only(bottom: 10),
                                    child: PassengerTile(
                                      passenger: p,
                                      onTap: () {},
                                    ),
                                  ),
                                )
                                .toList(),
                          ),
                        ),

                      const SizedBox(height: 40),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    });
  }

  String _formatDateRange(Tour tour) {
    final start = DateFormat('MMM d').format(tour.departureDate);
    if (tour.returnDate != null) {
      final end = DateFormat('MMM d').format(tour.returnDate!);
      return '$start - $end';
    }
    return start;
  }
}

// ── Active Badge ───────────────────────────────────────────────────

class _ActiveBadge extends StatelessWidget {
  final TourStatus status;
  const _ActiveBadge({required this.status});

  @override
  Widget build(BuildContext context) {
    final isActive = status != TourStatus.completed;
    final bgColor = isActive ? AppTheme.successLight : AppTheme.hoverLight;
    final textColor = isActive ? AppTheme.success : AppTheme.textSecondary;
    final label = status.displayName;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              color: textColor,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: textColor,
                ),
          ),
        ],
      ),
    );
  }
}

// ── Info Cell ──────────────────────────────────────────────────────

class _InfoCell extends StatelessWidget {
  final String label;
  final String value;

  const _InfoCell({
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: textTheme.labelSmall,
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w500,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }
}

// ── Summary Card ───────────────────────────────────────────────────

class _SummaryCard extends StatelessWidget {
  final int count;
  final String label;
  final Color bgColor;
  final Color textColor;
  final bool isDark;

  const _SummaryCard({
    required this.count,
    required this.label,
    required this.bgColor,
    required this.textColor,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
      decoration: BoxDecoration(
        color: isDark ? textColor.withAlpha(20) : bgColor,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        children: [
          Text(
            count.toString(),
            style: textTheme.headlineLarge?.copyWith(
              color: textColor,
              height: 1,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: textTheme.labelSmall?.copyWith(
              color: textColor,
            ),
          ),
        ],
      ),
    );
  }
}
