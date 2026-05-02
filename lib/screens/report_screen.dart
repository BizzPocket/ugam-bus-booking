import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:google_fonts/google_fonts.dart';
import 'dart:math' as math;
import '../controllers/tour_controller.dart';
import '../models/tour_status.dart';
import '../models/payment_status.dart';
import '../config/theme.dart';
import '../utils/app_snackbar.dart';

class ReportScreen extends StatelessWidget {
  const ReportScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final tourCtrl = Get.find<TourController>();

    return SafeArea(
      bottom: false,
      child: Obx(() {
        final tours = tourCtrl.tours;
        final totalTours = tours.length;

        // Passenger aggregation
        final allPassengers = tours.expand((t) => t.passengers).toList();
        final totalPassengers = allPassengers.length;
        final paidCount = allPassengers
            .where((p) => p.paymentStatus == PaymentStatus.paid)
            .length;
        final pendingCount = totalPassengers - paidCount;

        // Revenue: sum of pricePerSeat * passengers.length per tour
        final totalRevenue = tours.fold<double>(
          0,
          (sum, t) => sum + (t.pricePerSeat * t.passengers.length),
        );

        // Status breakdown
        final statusCounts = <TourStatus, int>{};
        for (final status in TourStatus.values) {
          final count = tours.where((t) => t.status == status).length;
          if (count > 0) statusCounts[status] = count;
        }

        return CustomScrollView(
          physics: const BouncingScrollPhysics(),
          slivers: [
            // -- Header --
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Reports',
                          style: GoogleFonts.inter(
                            fontSize: 28,
                            fontWeight: FontWeight.w700,
                            color: AppTheme.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Tour analytics overview',
                          style: GoogleFonts.inter(
                            fontSize: 14,
                            fontWeight: FontWeight.w400,
                            color: AppTheme.textMuted,
                          ),
                        ),
                      ],
                    ),
                    OutlinedButton.icon(
                      onPressed: () {
                        final csvLines = <String>[
                          'Tour,Route,Status,Passengers,Paid,Pending,Revenue',
                        ];
                        for (final t in tours) {
                          final paid = t.passengers
                              .where((p) => p.paymentStatus == PaymentStatus.paid)
                              .length;
                          final rev = t.pricePerSeat * t.passengers.length;
                          csvLines.add(
                            '"${t.title}","${t.route}","${t.status.displayName}",'
                            '${t.passengers.length},$paid,${t.passengers.length - paid},'
                            '${rev.toStringAsFixed(0)}',
                          );
                        }
                        Clipboard.setData(ClipboardData(text: csvLines.join('\n')));
                        AppSnackBar.success(
                          'Report CSV copied to clipboard. Paste into any spreadsheet app.',
                          title: 'Report Exported',
                        );
                      },
                      icon: const Icon(Icons.copy_rounded, size: 18),
                      label: const Text('Export'),
                    ),
                  ],
                ),
              ),
            ),

            // -- Overview Metrics Row --
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 28, 24, 0),
                child: _CardContainer(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Overview',
                        style: GoogleFonts.inter(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                          color: AppTheme.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 20),
                      Row(
                        children: [
                          Expanded(
                            child: _MetricTile(
                              label: 'Total Tours',
                              value: totalTours.toString(),
                              color: AppTheme.brand,
                              bgColor: const Color(0xFFEFF6FF),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: _MetricTile(
                              label: 'Passengers',
                              value: totalPassengers.toString(),
                              color: AppTheme.info,
                              bgColor: AppTheme.infoLight,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: _MetricTile(
                              label: 'Paid',
                              value: paidCount.toString(),
                              color: AppTheme.success,
                              bgColor: AppTheme.successLight,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: _MetricTile(
                              label: 'Pending',
                              value: pendingCount.toString(),
                              color: AppTheme.warning,
                              bgColor: AppTheme.warningLight,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),

            // -- Payment Collection Progress --
            if (totalPassengers > 0)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
                  child: _CardContainer(
                    child: _PaymentProgressBar(
                      paid: paidCount,
                      total: totalPassengers,
                    ),
                  ),
                ),
              ),

            // -- Revenue Card --
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
                child: _CardContainer(
                  child: Row(
                    children: [
                      Container(
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                          color: AppTheme.successLight,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: const Icon(
                          Icons.currency_rupee_rounded,
                          color: AppTheme.success,
                          size: 24,
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Estimated Revenue',
                              style: GoogleFonts.inter(
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                                color: AppTheme.textMuted,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              _formatCurrency(totalRevenue),
                              style: GoogleFonts.inter(
                                fontSize: 24,
                                fontWeight: FontWeight.w700,
                                color: AppTheme.textPrimary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

            // -- Tour Status Breakdown --
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 28, 24, 12),
                child: Text(
                  'Tour Breakdown by Status',
                  style: GoogleFonts.inter(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.textPrimary,
                  ),
                ),
              ),
            ),

            if (totalTours == 0)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: _CardContainer(
                    child: Column(
                      children: [
                        Icon(
                          Icons.bar_chart_rounded,
                          size: 48,
                          color: AppTheme.brand.withValues(alpha: 0.3),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'No tours yet',
                          style: GoogleFonts.inter(
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                            color: AppTheme.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'Create your first tour to see analytics',
                          style: GoogleFonts.inter(
                            fontSize: 14,
                            fontWeight: FontWeight.w400,
                            color: AppTheme.textMuted,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              )
            else
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: _CardContainer(
                    child: Column(
                      children: [
                        // Visual bar chart
                        if (totalTours > 0) ...[
                          ...TourStatus.values.map((status) {
                            final count = statusCounts[status] ?? 0;
                            final pct =
                                totalTours > 0 ? count / totalTours : 0.0;
                            return _StatusBarRow(
                              status: status,
                              count: count,
                              total: totalTours,
                              pct: pct,
                            );
                          }),
                        ],
                      ],
                    ),
                  ),
                ),
              ),

            // -- Per-Tour Revenue Breakdown --
            if (tours.isNotEmpty) ...[
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 28, 24, 12),
                  child: Text(
                    'Revenue by Tour',
                    style: GoogleFonts.inter(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.textPrimary,
                    ),
                  ),
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                sliver: SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (_, i) {
                      final tour = tours[i];
                      final revenue =
                          tour.pricePerSeat * tour.passengers.length;
                      final tourPaid = tour.passengers
                          .where(
                              (p) => p.paymentStatus == PaymentStatus.paid)
                          .length;
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: _TourRevenueCard(
                          title: tour.title,
                          route: tour.route,
                          passengerCount: tour.passengers.length,
                          paidCount: tourPaid,
                          revenue: revenue,
                          status: tour.status,
                        ),
                      );
                    },
                    childCount: tours.length,
                  ),
                ),
              ),
            ],

            const SliverToBoxAdapter(child: SizedBox(height: 100)),
          ],
        );
      }),
    );
  }

  static String _formatCurrency(double amount) {
    if (amount >= 100000) {
      return '\u20B9${(amount / 1000).toStringAsFixed(1)}K';
    }
    return '\u20B9${amount.toStringAsFixed(0)}';
  }
}

// -- Card Container with two-layer shadow, rounded 6 --

class _CardContainer extends StatelessWidget {
  final Widget child;

  const _CardContainer({required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(6),
        boxShadow: const [
          BoxShadow(
            color: Color(0x08000000),
            offset: Offset(0, 1),
            blurRadius: 3,
          ),
          BoxShadow(
            color: Color(0x0A000000),
            offset: Offset(0, 8),
            blurRadius: 24,
          ),
        ],
      ),
      child: child,
    );
  }
}

// -- Metric Tile --

class _MetricTile extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  final Color bgColor;

  const _MetricTile({
    required this.label,
    required this.value,
    required this.color,
    required this.bgColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            value,
            style: GoogleFonts.inter(
              fontSize: 28,
              fontWeight: FontWeight.w800,
              color: color,
              height: 1,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: GoogleFonts.inter(
              fontSize: 11,
              fontWeight: FontWeight.w500,
              color: color.withValues(alpha: 0.7),
            ),
          ),
        ],
      ),
    );
  }
}

// -- Payment Progress Bar --

class _PaymentProgressBar extends StatelessWidget {
  final int paid;
  final int total;

  const _PaymentProgressBar({
    required this.paid,
    required this.total,
  });

  @override
  Widget build(BuildContext context) {
    final pct = total > 0 ? paid / total : 0.0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'Payment Collection',
              style: GoogleFonts.inter(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: AppTheme.textSecondary,
              ),
            ),
            Text(
              '$paid / $total paid  \u2022  ${(pct * 100).toStringAsFixed(0)}%',
              style: GoogleFonts.inter(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: AppTheme.success,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: LinearProgressIndicator(
            value: pct,
            minHeight: 10,
            backgroundColor: const Color(0xFFE2E8F0),
            valueColor: const AlwaysStoppedAnimation(AppTheme.success),
          ),
        ),
      ],
    );
  }
}

// -- Status Bar Row --

class _StatusBarRow extends StatelessWidget {
  final TourStatus status;
  final int count;
  final int total;
  final double pct;

  const _StatusBarRow({
    required this.status,
    required this.count,
    required this.total,
    required this.pct,
  });

  Color get _statusColor {
    switch (status) {
      case TourStatus.planning:
        return AppTheme.textMuted;
      case TourStatus.collecting:
        return AppTheme.brand;
      case TourStatus.booked:
        return AppTheme.info;
      case TourStatus.assigning:
        return AppTheme.warning;
      case TourStatus.locked:
        return AppTheme.danger;
      case TourStatus.completed:
        return AppTheme.success;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: _statusColor,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    status.displayName,
                    style: GoogleFonts.inter(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: AppTheme.textPrimary,
                    ),
                  ),
                ],
              ),
              Text(
                '$count',
                style: GoogleFonts.inter(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: _statusColor,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: pct,
              minHeight: 6,
              backgroundColor: const Color(0xFFE2E8F0),
              valueColor: AlwaysStoppedAnimation(_statusColor),
            ),
          ),
        ],
      ),
    );
  }
}

// -- Tour Revenue Card --

class _TourRevenueCard extends StatelessWidget {
  final String title;
  final String route;
  final int passengerCount;
  final int paidCount;
  final double revenue;
  final TourStatus status;

  const _TourRevenueCard({
    required this.title,
    required this.route,
    required this.passengerCount,
    required this.paidCount,
    required this.revenue,
    required this.status,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(6),
        boxShadow: const [
          BoxShadow(
            color: Color(0x08000000),
            offset: Offset(0, 1),
            blurRadius: 3,
          ),
          BoxShadow(
            color: Color(0x0A000000),
            offset: Offset(0, 8),
            blurRadius: 24,
          ),
        ],
      ),
      child: Row(
        children: [
          // Ring indicator for payment ratio
          SizedBox(
            width: 48,
            height: 48,
            child: CustomPaint(
              painter: _RingPainter(
                pct: passengerCount > 0 ? paidCount / passengerCount : 0.0,
                color: AppTheme.success,
                bgColor: const Color(0xFFE2E8F0),
              ),
              child: Center(
                child: Text(
                  passengerCount > 0
                      ? '${((paidCount / passengerCount) * 100).toStringAsFixed(0)}%'
                      : '0%',
                  style: GoogleFonts.inter(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.success,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: GoogleFonts.inter(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.textPrimary,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  '$route  \u2022  $passengerCount pax',
                  style: GoogleFonts.inter(
                    fontSize: 12,
                    fontWeight: FontWeight.w400,
                    color: AppTheme.textMuted,
                  ),
                ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                '\u20B9${revenue.toStringAsFixed(0)}',
                style: GoogleFonts.inter(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: AppTheme.textPrimary,
                ),
              ),
              const SizedBox(height: 2),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: _statusBgColor(status),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  status.displayName,
                  style: GoogleFonts.inter(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    color: _statusFgColor(status),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Color _statusBgColor(TourStatus s) {
    switch (s) {
      case TourStatus.planning:
        return const Color(0xFFF1F5F9);
      case TourStatus.collecting:
        return AppTheme.brandLight;
      case TourStatus.booked:
        return AppTheme.infoLight;
      case TourStatus.assigning:
        return AppTheme.warningLight;
      case TourStatus.locked:
        return AppTheme.dangerLight;
      case TourStatus.completed:
        return AppTheme.successLight;
    }
  }

  Color _statusFgColor(TourStatus s) {
    switch (s) {
      case TourStatus.planning:
        return AppTheme.textMuted;
      case TourStatus.collecting:
        return AppTheme.brand;
      case TourStatus.booked:
        return AppTheme.info;
      case TourStatus.assigning:
        return AppTheme.warning;
      case TourStatus.locked:
        return AppTheme.danger;
      case TourStatus.completed:
        return AppTheme.success;
    }
  }
}

// -- Ring Painter --

class _RingPainter extends CustomPainter {
  final double pct;
  final Color color;
  final Color bgColor;

  _RingPainter({
    required this.pct,
    required this.color,
    required this.bgColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 4;
    const strokeWidth = 4.0;

    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..color = bgColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth,
    );

    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -math.pi / 2,
      2 * math.pi * pct,
      false,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(covariant _RingPainter old) =>
      old.pct != pct || old.color != color;
}
