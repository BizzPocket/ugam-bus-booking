import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:google_fonts/google_fonts.dart';

import '../config/theme.dart';
import '../models/tour.dart';
import '../models/tour_status.dart';
import '../services/whatsapp_service.dart';
import 'customer_booking_request_screen.dart';

/// Public-facing tour detail. Customers see route, dates, price, bus
/// info if confirmed, and a single CTA that opens the booking-request
/// composer.
class CustomerTourDetailScreen extends StatelessWidget {
  final Tour tour;

  const CustomerTourDetailScreen({super.key, required this.tour});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Get.back(),
        ),
        title: Text(
          'Tour details',
          style: GoogleFonts.inter(
            fontSize: 17,
            fontWeight: FontWeight.w700,
            color: colorScheme.onSurface,
          ),
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                children: [
                  _StatusChip(status: tour.status),
                  const SizedBox(height: 14),
                  Text(
                    tour.title,
                    style: GoogleFonts.inter(
                      fontSize: 24,
                      fontWeight: FontWeight.w700,
                      color: colorScheme.onSurface,
                      height: 1.2,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '${tour.fromCity} → ${tour.toCity}',
                    style: GoogleFonts.inter(
                      fontSize: 16,
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '[Tour ID: ${WhatsAppService.tourCode(tour.id)}]',
                    style: GoogleFonts.robotoMono(
                      fontSize: 12,
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 20),
                  _DetailGrid(tour: tour, colorScheme: colorScheme),
                  if (tour.busDetails != null) ...[
                    const SizedBox(height: 20),
                    _BusCard(tour: tour, colorScheme: colorScheme),
                  ],
                  if (tour.description != null &&
                      tour.description!.isNotEmpty) ...[
                    const SizedBox(height: 20),
                    Text(
                      'About this tour',
                      style: GoogleFonts.inter(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: colorScheme.onSurfaceVariant,
                        letterSpacing: 0.5,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      tour.description!,
                      style: GoogleFonts.inter(
                        fontSize: 15,
                        color: colorScheme.onSurface,
                        height: 1.55,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            // Sticky bottom CTA
            Container(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
              decoration: BoxDecoration(
                color: colorScheme.surface,
                border: Border(top: BorderSide(color: colorScheme.outline)),
              ),
              child: SizedBox(
                width: double.infinity,
                height: 56,
                child: ElevatedButton.icon(
                  onPressed: () => Get.to(
                      () => CustomerBookingRequestScreen(tour: tour)),
                  icon: const Icon(Icons.event_seat_rounded),
                  label: Text(
                    'Request seats',
                    style: GoogleFonts.inter(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
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
          ],
        ),
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  final TourStatus status;
  const _StatusChip({required this.status});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: AppTheme.brandLight,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        status.displayName,
        style: GoogleFonts.inter(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: AppTheme.brandDark,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

class _DetailGrid extends StatelessWidget {
  final Tour tour;
  final ColorScheme colorScheme;
  const _DetailGrid({required this.tour, required this.colorScheme});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colorScheme.outline),
      ),
      child: Column(
        children: [
          _row(Icons.calendar_today_rounded, 'Departure',
              _formatDate(tour.departureDate)),
          if (tour.returnDate != null) ...[
            const SizedBox(height: 12),
            _row(Icons.event_available_rounded, 'Return',
                _formatDate(tour.returnDate!)),
          ],
          const SizedBox(height: 12),
          _row(Icons.currency_rupee_rounded, 'Price per seat',
              '₹${tour.pricePerSeat.toStringAsFixed(0)}'),
          const SizedBox(height: 12),
          _row(
            Icons.group_rounded,
            'Tour status',
            tour.status.description,
          ),
        ],
      ),
    );
  }

  Widget _row(IconData icon, String label, String value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: colorScheme.onSurfaceVariant),
        const SizedBox(width: 12),
        SizedBox(
          width: 110,
          child: Text(
            label,
            style: GoogleFonts.inter(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: GoogleFonts.inter(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: colorScheme.onSurface,
            ),
          ),
        ),
      ],
    );
  }

  static String _formatDate(DateTime d) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    return '${d.day} ${months[d.month - 1]} ${d.year}';
  }
}

class _BusCard extends StatelessWidget {
  final Tour tour;
  final ColorScheme colorScheme;
  const _BusCard({required this.tour, required this.colorScheme});

  @override
  Widget build(BuildContext context) {
    final bus = tour.busDetails!;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.brandLight,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.brandAccent.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.directions_bus_rounded,
                  size: 18, color: AppTheme.brandDark),
              const SizedBox(width: 8),
              Text(
                'Bus confirmed',
                style: GoogleFonts.inter(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: AppTheme.brandDark,
                  letterSpacing: 0.5,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            bus.busNumber,
            style: GoogleFonts.inter(
              fontSize: 17,
              fontWeight: FontWeight.w700,
              color: AppTheme.brandDark,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '${bus.isAC ? "AC" : "Non-AC"} · ${bus.busType} · ${bus.driverName}',
            style: GoogleFonts.inter(
              fontSize: 13,
              color: AppTheme.brandDark.withValues(alpha: 0.85),
            ),
          ),
        ],
      ),
    );
  }
}
