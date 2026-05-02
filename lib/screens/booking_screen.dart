import 'package:flutter/material.dart';
import 'package:get/get.dart';
import '../components/booking_form.dart';
import '../components/seat_map.dart';
import '../controllers/booking_controller.dart';
import '../controllers/bus_controller.dart';
import 'main_shell.dart';

class BookingScreen extends StatelessWidget {
  const BookingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final bookingCtrl = Get.find<BookingController>();
    final busCtrl = Get.find<BusController>();
    final shell = Get.find<ShellController>();
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return SafeArea(
      bottom: false,
      child: CustomScrollView(
        physics: const BouncingScrollPhysics(),
        slivers: [
          // ── Header ──────────────────────────────────────────
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'New Booking',
                    style: theme.textTheme.headlineLarge,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Enter details below to create a booking',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurface.withAlpha(120),
                    ),
                  ),
                ],
              ),
            ),
          ),

          // ── Booking Form Card ────────────────────────────────
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
              child: BookingForm(),
            ),
          ),

          // ── Seat Map Section ─────────────────────────────────
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 28, 24, 0),
              child: Obx(() {
                if (busCtrl.buses.isEmpty) {
                  return Container(
                    padding: const EdgeInsets.all(28),
                    decoration: BoxDecoration(
                      color: isDark ? const Color(0xFF1E293B) : Colors.white,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: isDark
                            ? const Color(0xFF334155)
                            : const Color(0xFFE2E8F0),
                      ),
                    ),
                    child: Column(
                      children: [
                        Icon(
                          Icons.event_seat_rounded,
                          size: 48,
                          color: theme.colorScheme.primary.withAlpha(100),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'No buses configured',
                          style: theme.textTheme.titleLarge,
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'Add a bus in the Fleet tab to view the seat map',
                          style: theme.textTheme.bodyMedium,
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 20),
                        SizedBox(
                          height: 44,
                          child: OutlinedButton.icon(
                            onPressed: () => shell.switchTab(3),
                            icon: const Icon(Icons.directions_bus_rounded,
                                size: 18),
                            label: const Text('Go to Fleet'),
                          ),
                        ),
                      ],
                    ),
                  );
                }

                final bus = busCtrl.buses.first;
                final bookedSeats = bookingCtrl
                    .getBookingsByBus(bus.id)
                    .map((b) => b.seatNumbers)
                    .expand((e) => e)
                    .toList();

                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.event_seat_rounded,
                            size: 20, color: theme.colorScheme.primary),
                        const SizedBox(width: 8),
                        Text('Seat Map', style: theme.textTheme.headlineSmall),
                        const Spacer(),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.primary.withAlpha(15),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            bus.name,
                            style: theme.textTheme.titleSmall?.copyWith(
                              color: theme.colorScheme.primary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    SeatMap(
                      totalSeats: bus.totalCapacity,
                      bookedSeats: bookedSeats,
                      onSeatTap: (_) {},
                    ),
                  ],
                );
              }),
            ),
          ),

          const SliverToBoxAdapter(child: SizedBox(height: 100)),
        ],
      ),
    );
  }
}
