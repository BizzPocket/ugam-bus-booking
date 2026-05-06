import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../models/passenger.dart';
import '../models/payment_status.dart';
import '../config/theme.dart';

class PassengerTile extends StatelessWidget {
  final Passenger passenger;
  final VoidCallback? onTap;
  final VoidCallback? onPaymentToggle;
  final VoidCallback? onMakeHandler;
  final VoidCallback? onRemove;

  const PassengerTile({
    super.key,
    required this.passenger,
    this.onTap,
    this.onPaymentToggle,
    this.onMakeHandler,
    this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final isPaid = passenger.paymentStatus == PaymentStatus.paid;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF1E293B) : Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: passenger.isHandler
                ? AppTheme.brand.withAlpha(60)
                : (isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0)),
            width: passenger.isHandler ? 1.5 : 1,
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
                  colors: passenger.isHandler
                      ? [AppTheme.brand.withAlpha(60), AppTheme.brand.withAlpha(40)]
                      : [
                          theme.colorScheme.primary.withAlpha(isDark ? 60 : 40),
                          theme.colorScheme.secondary.withAlpha(isDark ? 60 : 40),
                        ],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(12),
              ),
              alignment: Alignment.center,
              child: passenger.isHandler
                  ? const Icon(Icons.star_rounded, color: AppTheme.brand, size: 20)
                  : Text(
                      passenger.name.isNotEmpty
                          ? passenger.name[0].toUpperCase()
                          : '?',
                      style: GoogleFonts.outfit(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: theme.colorScheme.primary,
                      ),
                    ),
            ),

            const SizedBox(width: 12),

            // ── Info ──
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          passenger.name,
                          style: theme.textTheme.titleLarge?.copyWith(fontSize: 15),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (passenger.isHandler) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: AppTheme.brand.withAlpha(15),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: const Text(
                            'HANDLER',
                            style: TextStyle(
                              fontSize: 9,
                              fontWeight: FontWeight.w800,
                              color: AppTheme.brand,
                              letterSpacing: 0.5,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      Icon(Icons.phone_rounded,
                          size: 12,
                          color: theme.colorScheme.onSurface.withAlpha(100)),
                      const SizedBox(width: 3),
                      Text(
                        passenger.phone,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurface.withAlpha(100),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Icon(Icons.event_seat_rounded,
                          size: 12,
                          color: theme.colorScheme.onSurface.withAlpha(100)),
                      const SizedBox(width: 3),
                      Text(
                        passenger.assignedSeats.isNotEmpty
                            ? passenger.assignedSeats
                                .map((a) => a.seatId)
                                .join(', ')
                            : passenger.requestSummary,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: passenger.assignedSeats.isNotEmpty
                              ? AppTheme.success
                              : theme.colorScheme.onSurface.withAlpha(100),
                          fontWeight: passenger.assignedSeats.isNotEmpty
                              ? FontWeight.w600
                              : FontWeight.w400,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),

            // ── Payment status ──
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: isPaid
                    ? AppTheme.success.withAlpha(15)
                    : AppTheme.warning.withAlpha(15),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                isPaid ? 'Paid' : 'Due',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: isPaid ? AppTheme.success : AppTheme.warning,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
