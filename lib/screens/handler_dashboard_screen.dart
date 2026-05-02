import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:google_fonts/google_fonts.dart';
import '../config/theme.dart';
import '../controllers/tour_controller.dart';
import '../utils/app_snackbar.dart';
import '../models/tour.dart';

class HandlerDashboardScreen extends StatefulWidget {
  const HandlerDashboardScreen({super.key});

  @override
  State<HandlerDashboardScreen> createState() => _HandlerDashboardScreenState();
}

class _HandlerDashboardScreenState extends State<HandlerDashboardScreen> {
  int _activeTab = 0;

  // Sample data shown when no real handler-assigned tour exists
  static const List<Map<String, dynamic>> _samplePassengers = [
    {
      'name': 'Aarav Sharma',
      'seat': '1A',
      'phone': '+91 98765 43210',
      'amount': 3000,
      'paid': true,
      'status': 'Confirmed - Boarding Pass Sent',
    },
    {
      'name': 'Priya Patel',
      'seat': '1B',
      'phone': '+91 87654 32109',
      'amount': 3000,
      'paid': true,
      'status': 'Confirmed - Boarding Pass Sent',
    },
    {
      'name': 'Rohan Gupta',
      'seat': '2A',
      'phone': '+91 76543 21098',
      'amount': 3000,
      'paid': false,
      'status': 'Pending payment',
    },
    {
      'name': 'Sneha Reddy',
      'seat': '2B',
      'phone': '+91 65432 10987',
      'amount': 3000,
      'paid': false,
      'status': 'Pending payment',
    },
  ];

  @override
  Widget build(BuildContext context) {
    final tourCtrl = Get.find<TourController>();

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: SafeArea(
        child: Obx(() {
          // Find a tour where the current user is handler
          // For now, find any tour that has a handlerId set
          final Tour? handlerTour = tourCtrl.tours.firstWhereOrNull(
            (t) => t.handlerId != null && t.status.name != 'completed',
          );

          final bool usingSampleData = handlerTour == null;

          // Derive display values from real tour or sample data
          final String tourTitle;
          final String handlerLabel;
          final String dateLabel;
          final List<Map<String, dynamic>> passengers;
          final int totalPassengers;
          final int paidPassengers;
          final double pricePerSeat;

          if (!usingSampleData) {
            final tour = handlerTour;
            tourTitle = tour.title;
            final handler = tour.handler;
            handlerLabel = 'Handled by ${handler?.name ?? 'Unknown'}';
            final months = [
              'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
              'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
            ];
            final dep = tour.departureDate;
            dateLabel = '${months[dep.month - 1]} ${dep.day}, ${dep.year}';
            pricePerSeat = tour.pricePerSeat;
            totalPassengers = tour.passengers.length;
            paidPassengers = tour.paidCount;

            passengers = tour.passengers.map((p) {
              final isPaid = p.paymentStatus.name == 'paid';
              final seatLabel = p.assignedSeats.isNotEmpty
                  ? p.assignedSeats.join(', ')
                  : 'Unassigned';
              return {
                'name': p.name,
                'seat': seatLabel,
                'phone': p.phone,
                'amount': tour.pricePerSeat.toInt(),
                'paid': isPaid,
                'status': isPaid
                    ? 'Confirmed - Boarding Pass Sent'
                    : 'Pending payment',
              };
            }).toList();
          } else {
            tourTitle = 'Sample: Jaipur Heritage Tour';
            handlerLabel = 'Handled by Rajesh Kumar (sample)';
            dateLabel = 'Apr 5, 2026';
            pricePerSeat = 3000;
            totalPassengers = 12;
            paidPassengers = 8;
            passengers = _samplePassengers;
          }

          final double collected = usingSampleData
              ? 24000
              : paidPassengers * pricePerSeat;
          final double total = usingSampleData
              ? 36000
              : totalPassengers * pricePerSeat;
          final double pending = total - collected;
          final double progress = total > 0 ? collected / total : 0.0;
          final int displayPassengerCount = usingSampleData ? 12 : totalPassengers;

          return Stack(
            children: [
              SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 80),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // -- Header --
                    if (usingSampleData)
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        margin: const EdgeInsets.only(bottom: 12),
                        decoration: BoxDecoration(
                          color: AppTheme.warningLight,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          'Showing sample data - no handler-assigned tours found',
                          style: GoogleFonts.inter(
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                            color: AppTheme.warning,
                          ),
                        ),
                      ),
                    Text(
                      tourTitle,
                      style: GoogleFonts.inter(
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                        color: AppTheme.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      handlerLabel,
                      style: GoogleFonts.inter(
                        fontSize: 14,
                        fontWeight: FontWeight.w400,
                        color: AppTheme.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: AppTheme.brand,
                        borderRadius: BorderRadius.circular(100),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.calendar_today,
                            size: 12,
                            color: Colors.white,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            dateLabel,
                            style: GoogleFonts.inter(
                              fontSize: 11,
                              fontWeight: FontWeight.w500,
                              color: Colors.white,
                            ),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 20),

                    // -- Stats Row --
                    Row(
                      children: [
                        Expanded(
                          child: _StatCard(
                            bgColor: AppTheme.brandLight,
                            value: '$displayPassengerCount',
                            valueColor: AppTheme.brand,
                            valueFontSize: 24,
                            label: 'PASSENGERS',
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: _StatCard(
                            bgColor: AppTheme.successLight,
                            value: _formatCurrency(collected),
                            valueColor: AppTheme.success,
                            valueFontSize: 18,
                            label: 'COLLECTED',
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: _StatCard(
                            bgColor: AppTheme.warningLight,
                            value: _formatCurrency(pending),
                            valueColor: AppTheme.warning,
                            valueFontSize: 18,
                            label: 'PENDING',
                          ),
                        ),
                      ],
                    ),

                    const SizedBox(height: 24),

                    // -- Passenger List --
                    ...passengers.map((p) => Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: AppTheme.borderLight),
                          boxShadow: AppTheme.cardShadow,
                        ),
                        child: Column(
                          children: [
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        p['name'] as String,
                                        style: GoogleFonts.inter(
                                          fontSize: 15,
                                          fontWeight: FontWeight.w600,
                                          color: AppTheme.textPrimary,
                                        ),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        'Seat ${p['seat']} · ₹${p['amount']}',
                                        style: GoogleFonts.inter(
                                          fontSize: 13,
                                          fontWeight: FontWeight.w400,
                                          color: AppTheme.textSecondary,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                if (p['paid'] as bool)
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 5,
                                    ),
                                    decoration: BoxDecoration(
                                      color: AppTheme.successLight,
                                      borderRadius: BorderRadius.circular(100),
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(
                                          Icons.check,
                                          size: 12,
                                          color: AppTheme.success,
                                        ),
                                        const SizedBox(width: 4),
                                        Text(
                                          '₹${p['amount']}',
                                          style: GoogleFonts.inter(
                                            fontSize: 12,
                                            fontWeight: FontWeight.w600,
                                            color: AppTheme.success,
                                          ),
                                        ),
                                      ],
                                    ),
                                  )
                                else
                                  GestureDetector(
                                    onTap: () {
                                      AppSnackBar.success('₹${p['amount']} from ${p['name']}', title: 'Cash Collected');
                                    },
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 12,
                                        vertical: 6,
                                      ),
                                      decoration: BoxDecoration(
                                        color: AppTheme.warning,
                                        borderRadius: BorderRadius.circular(6),
                                      ),
                                      child: Text(
                                        'Collect Cash',
                                        style: GoogleFonts.inter(
                                          fontSize: 12,
                                          fontWeight: FontWeight.w600,
                                          color: Colors.white,
                                        ),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                            const SizedBox(height: 10),
                            Row(
                              children: [
                                Icon(
                                  Icons.phone,
                                  size: 12,
                                  color: AppTheme.textMuted,
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  p['phone'] as String,
                                  style: GoogleFonts.inter(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w400,
                                    color: AppTheme.textSecondary,
                                  ),
                                ),
                                const SizedBox(width: 16),
                                Expanded(
                                  child: Text(
                                    p['status'] as String,
                                    style: GoogleFonts.inter(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w500,
                                      color: (p['paid'] as bool)
                                          ? AppTheme.success
                                          : AppTheme.warning,
                                    ),
                                    textAlign: TextAlign.right,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    )),

                    const SizedBox(height: 20),

                    // -- Collection Progress Card --
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: AppTheme.brandDark,
                        borderRadius: BorderRadius.circular(6),
                        boxShadow: AppTheme.cardShadow,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'COLLECTION PROGRESS',
                            style: GoogleFonts.inter(
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 1,
                              color: Colors.white,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            '${(progress * 100).round()}%',
                            style: GoogleFonts.inter(
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                              color: Colors.white,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '${_formatCurrency(collected)} / ${_formatCurrency(total)} collected',
                            style: GoogleFonts.inter(
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                              color: Colors.white,
                            ),
                          ),
                          const SizedBox(height: 12),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(3),
                            child: SizedBox(
                              height: 6,
                              child: LinearProgressIndicator(
                                value: progress,
                                backgroundColor: const Color(0xFFF1F5F9),
                                valueColor: const AlwaysStoppedAnimation<Color>(
                                  AppTheme.success,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 10),
                          Text(
                            '$paidPassengers of $displayPassengerCount passengers paid · ${_formatCurrency(pending)} remaining',
                            style: GoogleFonts.inter(
                              fontSize: 12,
                              fontWeight: FontWeight.w400,
                              color: AppTheme.textMuted,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),

              // -- Bottom Tab Nav --
              Positioned(
                left: 20,
                right: 20,
                bottom: 16,
                child: Container(
                  height: 48,
                  decoration: BoxDecoration(
                    color: AppTheme.brandDark,
                    borderRadius: BorderRadius.circular(100),
                    boxShadow: AppTheme.cardShadow,
                  ),
                  child: Row(
                    children: [
                      _TabItem(
                        label: 'HOME',
                        icon: Icons.home_rounded,
                        isActive: _activeTab == 0,
                        onTap: () => setState(() => _activeTab = 0),
                      ),
                      _TabItem(
                        label: 'PASSENGERS',
                        icon: Icons.people_rounded,
                        isActive: _activeTab == 1,
                        onTap: () => setState(() => _activeTab = 1),
                      ),
                      _TabItem(
                        label: 'COLLECTION',
                        icon: Icons.account_balance_wallet_rounded,
                        isActive: _activeTab == 2,
                        onTap: () => setState(() => _activeTab = 2),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          );
        }),
      ),
    );
  }

  String _formatCurrency(double amount) {
    if (amount >= 100000) {
      return '₹${(amount / 1000).toStringAsFixed(0)}K';
    }
    return '₹${amount.toStringAsFixed(0).replaceAllMapped(RegExp(r'(\d)(?=(\d{3})+$)'), (m) => '${m[1]},')}';
  }
}

class _StatCard extends StatelessWidget {
  final Color bgColor;
  final String value;
  final Color valueColor;
  final double valueFontSize;
  final String label;

  const _StatCard({
    required this.bgColor,
    required this.value,
    required this.valueColor,
    required this.valueFontSize,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        children: [
          Text(
            value,
            style: GoogleFonts.inter(
              fontSize: valueFontSize,
              fontWeight: FontWeight.w700,
              color: valueColor,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: GoogleFonts.inter(
              fontSize: 9,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.8,
              color: AppTheme.textMuted,
            ),
          ),
        ],
      ),
    );
  }
}

class _TabItem extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool isActive;
  final VoidCallback onTap;

  const _TabItem({
    required this.label,
    required this.icon,
    required this.isActive,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          margin: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: isActive
                ? Colors.white.withValues(alpha: 0.15)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(100),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 16,
                color: isActive ? Colors.white : Colors.white.withValues(alpha: 0.5),
              ),
              const SizedBox(height: 2),
              Text(
                label,
                style: GoogleFonts.inter(
                  fontSize: 9,
                  fontWeight: isActive ? FontWeight.w600 : FontWeight.w500,
                  color: isActive
                      ? Colors.white
                      : Colors.white.withValues(alpha: 0.5),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
