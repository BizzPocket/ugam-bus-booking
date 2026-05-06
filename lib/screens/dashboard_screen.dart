import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';

import '../config/theme.dart';
import '../controllers/auth_controller.dart';
import '../controllers/tour_controller.dart';
import '../models/tour.dart';
import '../models/tour_status.dart';
import '../utils/responsive.dart';
import 'main_shell.dart';
import 'create_tour_screen.dart';

class DashboardScreen extends StatelessWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final tourCtrl = Get.find<TourController>();
    final shell = Get.find<ShellController>();
    final authCtrl = Get.find<AuthController>();
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: SafeArea(
        bottom: false,
        child: Obx(() {
          if (tourCtrl.isLoading.value && tourCtrl.tours.isEmpty) {
            return const Center(child: CircularProgressIndicator());
          }

          if (tourCtrl.hasError.value && tourCtrl.tours.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.cloud_off_rounded,
                        size: 48,
                        color: isDark ? Colors.white38 : AppTheme.textMuted),
                    const SizedBox(height: 16),
                    Text(
                      tourCtrl.errorMessage.value,
                      textAlign: TextAlign.center,
                      style: GoogleFonts.inter(
                        fontSize: 15,
                        color: isDark ? Colors.white70 : AppTheme.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 16),
                    OutlinedButton.icon(
                      onPressed: tourCtrl.refreshTours,
                      icon: const Icon(Icons.refresh_rounded, size: 18),
                      label: const Text('Retry'),
                    ),
                  ],
                ),
              ),
            );
          }

          final tours = tourCtrl.tours;
          final activeTours = tourCtrl.activeTours;
          final activeCount = activeTours.length;
          final pendingRequests = tourCtrl
              .toursByStatus(TourStatus.collecting)
              .length;
          final totalPassengers =
              tours.fold<int>(0, (sum, t) => sum + t.passengerCount);
          final revenue = tours.fold<double>(
              0, (sum, t) => sum + (t.pricePerSeat * t.totalSeatsRequested));

          return Stack(
            children: [
              SingleChildScrollView(
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 20),

                    // ── Header (greetRow) ──────────────────────────
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _greeting(),
                                style: GoogleFonts.inter(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w400,
                                  color: isDark ? const Color(0xFFCBD5E1) : AppTheme.textSecondary,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                authCtrl.userName.value.isNotEmpty
                                    ? authCtrl.userName.value
                                    : 'User',
                                style: GoogleFonts.inter(
                                  fontSize: 22,
                                  fontWeight: FontWeight.w700,
                                  color: isDark ? Colors.white : AppTheme.textPrimary,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),
                        Container(
                          width: 44,
                          height: 44,
                          decoration: const BoxDecoration(
                            color: AppTheme.brand,
                            shape: BoxShape.circle,
                          ),
                          alignment: Alignment.center,
                          child: Text(
                            authCtrl.initials,
                            style: GoogleFonts.inter(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ],
                    ),

                    const SizedBox(height: 28),

                    // ── QUICK OVERVIEW label ───────────────────────
                    Text(
                      'QUICK OVERVIEW',
                      style: GoogleFonts.inter(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 1.2,
                        color: isDark ? const Color(0xFF94A3B8) : AppTheme.textMuted,
                      ),
                    ),

                    const SizedBox(height: 14),

                    // ── 2x2 stat grid ──────────────────────────────
                    GridView.count(
                      crossAxisCount: Responsive.gridColumns(context),
                      mainAxisSpacing: 12,
                      crossAxisSpacing: 12,
                      childAspectRatio: Responsive.statCardAspectRatio(context),
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      children: [
                        _StatCard(
                          icon: Icons.map_rounded,
                          iconBgColor: AppTheme.brandLight,
                          iconColor: AppTheme.brand,
                          value: '$activeCount',
                          label: 'Active Tours',
                        ),
                        _StatCard(
                          icon: Icons.access_time_rounded,
                          iconBgColor: AppTheme.warningLight,
                          iconColor: AppTheme.warning,
                          value: '$pendingRequests',
                          label: 'Pending Requests',
                        ),
                        _StatCard(
                          icon: Icons.people_rounded,
                          iconBgColor: AppTheme.successLight,
                          iconColor: AppTheme.success,
                          value: '$totalPassengers',
                          label: 'Total Passengers',
                        ),
                        _StatCard(
                          icon: Icons.currency_rupee_rounded,
                          iconBgColor: AppTheme.infoLight,
                          iconColor: AppTheme.info,
                          value: _formatRevenue(revenue),
                          label: 'Revenue',
                        ),
                      ],
                    ),

                    const SizedBox(height: 28),

                    // ── Upcoming Tours header ──────────────────────
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'Upcoming Tours',
                          style: GoogleFonts.inter(
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                            color: AppTheme.textPrimary,
                          ),
                        ),
                        GestureDetector(
                          onTap: () => shell.switchTab(1),
                          child: Text(
                            'See All',
                            style: GoogleFonts.inter(
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                              color: AppTheme.brand,
                            ),
                          ),
                        ),
                      ],
                    ),

                    const SizedBox(height: 14),

                    // ── Tour list ──────────────────────────────────
                    if (activeTours.isEmpty)
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(vertical: 40),
                        decoration: BoxDecoration(
                          color: isDark ? AppTheme.cardDark : Colors.white,
                          borderRadius: BorderRadius.circular(6),
                          boxShadow: isDark ? null : AppTheme.cardShadow,
                        ),
                        child: Column(
                          children: [
                            Icon(Icons.map_outlined,
                                size: 40, color: AppTheme.textMuted),
                            const SizedBox(height: 8),
                            Text(
                              'No upcoming tours',
                              style: GoogleFonts.inter(
                                fontSize: 13,
                                color: AppTheme.textMuted,
                              ),
                            ),
                          ],
                        ),
                      )
                    else
                      ...activeTours.map((tour) => Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: _UpcomingTourCard(tour: tour),
                          )),

                    // Bottom spacing for nav bar + FAB
                    const SizedBox(height: 120),
                  ],
                ),
              ),

              // ── FAB ────────────────────────────────────────────
              Positioned(
                bottom: 100,
                right: 20,
                child: Semantics(
                  button: true,
                  label: 'Create new tour',
                  child: GestureDetector(
                    onTap: () => Get.to(() => const CreateTourScreen()),
                    child: Container(
                      width: 56,
                      height: 56,
                      decoration: BoxDecoration(
                        color: AppTheme.brand,
                        borderRadius: BorderRadius.circular(28),
                        boxShadow: AppTheme.brandShadow,
                      ),
                      alignment: Alignment.center,
                      child: const Icon(
                        Icons.add,
                        size: 24,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        }),
      ),
    );
  }

  String _greeting() {
    final hour = DateTime.now().hour;
    if (hour < 12) return 'Good Morning';
    if (hour < 17) return 'Good Afternoon';
    return 'Good Evening';
  }

  String _formatRevenue(double amount) {
    if (amount >= 100000) {
      final lakhs = amount / 100000;
      return lakhs == lakhs.roundToDouble()
          ? '\u20B9${lakhs.toInt()}L'
          : '\u20B9${lakhs.toStringAsFixed(1)}L';
    } else if (amount >= 1000) {
      final k = amount / 1000;
      return k == k.roundToDouble()
          ? '\u20B9${k.toInt()}K'
          : '\u20B9${k.toStringAsFixed(1)}K';
    }
    return '\u20B9${amount.toInt()}';
  }
}

// ── Stat Card ─────────────────────────────────────────────────────

class _StatCard extends StatelessWidget {
  final IconData icon;
  final Color iconBgColor;
  final Color iconColor;
  final String value;
  final String label;

  const _StatCard({
    required this.icon,
    required this.iconBgColor,
    required this.iconColor,
    required this.value,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.cardDark : Colors.white,
        borderRadius: BorderRadius.circular(6),
        boxShadow: isDark ? null : AppTheme.cardShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: iconBgColor,
              borderRadius: BorderRadius.circular(6),
            ),
            alignment: Alignment.center,
            child: Icon(icon, size: 16, color: iconColor),
          ),
          const Spacer(),
          Text(
            value,
            style: GoogleFonts.inter(
              fontSize: 26,
              fontWeight: FontWeight.w700,
              color: isDark ? Colors.white : AppTheme.textPrimary,
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
              color: isDark ? const Color(0xFF94A3B8) : AppTheme.textMuted,
            ),
          ),
        ],
      ),
    );
  }
}

// ── Upcoming Tour Card ────────────────────────────────────────────

class _UpcomingTourCard extends StatelessWidget {
  final Tour tour;

  const _UpcomingTourCard({required this.tour});

  @override
  Widget build(BuildContext context) {
    final dateStr = _formatDate(tour.departureDate, tour.returnDate);
    final paxStr = '${tour.passengerCount} pax';
    final statusLabel = tour.status.displayName;
    final statusColors = _statusColors(tour.status);

    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.cardDark : Colors.white,
        borderRadius: BorderRadius.circular(6),
        boxShadow: isDark ? null : AppTheme.cardShadow,
      ),
      child: Row(
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
                    color: isDark ? Colors.white : AppTheme.textPrimary,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Icon(Icons.calendar_today_outlined,
                        size: 12, color: AppTheme.textSecondary),
                    const SizedBox(width: 4),
                    Text(
                      dateStr,
                      style: GoogleFonts.inter(
                        fontSize: 11,
                        fontWeight: FontWeight.w400,
                        color: AppTheme.textSecondary,
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Text(
                        '\u00B7',
                        style: GoogleFonts.inter(
                          fontSize: 11,
                          color: AppTheme.textMuted,
                        ),
                      ),
                    ),
                    Icon(Icons.people_outline_rounded,
                        size: 12, color: AppTheme.textSecondary),
                    const SizedBox(width: 4),
                    Text(
                      paxStr,
                      style: GoogleFonts.inter(
                        fontSize: 11,
                        fontWeight: FontWeight.w400,
                        color: AppTheme.textSecondary,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 14),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: statusColors.$1,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              statusLabel,
              style: GoogleFonts.inter(
                fontSize: 10,
                fontWeight: FontWeight.w600,
                color: statusColors.$2,
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _formatDate(DateTime departure, DateTime? returnDate) {
    final fmt = DateFormat('MMM d');
    if (returnDate != null) {
      return '${fmt.format(departure)} \u2013 ${fmt.format(returnDate)}';
    }
    return fmt.format(departure);
  }

  /// Returns (bgColor, textColor) for the status badge.
  (Color, Color) _statusColors(TourStatus status) {
    switch (status) {
      case TourStatus.planning:
        return (AppTheme.infoLight, AppTheme.info);
      case TourStatus.collecting:
        return (AppTheme.warningLight, AppTheme.warning);
      case TourStatus.busBooked:
        return (AppTheme.successLight, AppTheme.success);
      case TourStatus.assigning:
        return (AppTheme.brandLight, AppTheme.brand);
      case TourStatus.locked:
        return (AppTheme.successLight, AppTheme.success);
      case TourStatus.completed:
        return (const Color(0xFFF1F5F9), AppTheme.textSecondary);
    }
  }
}
