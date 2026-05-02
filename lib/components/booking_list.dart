import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../models/booking.dart';
import '../models/payment_status.dart';
import '../config/theme.dart';
import 'payment_toggle.dart';

class BookingList extends StatelessWidget {
  final List<Booking> bookings;

  const BookingList({super.key, required this.bookings});

  @override
  Widget build(BuildContext context) {
    if (bookings.isEmpty) {
      return _EmptyList();
    }

    return ListView.separated(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: bookings.length,
      separatorBuilder: (context, index) => const SizedBox(height: 10),
      itemBuilder: (context, index) => _BookingTile(booking: bookings[index]),
    );
  }
}

class _EmptyList extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.receipt_long_rounded,
              size: 48,
              color: theme.colorScheme.onSurface.withAlpha(60),
            ),
            const SizedBox(height: 12),
            Text(
              'No bookings found',
              style: theme.textTheme.titleMedium?.copyWith(
                color: theme.colorScheme.onSurface.withAlpha(100),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BookingTile extends StatelessWidget {
  final Booking booking;
  const _BookingTile({required this.booking});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final isPaid = booking.paymentStatus == PaymentStatus.paid;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E293B) : Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0),
        ),
      ),
      child: Row(
        children: [
          // ── Avatar ──
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  theme.colorScheme.primary.withAlpha(isDark ? 60 : 40),
                  theme.colorScheme.secondary.withAlpha(isDark ? 60 : 40),
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(12),
            ),
            alignment: Alignment.center,
            child: Text(
              booking.customerName.isNotEmpty
                  ? booking.customerName[0].toUpperCase()
                  : '?',
              style: GoogleFonts.outfit(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: theme.colorScheme.primary,
              ),
            ),
          ),

          const SizedBox(width: 12),

          // ── Details ──
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  booking.customerName,
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontSize: 15,
                  ),
                ),
                const SizedBox(height: 3),
                Row(
                  children: [
                    Icon(
                      Icons.directions_bus_rounded,
                      size: 12,
                      color: theme.colorScheme.onSurface.withAlpha(100),
                    ),
                    const SizedBox(width: 3),
                    Flexible(
                      child: Text(
                        booking.busId,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurface.withAlpha(100),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Icon(
                      Icons.event_seat_rounded,
                      size: 12,
                      color: theme.colorScheme.onSurface.withAlpha(100),
                    ),
                    const SizedBox(width: 3),
                    Flexible(
                      child: Text(
                        booking.seatNumbers.join(', '),
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurface.withAlpha(100),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),

          const SizedBox(width: 8),

          // ── Status + Toggle ──
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: isPaid
                      ? AppTheme.success.withAlpha(15)
                      : AppTheme.warning.withAlpha(15),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  booking.paymentStatus.displayName,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: isPaid ? AppTheme.success : AppTheme.warning,
                  ),
                ),
              ),
              PaymentToggle(
                bookingId: booking.id,
                currentStatus: booking.paymentStatus,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
