import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:google_fonts/google_fonts.dart';

import '../config/theme.dart';
import '../models/tour.dart';
import '../models/tour_status.dart';
import '../screens/requests_screen.dart';
import '../screens/assign_screen.dart';
import '../screens/seat_assignment_screen.dart';
import '../screens/notify_screen.dart';
import '../screens/handler_cash_screen.dart';
import '../screens/broadcast_template_screen.dart';

class TourPipelineCard extends StatelessWidget {
  final Tour tour;
  final VoidCallback onStateAdvance;

  const TourPipelineCard({
    super.key,
    required this.tour,
    required this.onStateAdvance,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    final currentStep = tour.status.stepIndex;

    return Container(
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E293B) : Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: colorScheme.outline),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withAlpha(isDark ? 50 : 20),
            blurRadius: 16,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC),
              borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
              border: Border(bottom: BorderSide(color: colorScheme.outline)),
            ),
            child: Row(
              children: [
                Icon(Icons.rocket_launch_rounded, color: AppTheme.brand, size: 20),
                const SizedBox(width: 8),
                Text(
                  'Mission Control',
                  style: GoogleFonts.outfit(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: colorScheme.onSurface,
                  ),
                ),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: AppTheme.brand.withAlpha(30),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    'Step ${currentStep + 1} of 6',
                    style: GoogleFonts.inter(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.brand,
                    ),
                  ),
                ),
              ],
            ),
          ),
          
          Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Render the elegant timeline nodes
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: List.generate(6, (index) {
                    final isActive = index == currentStep;
                    final isPast = index < currentStep;
                    
                    return Expanded(
                      child: Row(
                        children: [
                          Container(
                            width: isActive ? 24 : 16,
                            height: isActive ? 24 : 16,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: isPast || isActive ? AppTheme.brand : colorScheme.surface,
                              border: Border.all(
                                color: isPast || isActive ? AppTheme.brand : colorScheme.outline,
                                width: 2,
                              ),
                              boxShadow: isActive ? [
                                BoxShadow(
                                  color: AppTheme.brand.withAlpha(100),
                                  blurRadius: 8,
                                  spreadRadius: 2,
                                )
                              ] : null,
                            ),
                            child: isPast ? const Icon(Icons.check, size: 10, color: Colors.white) : null,
                          ),
                          if (index < 5)
                            Expanded(
                              child: Container(
                                height: 2,
                                color: isPast ? AppTheme.brand : colorScheme.outline,
                              ),
                            ),
                        ],
                      ),
                    );
                  }),
                ),
                const SizedBox(height: 24),
                
                // Content mapped to action
                _buildActionArea(context),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActionArea(BuildContext context) {
    String title = '';
    String description = '';
    String btnText = '';
    IconData btnIcon = Icons.arrow_forward_rounded;
    VoidCallback onAction = () {};

    switch (tour.status) {
      case TourStatus.planning:
        title = 'Broadcast to Contacts';
        description = 'Your tour is drafted. Edit your WhatsApp message, then blast it to all contacts to collect interest.';
        btnText = 'Edit & Broadcast';
        btnIcon = Icons.campaign_rounded;
        onAction = () {
          Get.to(() => BroadcastTemplateScreen(tour: tour));
        };
        break;
      case TourStatus.collecting:
        title = 'Collect AI WhatsApp Requests';
        description = 'The AI is parsing incoming WhatsApp messages and extracting seat counts.';
        btnText = 'View Requests';
        btnIcon = Icons.mark_chat_unread_rounded;
        onAction = () {
          Get.to(() => const RequestsScreen());
          // Automatically advance to the next visual step just for UI flow demo
          onStateAdvance();
        };
        break;
      case TourStatus.booked:
        title = 'Source & Input Bus Details';
        description = 'Requests are pooled. Call the bus owner to book a bus, then input the driver and vehicle info.';
        btnText = 'Source Bus';
        btnIcon = Icons.directions_bus_rounded;
        onAction = () {
          Get.to(() => const AssignScreen());
          onStateAdvance();
        };
        break;
      case TourStatus.assigning:
        title = 'Assign Passenger Seats';
        description = 'Bus sourced. Assign the requested physical seats to each passenger so they know where to sit.';
        btnText = 'Seat Map Layout';
        btnIcon = Icons.airline_seat_recline_normal_rounded;
        onAction = () {
          Get.to(() => SeatAssignmentScreen(tourId: tour.id));
          onStateAdvance();
        };
        break;
      case TourStatus.locked:
        title = 'Nominate Handler & Lock';
        description = 'Appoint one passenger as the Handler to collect cash. Lock the seats and notify everyone via WhatsApp.';
        btnText = 'Lock Tour & Notify';
        btnIcon = Icons.lock_person_rounded;
        onAction = () {
          Get.to(() => const NotifyScreen());
          onStateAdvance(); // Completed
        };
        break;
      case TourStatus.completed:
        title = 'Handler Cash Collection';
        description = 'The passengers have been notified. The handler can now open the checklist to collect cash on the bus.';
        btnText = 'Open Checklist';
        btnIcon = Icons.account_balance_wallet_rounded;
        onAction = () {
          Get.to(() => HandlerCashScreen(tourId: tour.id));
        };
        break;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: GoogleFonts.outfit(
            fontSize: 17,
            fontWeight: FontWeight.w600,
            color: Theme.of(context).colorScheme.onSurface,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          description,
          style: GoogleFonts.inter(
            fontSize: 12,
            height: 1.5,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            onPressed: onAction,
            icon: Icon(btnIcon, size: 18),
            label: Text(btnText, style: GoogleFonts.inter(fontWeight: FontWeight.w600)),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.brandDark,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
        ),
      ],
    );
  }
}
