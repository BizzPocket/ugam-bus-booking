import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:google_fonts/google_fonts.dart';

import '../config/theme.dart';
import '../models/tour.dart';
import '../models/passenger.dart';
import '../services/whatsapp_service.dart';
import '../utils/app_snackbar.dart';

class TicketScreen extends StatelessWidget {
  final Tour tour;
  final Passenger passenger;
  final List<String> seatNumbers;

  const TicketScreen({
    super.key,
    required this.tour,
    required this.passenger,
    required this.seatNumbers,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final colorScheme = theme.colorScheme;

    return Scaffold(
      backgroundColor: isDark ? colorScheme.surface : const Color(0xFFF1F5F9),
      appBar: AppBar(
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: colorScheme.onSurface),
          onPressed: () => Get.back(),
        ),
        title: Text(
          'E-Ticket',
          style: GoogleFonts.outfit(
            fontSize: 20,
            fontWeight: FontWeight.w700,
            color: colorScheme.onSurface,
          ),
        ),
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
      ),
      body: SingleChildScrollView(
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
        child: Column(
          children: [
            // E-Ticket Card
            Container(
              decoration: BoxDecoration(
                color: theme.cardColor,
                borderRadius: BorderRadius.circular(24),
                border: isDark ? Border.all(color: colorScheme.outline) : null,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withAlpha(isDark ? 30 : 6),
                    blurRadius: 20,
                    offset: const Offset(0, 10),
                  ),
                ],
              ),
              child: Column(
                children: [
                  // Header
                  Container(
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      color: AppTheme.brandDark,
                      borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              tour.route,
                              style: GoogleFonts.outfit(
                                fontSize: 24,
                                fontWeight: FontWeight.w700,
                                color: Colors.white,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Occubus Tours & Travels',
                              style: GoogleFonts.inter(
                                fontSize: 13,
                                color: Colors.white.withAlpha(200),
                              ),
                            ),
                          ],
                        ),
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: Colors.white.withAlpha(40),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Icon(Icons.directions_bus_rounded, color: Colors.white, size: 28),
                        ),
                      ],
                    ),
                  ),

                  // Divider with cutouts
                  Stack(
                    children: [
                      Container(
                        height: 32,
                        decoration: BoxDecoration(
                          color: theme.cardColor,
                        ),
                      ),
                      Positioned.fill(
                        child: Align(
                          alignment: Alignment.center,
                          child: Row(
                            children: List.generate(
                              30,
                              (index) => Expanded(
                                child: Container(
                                  height: 2,
                                  color: index.isEven
                                      ? colorScheme.outline.withAlpha(100)
                                      : Colors.transparent,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      Positioned(
                        left: -16,
                        top: 0,
                        bottom: 0,
                        child: Container(
                          width: 32,
                          height: 32,
                          decoration: BoxDecoration(
                            color: isDark ? colorScheme.surface : const Color(0xFFF1F5F9),
                            shape: BoxShape.circle,
                          ),
                        ),
                      ),
                      Positioned(
                        right: -16,
                        top: 0,
                        bottom: 0,
                        child: Container(
                          width: 32,
                          height: 32,
                          decoration: BoxDecoration(
                            color: isDark ? colorScheme.surface : const Color(0xFFF1F5F9),
                            shape: BoxShape.circle,
                          ),
                        ),
                      ),
                    ],
                  ),

                  // Passenger & Trip Info
                  Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      children: [
                        _InfoRow(
                          label1: 'Passenger Name',
                          value1: passenger.name,
                          label2: 'Phone Number',
                          value2: passenger.phone,
                        ),
                        const SizedBox(height: 24),
                        _InfoRow(
                          label1: 'Departure Date',
                          value1: '${tour.departureDate.day}/${tour.departureDate.month}/${tour.departureDate.year}',
                          label2: 'Seats',
                          value2: '${seatNumbers.length} seat${seatNumbers.length > 1 ? "s" : ""}',
                        ),
                        const SizedBox(height: 24),
                        _InfoRow(
                          label1: 'Seats',
                          value1: seatNumbers.join(', '),
                          label2: 'Total Pax',
                          value2: '${seatNumbers.length}',
                        ),
                        const SizedBox(height: 32),

                        // QR Code Mock
                        Container(
                          width: 140,
                          height: 140,
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: const Color(0xFFE2E8F0)),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withAlpha(10),
                                blurRadius: 10,
                                offset: const Offset(0, 4),
                              ),
                            ],
                          ),
                          alignment: Alignment.center,
                          child: Icon(
                            Icons.qr_code_2_rounded,
                            size: 110,
                            color: isDark ? const Color(0xFF0F172A) : colorScheme.onSurface,
                          ),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'Scan to verify booking',
                          style: GoogleFonts.inter(
                            fontSize: 12,
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 32),
            SizedBox(
              width: double.infinity,
              height: 52,
              child: ElevatedButton.icon(
                onPressed: () async {
                  final wa = WhatsAppService();
                  final sent = await wa.sendToPassenger(
                    passenger: passenger,
                    tour: tour,
                    busNumber: tour.busDetails?.busNumber,
                    driverName: tour.busDetails?.driverName,
                    driverPhone: tour.busDetails?.driverPhone,
                  );
                  if (!sent) {
                    AppSnackBar.error('Could not open WhatsApp. Is it installed?');
                  }
                },
                icon: const Icon(Icons.share_rounded, size: 20),
                label: const Text('Share Ticket (WhatsApp)'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.brand,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
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

class _InfoRow extends StatelessWidget {
  final String label1;
  final String value1;
  final String label2;
  final String value2;

  const _InfoRow({
    required this.label1,
    required this.value1,
    required this.label2,
    required this.value2,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Row(
      children: [
        Expanded(
          flex: 3,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label1,
                style: GoogleFonts.inter(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                value1,
                style: GoogleFonts.outfit(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: colorScheme.onSurface,
                ),
              ),
            ],
          ),
        ),
        Expanded(
          flex: 2,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label2,
                style: GoogleFonts.inter(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                value2,
                style: GoogleFonts.outfit(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: colorScheme.onSurface,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
