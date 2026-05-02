import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';

import '../config/theme.dart';
import '../controllers/auth_controller.dart';
import '../controllers/tour_controller.dart';
import '../models/tour.dart';
import '../models/passenger.dart';
import '../models/payment_status.dart';

/// Home screen for passengers — shows only their bookings and seat status.
class PassengerHomeScreen extends StatelessWidget {
  const PassengerHomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final auth = Get.find<AuthController>();
    final tourCtrl = Get.find<TourController>();
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: isDark ? AppTheme.bgDark : AppTheme.bgLight,
      body: SafeArea(
        child: Obx(() {
          final phone = auth.userPhone.value;

          // Find all tours where this phone number is a passenger
          final myBookings = <_BookingInfo>[];
          for (final tour in tourCtrl.tours) {
            for (final p in tour.passengers) {
              if (_phoneMatches(p.phone, phone)) {
                myBookings.add(_BookingInfo(tour: tour, passenger: p));
              }
            }
          }

          return CustomScrollView(
            physics: const BouncingScrollPhysics(),
            slivers: [
              // ── Header ─────────────────────────────────────
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'My Bookings',
                              style: GoogleFonts.inter(
                                fontSize: 28,
                                fontWeight: FontWeight.w700,
                                color: isDark
                                    ? Colors.white
                                    : AppTheme.textPrimary,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              phone.isNotEmpty
                                  ? '+91 $phone'
                                  : 'Welcome',
                              style: GoogleFonts.inter(
                                fontSize: 14,
                                color: AppTheme.textMuted,
                              ),
                            ),
                          ],
                        ),
                      ),
                      GestureDetector(
                        onTap: () => auth.logout(),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 8),
                          decoration: BoxDecoration(
                            color: AppTheme.dangerLight,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.logout_rounded,
                                  size: 16, color: AppTheme.danger),
                              const SizedBox(width: 6),
                              Text(
                                'Logout',
                                style: GoogleFonts.inter(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: AppTheme.danger,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              const SliverToBoxAdapter(child: SizedBox(height: 24)),

              // ── Summary Card ───────────────────────────────
              if (myBookings.isNotEmpty)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: _SummaryCard(bookings: myBookings, isDark: isDark),
                  ),
                ),

              const SliverToBoxAdapter(child: SizedBox(height: 24)),

              // ── Booking List ────────────────────────────────
              if (myBookings.isEmpty)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 24, vertical: 60),
                    child: Center(
                      child: Column(
                        children: [
                          Icon(
                            Icons.confirmation_number_outlined,
                            size: 64,
                            color: AppTheme.textMuted.withAlpha(80),
                          ),
                          const SizedBox(height: 16),
                          Text(
                            'No Bookings Found',
                            style: GoogleFonts.inter(
                              fontSize: 20,
                              fontWeight: FontWeight.w700,
                              color: isDark
                                  ? Colors.white
                                  : AppTheme.textPrimary,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Your phone number is not linked to any tour bookings yet. Contact your tour agent to get booked.',
                            textAlign: TextAlign.center,
                            style: GoogleFonts.inter(
                              fontSize: 14,
                              color: AppTheme.textMuted,
                              height: 1.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                )
              else
                SliverPadding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  sliver: SliverList(
                    delegate: SliverChildBuilderDelegate(
                      (_, i) => Padding(
                        padding: const EdgeInsets.only(bottom: 16),
                        child: _BookingCard(
                          booking: myBookings[i],
                          isDark: isDark,
                        ),
                      ),
                      childCount: myBookings.length,
                    ),
                  ),
                ),

              const SliverToBoxAdapter(child: SizedBox(height: 40)),
            ],
          );
        }),
      ),
    );
  }

  /// Match phone numbers loosely (last 10 digits).
  bool _phoneMatches(String passengerPhone, String userPhone) {
    final clean1 = passengerPhone.replaceAll(RegExp(r'[^\d]'), '');
    final clean2 = userPhone.replaceAll(RegExp(r'[^\d]'), '');
    if (clean1.isEmpty || clean2.isEmpty) return false;
    final last10a =
        clean1.length >= 10 ? clean1.substring(clean1.length - 10) : clean1;
    final last10b =
        clean2.length >= 10 ? clean2.substring(clean2.length - 10) : clean2;
    return last10a == last10b;
  }
}

// ── Data holder ──────────────────────────────────────────────────────

class _BookingInfo {
  final Tour tour;
  final Passenger passenger;
  const _BookingInfo({required this.tour, required this.passenger});
}

// ── Summary Card ─────────────────────────────────────────────────────

class _SummaryCard extends StatelessWidget {
  final List<_BookingInfo> bookings;
  final bool isDark;

  const _SummaryCard({required this.bookings, required this.isDark});

  @override
  Widget build(BuildContext context) {
    final totalSeats =
        bookings.fold<int>(0, (s, b) => s + b.passenger.requestedSeats);
    final assignedSeats =
        bookings.fold<int>(0, (s, b) => s + b.passenger.assignedSeats.length);
    final paidCount = bookings
        .where((b) => b.passenger.paymentStatus == PaymentStatus.paid)
        .length;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: AppTheme.brandGradient,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          _SummaryItem(
            value: '${bookings.length}',
            label: 'Tours',
          ),
          _divider(),
          _SummaryItem(
            value: '$assignedSeats/$totalSeats',
            label: 'Seats',
          ),
          _divider(),
          _SummaryItem(
            value: '$paidCount/${bookings.length}',
            label: 'Paid',
          ),
        ],
      ),
    );
  }

  Widget _divider() {
    return Container(
      width: 1,
      height: 36,
      margin: const EdgeInsets.symmetric(horizontal: 12),
      color: Colors.white.withAlpha(50),
    );
  }
}

class _SummaryItem extends StatelessWidget {
  final String value;
  final String label;

  const _SummaryItem({required this.value, required this.label});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        children: [
          Text(
            value,
            style: GoogleFonts.inter(
              fontSize: 22,
              fontWeight: FontWeight.w700,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: GoogleFonts.inter(
              fontSize: 11,
              fontWeight: FontWeight.w500,
              color: Colors.white.withAlpha(180),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Booking Card ─────────────────────────────────────────────────────

class _BookingCard extends StatelessWidget {
  final _BookingInfo booking;
  final bool isDark;

  const _BookingCard({required this.booking, required this.isDark});

  @override
  Widget build(BuildContext context) {
    final tour = booking.tour;
    final p = booking.passenger;
    final isPaid = p.paymentStatus == PaymentStatus.paid;
    final hasSeats = p.assignedSeats.isNotEmpty;
    final totalCost = tour.pricePerSeat * p.requestedSeats;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.cardDark : Colors.white,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: isDark ? AppTheme.borderDark : AppTheme.borderLight,
        ),
        boxShadow: isDark ? [] : AppTheme.cardShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Tour title + status
          Row(
            children: [
              Expanded(
                child: Text(
                  tour.title,
                  style: GoogleFonts.inter(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    color: isDark ? Colors.white : AppTheme.textPrimary,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: _statusBg(tour.status.name),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  tour.status.displayName,
                  style: GoogleFonts.inter(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    color: _statusFg(tour.status.name),
                  ),
                ),
              ),
            ],
          ),

          const SizedBox(height: 10),

          // Route + Date
          Row(
            children: [
              const Icon(Icons.location_on_outlined,
                  size: 14, color: AppTheme.textMuted),
              const SizedBox(width: 4),
              Text(
                tour.route,
                style: GoogleFonts.inter(
                  fontSize: 13,
                  color: AppTheme.textSecondary,
                ),
              ),
              const SizedBox(width: 16),
              const Icon(Icons.calendar_today_outlined,
                  size: 13, color: AppTheme.textMuted),
              const SizedBox(width: 4),
              Text(
                DateFormat('MMM d, yyyy').format(tour.departureDate),
                style: GoogleFonts.inter(
                  fontSize: 13,
                  color: AppTheme.textSecondary,
                ),
              ),
            ],
          ),

          const SizedBox(height: 14),
          const Divider(height: 1, color: AppTheme.borderLight),
          const SizedBox(height: 14),

          // Seat info
          Row(
            children: [
              // Seats
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'SEATS',
                      style: GoogleFonts.inter(
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.8,
                        color: AppTheme.textMuted,
                      ),
                    ),
                    const SizedBox(height: 4),
                    if (hasSeats)
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: p.assignedSeats
                            .map((s) => Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 10, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: AppTheme.brandLight,
                                    borderRadius: BorderRadius.circular(4),
                                    border: Border.all(
                                        color: AppTheme.brand, width: 1.2),
                                  ),
                                  child: Text(
                                    s,
                                    style: GoogleFonts.inter(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w700,
                                      color: AppTheme.brand,
                                    ),
                                  ),
                                ))
                            .toList(),
                      )
                    else
                      Text(
                        '${p.requestedSeats} seat${p.requestedSeats > 1 ? "s" : ""} requested \u2022 pending assignment',
                        style: GoogleFonts.inter(
                          fontSize: 13,
                          color: AppTheme.warning,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),

          const SizedBox(height: 14),

          // Payment + Bus info row
          Row(
            children: [
              // Payment status
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: isPaid ? AppTheme.successLight : AppTheme.warningLight,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      isPaid
                          ? Icons.check_circle_outline
                          : Icons.access_time_rounded,
                      size: 13,
                      color: isPaid ? AppTheme.success : AppTheme.warning,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      isPaid ? 'Paid' : 'Payment Pending',
                      style: GoogleFonts.inter(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: isPaid ? AppTheme.success : AppTheme.warning,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              // Amount
              Text(
                '\u20B9${totalCost.toStringAsFixed(0)}',
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: isDark ? Colors.white : AppTheme.textPrimary,
                ),
              ),
              const Spacer(),
              // Bus info
              if (tour.busDetails != null)
                Row(
                  children: [
                    const Icon(Icons.directions_bus_outlined,
                        size: 14, color: AppTheme.textMuted),
                    const SizedBox(width: 4),
                    Text(
                      tour.busDetails!.busNumber,
                      style: GoogleFonts.inter(
                        fontSize: 12,
                        color: AppTheme.textSecondary,
                      ),
                    ),
                  ],
                ),
            ],
          ),

          // Handler info
          if (tour.handler != null) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                const Icon(Icons.support_agent_rounded,
                    size: 14, color: AppTheme.textMuted),
                const SizedBox(width: 4),
                Text(
                  'Handler: ${tour.handler!.name} \u2022 ${tour.handler!.phone}',
                  style: GoogleFonts.inter(
                    fontSize: 12,
                    color: AppTheme.textSecondary,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Color _statusBg(String status) {
    switch (status) {
      case 'completed':
        return AppTheme.successLight;
      case 'locked':
        return AppTheme.dangerLight;
      case 'assigning':
        return AppTheme.warningLight;
      default:
        return AppTheme.brandLight;
    }
  }

  Color _statusFg(String status) {
    switch (status) {
      case 'completed':
        return AppTheme.success;
      case 'locked':
        return AppTheme.danger;
      case 'assigning':
        return AppTheme.warning;
      default:
        return AppTheme.brand;
    }
  }
}
