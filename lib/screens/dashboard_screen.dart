import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';

import '../config/theme.dart';
import '../controllers/auth_controller.dart';
import '../controllers/tour_controller.dart';
import '../models/tour.dart';
import '../models/tour_status.dart';
import 'create_tour_screen.dart';
import 'main_shell.dart';
import 'tour_detail_screen.dart';

/// Admin home screen. Mirrors the Pencil "Admin Home" layout:
/// greeting + avatar, 2x2 stat grid, "Upcoming Tours" list with status
/// pills, and a floating "+" CTA that opens Create Tour.
class DashboardScreen extends StatelessWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final tourCtrl = Get.find<TourController>();
    final authCtrl = Get.find<AuthController>();
    final shell = Get.find<ShellController>();
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      body: SafeArea(
        bottom: false,
        child: Stack(
          children: [
            Obx(() {
              if (tourCtrl.isLoading.value && tourCtrl.tours.isEmpty) {
                return const Center(child: CircularProgressIndicator());
              }
              if (tourCtrl.hasError.value && tourCtrl.tours.isEmpty) {
                return _ErrorState(
                  message: tourCtrl.errorMessage.value,
                  onRetry: tourCtrl.refreshTours,
                );
              }

              final tours = tourCtrl.tours;
              final activeTours = tourCtrl.activeTours;
              final pendingRequests = tourCtrl
                  .toursByStatus(TourStatus.collecting)
                  .length;
              final totalPassengers = tours.fold<int>(
                0,
                (s, t) => s + t.passengerCount,
              );
              final revenue = tours.fold<double>(
                0,
                (s, t) => s + (t.pricePerSeat * t.totalSeatsRequested),
              );

              return ListView(
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(20, 24, 20, 140),
                children: [
                  _Greeting(
                    name: authCtrl.userName.value,
                    initials: authCtrl.initials,
                  ),
                  const SizedBox(height: 28),
                  _SectionLabel('QUICK OVERVIEW'),
                  const SizedBox(height: 12),
                  _StatGrid(
                    activeCount: activeTours.length,
                    pendingRequests: pendingRequests,
                    totalPassengers: totalPassengers,
                    revenue: revenue,
                  ),
                  const SizedBox(height: 28),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Upcoming Tours',
                        style: GoogleFonts.inter(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                          color: theme.colorScheme.onSurface,
                        ),
                      ),
                      GestureDetector(
                        onTap: () => shell.switchTab(1),
                        child: Text(
                          'See All',
                          style: GoogleFonts.inter(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: AppTheme.brand,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  if (activeTours.isEmpty)
                    const _EmptyTours()
                  else
                    ...activeTours.map(
                      (tour) => Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: _TourCard(
                          tour: tour,
                          onTap: () => Get.to(
                            () => TourDetailScreen(tourId: tour.id),
                            transition: Transition.cupertino,
                          ),
                        ),
                      ),
                    ),
                ],
              );
            }),

            // Floating "+" — sits clear of the pill bottom nav (~104px tall).
            Positioned(
              right: 20,
              bottom: 110,
              child: _Fab(onTap: () => Get.to(() => const CreateTourScreen())),
            ),
          ],
        ),
      ),
    );
  }
}

class _Greeting extends StatelessWidget {
  final String name;
  final String initials;

  const _Greeting({required this.name, required this.initials});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final greeting = _greetingForHour(DateTime.now().hour);
    final displayName = name.isNotEmpty ? name : 'Welcome';
    final displayInitials = initials.isNotEmpty ? initials : '👋';

    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                greeting,
                style: GoogleFonts.inter(
                  fontSize: 14,
                  color: AppTheme.textSecondary,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                displayName,
                style: GoogleFonts.inter(
                  fontSize: 24,
                  fontWeight: FontWeight.w700,
                  color: theme.colorScheme.onSurface,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
        Container(
          width: 44,
          height: 44,
          decoration: const BoxDecoration(
            color: AppTheme.brand,
            shape: BoxShape.circle,
          ),
          alignment: Alignment.center,
          child: Text(
            displayInitials,
            style: GoogleFonts.inter(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: Colors.white,
            ),
          ),
        ),
      ],
    );
  }

  String _greetingForHour(int hour) {
    if (hour < 12) return 'Good Morning';
    if (hour < 17) return 'Good Afternoon';
    return 'Good Evening';
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: GoogleFonts.inter(
        fontSize: 11,
        fontWeight: FontWeight.w600,
        letterSpacing: 1.2,
        color: AppTheme.textMuted,
      ),
    );
  }
}

class _StatGrid extends StatelessWidget {
  final int activeCount;
  final int pendingRequests;
  final int totalPassengers;
  final double revenue;

  const _StatGrid({
    required this.activeCount,
    required this.pendingRequests,
    required this.totalPassengers,
    required this.revenue,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: _StatCard(
                icon: Icons.map_rounded,
                iconBg: AppTheme.brandLight,
                iconColor: AppTheme.brand,
                value: '$activeCount',
                label: 'Active Tours',
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _StatCard(
                icon: Icons.access_time_rounded,
                iconBg: AppTheme.warningLight,
                iconColor: AppTheme.warning,
                value: '$pendingRequests',
                label: 'Pending Requests',
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _StatCard(
                icon: Icons.people_rounded,
                iconBg: AppTheme.successLight,
                iconColor: AppTheme.success,
                value: '$totalPassengers',
                label: 'Total Passengers',
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _StatCard(
                icon: Icons.currency_rupee_rounded,
                iconBg: AppTheme.infoLight,
                iconColor: AppTheme.info,
                value: _formatRevenue(revenue),
                label: 'Revenue',
              ),
            ),
          ],
        ),
      ],
    );
  }

  String _formatRevenue(double amount) {
    if (amount >= 100000) {
      final lakhs = amount / 100000;
      return lakhs == lakhs.roundToDouble()
          ? '₹${lakhs.toInt()}L'
          : '₹${lakhs.toStringAsFixed(1)}L';
    }
    if (amount >= 1000) {
      final k = amount / 1000;
      return k == k.roundToDouble()
          ? '₹${k.toInt()}K'
          : '₹${k.toStringAsFixed(1)}K';
    }
    return '₹${amount.toInt()}';
  }
}

class _StatCard extends StatelessWidget {
  final IconData icon;
  final Color iconBg;
  final Color iconColor;
  final String value;
  final String label;

  const _StatCard({
    required this.icon,
    required this.iconBg,
    required this.iconColor,
    required this.value,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.cardDark : Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.borderLight),
        boxShadow: isDark ? null : AppTheme.subtleShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: iconBg,
              borderRadius: BorderRadius.circular(8),
            ),
            alignment: Alignment.center,
            child: Icon(icon, size: 16, color: iconColor),
          ),
          const SizedBox(height: 14),
          Text(
            value,
            style: GoogleFonts.inter(
              fontSize: 26,
              fontWeight: FontWeight.w700,
              color: theme.colorScheme.onSurface,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: GoogleFonts.inter(
              fontSize: 11,
              fontWeight: FontWeight.w500,
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
  final VoidCallback onTap;

  const _TourCard({required this.tour, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final colors = _statusColors(tour.status);

    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: isDark ? AppTheme.cardDark : Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppTheme.borderLight),
          boxShadow: isDark ? null : AppTheme.subtleShadow,
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    tour.title,
                    style: GoogleFonts.inter(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: theme.colorScheme.onSurface,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      const Icon(
                        Icons.calendar_today_outlined,
                        size: 12,
                        color: AppTheme.textSecondary,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        _formatDate(tour.departureDate, tour.returnDate),
                        style: GoogleFonts.inter(
                          fontSize: 11,
                          color: AppTheme.textSecondary,
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: Text(
                          '·',
                          style: GoogleFonts.inter(
                            fontSize: 11,
                            color: AppTheme.textMuted,
                          ),
                        ),
                      ),
                      const Icon(
                        Icons.people_outline_rounded,
                        size: 12,
                        color: AppTheme.textSecondary,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '${tour.passengerCount} pax',
                        style: GoogleFonts.inter(
                          fontSize: 11,
                          color: AppTheme.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: colors.$1,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                tour.status.displayName,
                style: GoogleFonts.inter(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  color: colors.$2,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatDate(DateTime departure, DateTime? returnDate) {
    final fmt = DateFormat('MMM d');
    if (returnDate != null) {
      return '${fmt.format(departure)} – ${fmt.format(returnDate)}';
    }
    return fmt.format(departure);
  }

  (Color, Color) _statusColors(TourStatus status) {
    switch (status) {
      case TourStatus.planning:
        return (AppTheme.infoLight, AppTheme.info);
      case TourStatus.collecting:
        return (AppTheme.warningLight, AppTheme.warning);
      case TourStatus.busBooked:
        return (AppTheme.brandLight, AppTheme.brand);
      case TourStatus.assigning:
        return (AppTheme.brandLight, AppTheme.brand);
      case TourStatus.locked:
        return (AppTheme.successLight, AppTheme.success);
      case TourStatus.completed:
        return (const Color(0xFFF1F5F9), AppTheme.textSecondary);
    }
  }
}

class _Fab extends StatelessWidget {
  final VoidCallback onTap;

  const _Fab({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 56,
        height: 56,
        decoration: BoxDecoration(
          color: AppTheme.brand,
          borderRadius: BorderRadius.circular(28),
          boxShadow: [
            BoxShadow(
              color: AppTheme.brand.withValues(alpha: 0.35),
              blurRadius: 16,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        alignment: Alignment.center,
        child: const Icon(Icons.add, size: 24, color: Colors.white),
      ),
    );
  }
}

class _EmptyTours extends StatelessWidget {
  const _EmptyTours();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 40),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.cardDark : Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.borderLight),
        boxShadow: isDark ? null : AppTheme.subtleShadow,
      ),
      child: Column(
        children: [
          const Icon(Icons.map_outlined, size: 40, color: AppTheme.textMuted),
          const SizedBox(height: 8),
          Text(
            'No upcoming tours',
            style: GoogleFonts.inter(fontSize: 13, color: AppTheme.textMuted),
          ),
        ],
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  final String message;
  final Future<void> Function() onRetry;

  const _ErrorState({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.cloud_off_rounded,
              size: 48,
              color: AppTheme.textMuted,
            ),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(
                fontSize: 14,
                color: AppTheme.textSecondary,
              ),
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }
}
