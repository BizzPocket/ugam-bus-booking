import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:google_fonts/google_fonts.dart';

import '../components/ugam_logo.dart';
import '../config/theme.dart';
import '../controllers/tour_controller.dart';
import '../models/tour.dart';
import '../models/tour_status.dart';
import 'customer_tour_detail_screen.dart';

/// Anonymous landing screen — lists public tours that customers can
/// browse without signing in. Tapping a tour opens its detail screen,
/// which leads to the WhatsApp booking request flow.
class CustomerTourListScreen extends StatelessWidget {
  const CustomerTourListScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final tourCtrl = Get.find<TourController>();
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Header(),
            Expanded(
              child: Obx(() {
                if (tourCtrl.isLoading.value && tourCtrl.tours.isEmpty) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (tourCtrl.hasError.value && tourCtrl.tours.isEmpty) {
                  return _Empty(
                    icon: Icons.cloud_off_rounded,
                    title: 'Cannot load tours',
                    subtitle: tourCtrl.errorMessage.value,
                    onRetry: tourCtrl.refreshTours,
                  );
                }
                final tours = _visibleTours(tourCtrl.tours);
                if (tours.isEmpty) {
                  return _Empty(
                    icon: Icons.event_busy_rounded,
                    title: 'No upcoming tours',
                    subtitle: 'Check back soon — new tours are announced '
                        'as soon as the route and date are confirmed.',
                    onRetry: tourCtrl.refreshTours,
                  );
                }
                return RefreshIndicator(
                  onRefresh: tourCtrl.refreshTours,
                  child: ListView.separated(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
                    itemCount: tours.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 14),
                    itemBuilder: (_, i) => _CustomerTourCard(
                      tour: tours[i],
                      colorScheme: colorScheme,
                    ),
                  ),
                );
              }),
            ),
          ],
        ),
      ),
    );
  }

  List<Tour> _visibleTours(List<Tour> all) => all
      .where((t) => t.isPublic && t.status != TourStatus.completed)
      .toList()
    ..sort((a, b) => a.departureDate.compareTo(b.departureDate));
}

class _Header extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
      child: Row(
        children: [
          const UgamLogo(size: 44),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Ugam Booking',
                  style: GoogleFonts.inter(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                ),
                Text(
                  'ઉગમ ફોજ બસ બુકિંગ',
                  style: GoogleFonts.notoSansGujarati(
                    fontSize: 11,
                    fontWeight: FontWeight.w400,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          OutlinedButton.icon(
            onPressed: () => Get.toNamed('/login'),
            icon: const Icon(Icons.lock_outline_rounded, size: 16),
            label: Text(
              'Admin',
              style: GoogleFonts.inter(
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CustomerTourCard extends StatelessWidget {
  final Tour tour;
  final ColorScheme colorScheme;

  const _CustomerTourCard({required this.tour, required this.colorScheme});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: () => Get.to(() => CustomerTourDetailScreen(tour: tour)),
      child: Ink(
        decoration: BoxDecoration(
          color: colorScheme.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: colorScheme.outline),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: AppTheme.brandLight,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      _formatDate(tour.departureDate),
                      style: GoogleFonts.inter(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: AppTheme.brandDark,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '₹${tour.pricePerSeat.toStringAsFixed(0)} / seat',
                    style: GoogleFonts.inter(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: colorScheme.onSurface,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                tour.title,
                style: GoogleFonts.inter(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  color: colorScheme.onSurface,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '${tour.fromCity} → ${tour.toCity}',
                style: GoogleFonts.inter(
                  fontSize: 14,
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Icon(
                    Icons.directions_bus_rounded,
                    size: 16,
                    color: colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    tour.buses.isEmpty
                        ? 'Bus to be confirmed'
                        : tour.buses.first.busNumber,
                    style: GoogleFonts.inter(
                      fontSize: 12,
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    'Tap to book →',
                    style: GoogleFonts.inter(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.brand,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _formatDate(DateTime d) {
    const months = [
      'JAN', 'FEB', 'MAR', 'APR', 'MAY', 'JUN',
      'JUL', 'AUG', 'SEP', 'OCT', 'NOV', 'DEC',
    ];
    return '${d.day.toString().padLeft(2, '0')} ${months[d.month - 1]}';
  }
}

class _Empty extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onRetry;

  const _Empty({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56, color: colorScheme.onSurfaceVariant),
            const SizedBox(height: 16),
            Text(
              title,
              style: GoogleFonts.inter(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: colorScheme.onSurface,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(
                fontSize: 14,
                color: colorScheme.onSurfaceVariant,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 18),
            OutlinedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded, size: 16),
              label: const Text('Refresh'),
            ),
          ],
        ),
      ),
    );
  }
}
