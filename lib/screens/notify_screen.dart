import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:google_fonts/google_fonts.dart';
import '../config/theme.dart';
import '../controllers/tour_controller.dart';
import '../models/tour.dart';
import '../utils/app_snackbar.dart';
import '../services/whatsapp_service.dart';

class NotifyScreen extends StatelessWidget {
  const NotifyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final tourCtrl = Get.find<TourController>();

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: SafeArea(
        child: Obx(() {
          // Find first active tour (not completed)
          final Tour? tour = tourCtrl.tours.firstWhereOrNull(
            (t) => t.status.name != 'completed',
          );

          if (tour == null) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(40),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.notifications_off_rounded,
                      size: 48,
                      color: AppTheme.textMuted,
                    ),
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
                      'Create a tour first to send notifications.',
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

          final tourName = tour.title;
          final busNo = tour.busDetails?.busNumber ?? 'Not assigned';
          final totalSeats = tour.busDetails?.totalSeats.toString() ?? '-';
          final driverName = tour.busDetails?.driverName ?? 'Not assigned';
          final handlerPhone = tour.handler?.phone ?? 'Not assigned';

          // Format date range
          final months = [
            'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
            'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
          ];
          final depDate = tour.departureDate;
          String tourDate = '${months[depDate.month - 1]} ${depDate.day}';
          if (tour.returnDate != null) {
            final ret = tour.returnDate!;
            tourDate += '–${ret.day}';
          }

          // Passengers with assigned seats
          final assignedPassengers = tour.passengers
              .where((p) => p.assignedSeats.isNotEmpty)
              .toList();

          return SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // -- Summary Card --
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: AppTheme.cardLight,
                    borderRadius: BorderRadius.circular(6),
                    boxShadow: AppTheme.cardShadow,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        tourName,
                        style: GoogleFonts.inter(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: AppTheme.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 14),
                      Row(
                        children: [
                          _SummaryBox(label: 'DATE', value: tourDate),
                          const SizedBox(width: 10),
                          _SummaryBox(label: 'BUS NO.', value: busNo),
                          const SizedBox(width: 10),
                          _SummaryBox(label: 'SEATS', value: totalSeats),
                        ],
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 24),

                // -- Passenger Assignments --
                Text(
                  'PASSENGER ASSIGNMENTS',
                  style: GoogleFonts.inter(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 1,
                    color: AppTheme.textMuted,
                  ),
                ),
                const SizedBox(height: 12),
                if (assignedPassengers.isEmpty)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(6),
                      boxShadow: AppTheme.cardShadow,
                    ),
                    child: Center(
                      child: Text(
                        'No seats assigned yet',
                        style: GoogleFonts.inter(
                          fontSize: 13,
                          color: AppTheme.textMuted,
                        ),
                      ),
                    ),
                  )
                else
                  ...assignedPassengers.map((p) => Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 12,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(6),
                        boxShadow: AppTheme.cardShadow,
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.check_circle,
                            size: 18,
                            color: AppTheme.success,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              p.name,
                              style: GoogleFonts.inter(
                                fontSize: 14,
                                fontWeight: FontWeight.w500,
                                color: AppTheme.textPrimary,
                              ),
                            ),
                          ),
                          Text(
                            'Seat ${p.assignedSeats.join(', ')}',
                            style: GoogleFonts.inter(
                              fontSize: 11,
                              fontWeight: FontWeight.w500,
                              color: AppTheme.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  )),

                const SizedBox(height: 24),

                // -- Notification Preview --
                Text(
                  'NOTIFICATION PREVIEW',
                  style: GoogleFonts.inter(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 1,
                    color: AppTheme.textMuted,
                  ),
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: AppTheme.brandDark,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.message,
                            size: 16,
                            color: const Color(0xFF25D366),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            'WhatsApp Message',
                            style: GoogleFonts.inter(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: const Color(0xFF25D366),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Divider(color: const Color(0xFF334155), height: 1),
                      const SizedBox(height: 12),
                      Text(
                        'Your seat is confirmed!\n\n'
                        'Tour: $tourName\n'
                        'Dates: $tourDate\n'
                        'Bus: $busNo\n'
                        'Driver: $driverName\n'
                        'Seat: ${assignedPassengers.isNotEmpty ? assignedPassengers.first.assignedSeats.join(', ') : '-'}\n'
                        'Handler: $handlerPhone\n\n'
                        'Have a wonderful trip!',
                        style: GoogleFonts.inter(
                          fontSize: 13,
                          fontWeight: FontWeight.w400,
                          color: Colors.white,
                          height: 1.5,
                        ),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 24),

                // -- CTA Button --
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: ElevatedButton(
                    onPressed: () async {
                      if (assignedPassengers.isEmpty) {
                        AppSnackBar.error('No passengers with assigned seats to notify.');
                        return;
                      }
                      final wa = WhatsAppService();
                      // Copy broadcast message to clipboard for WhatsApp Business
                      await wa.copyBroadcastToClipboard(
                        tour: tour,
                        busNumber: tour.busDetails?.busNumber,
                        driverName: tour.busDetails?.driverName,
                        driverPhone: tour.busDetails?.driverPhone,
                        handlerPhone: tour.handler?.phone,
                      );
                      // Also open WhatsApp for the first passenger
                      final sent = await wa.sendToPassenger(
                        passenger: assignedPassengers.first,
                        tour: tour,
                        busNumber: tour.busDetails?.busNumber,
                        driverName: tour.busDetails?.driverName,
                        driverPhone: tour.busDetails?.driverPhone,
                        handlerPhone: tour.handler?.phone,
                      );
                      if (sent) {
                        AppSnackBar.success(
                          'WhatsApp opened for ${assignedPassengers.first.name}. '
                          'Broadcast message copied to clipboard for remaining ${assignedPassengers.length - 1} passengers.',
                          title: 'Seats Locked',
                        );
                      } else {
                        AppSnackBar.error('Could not open WhatsApp. Is it installed?');
                      }
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.brand,
                      foregroundColor: Colors.white,
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(6),
                      ),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.lock, size: 18),
                        const SizedBox(width: 8),
                        Text(
                          'Lock Seats & Send Notifications',
                          style: GoogleFonts.inter(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: Colors.white,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                const SizedBox(height: 20),
              ],
            ),
          );
        }),
      ),
    );
  }
}

class _SummaryBox extends StatelessWidget {
  final String label;
  final String value;

  const _SummaryBox({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 10),
        decoration: BoxDecoration(
          color: AppTheme.bgLight,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: GoogleFonts.inter(
                fontSize: 9,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.8,
                color: AppTheme.textMuted,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              value,
              style: GoogleFonts.inter(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: AppTheme.textPrimary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
