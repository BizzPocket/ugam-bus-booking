import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:google_fonts/google_fonts.dart';
import '../config/theme.dart';
import '../controllers/tour_controller.dart';
import '../models/payment_status.dart';
import '../utils/app_snackbar.dart';

class HandlerCashScreen extends StatefulWidget {
  final String tourId;
  const HandlerCashScreen({super.key, required this.tourId});

  @override
  State<HandlerCashScreen> createState() => _HandlerCashScreenState();
}

class _HandlerCashScreenState extends State<HandlerCashScreen> {
  String _filter = 'All';

  @override
  Widget build(BuildContext context) {
    final tourCtrl = Get.find<TourController>();

    return Obx(() {
      final tour = tourCtrl.getTour(widget.tourId);
      if (tour == null) {
        return Scaffold(
          appBar: AppBar(),
          body: const Center(child: Text('Tour not found')),
        );
      }

      final allPassengers = tour.passengers;
      final pricePerSeat = tour.pricePerSeat;

      final filteredPassengers = _filter == 'Paid'
          ? allPassengers
              .where((p) => p.paymentStatus == PaymentStatus.paid)
              .toList()
          : _filter == 'Pending'
              ? allPassengers
                  .where((p) => p.paymentStatus == PaymentStatus.notPaid)
                  .toList()
              : allPassengers;

      final paidCount = allPassengers
          .where((p) => p.paymentStatus == PaymentStatus.paid)
          .length;

      final totalAmount = allPassengers.fold<double>(
          0, (sum, p) => sum + (p.requestedSeats * pricePerSeat));
      final totalCollected = allPassengers
          .where((p) => p.paymentStatus == PaymentStatus.paid)
          .fold<double>(0, (sum, p) => sum + (p.requestedSeats * pricePerSeat));
      final remaining = totalAmount - totalCollected;
      final percent = totalAmount > 0 ? totalCollected / totalAmount : 0.0;
      final percentLabel = (percent * 100).toStringAsFixed(1);

      return Scaffold(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        body: SafeArea(
          child: Column(
            children: [
              // ── Header ──────────────────────────────────────
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 8, 20, 0),
                child: Row(
                  children: [
                    IconButton(
                      onPressed: () => Get.back(),
                      icon: const Icon(
                        Icons.arrow_back,
                        color: AppTheme.textPrimary,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Cash Collection',
                            style: GoogleFonts.inter(
                              fontSize: 20,
                              fontWeight: FontWeight.w700,
                              color: AppTheme.textPrimary,
                            ),
                          ),
                          Text(
                            tour.title,
                            style: GoogleFonts.inter(
                              fontSize: 13,
                              fontWeight: FontWeight.w400,
                              color: AppTheme.textSecondary,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),

              // ── Scrollable Body ─────────────────────────────
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // ── Progress Card (Dark) ────────────────
                      Container(
                        padding: const EdgeInsets.all(24),
                        decoration: BoxDecoration(
                          color: AppTheme.brandDark,
                          borderRadius: BorderRadius.circular(6),
                          boxShadow: AppTheme.cardShadow,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'TOTAL COLLECTED',
                              style: GoogleFonts.inter(
                                fontSize: 11,
                                fontWeight: FontWeight.w500,
                                letterSpacing: 1.2,
                                color: Colors.white,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Row(
                              crossAxisAlignment:
                                  CrossAxisAlignment.baseline,
                              textBaseline: TextBaseline.alphabetic,
                              children: [
                                Text(
                                  '\u20B9${_formatAmount(totalCollected.toInt())}',
                                  style: GoogleFonts.inter(
                                    fontSize: 36,
                                    fontWeight: FontWeight.w700,
                                    color: Colors.white,
                                  ),
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  '/',
                                  style: GoogleFonts.inter(
                                    fontSize: 20,
                                    fontWeight: FontWeight.w400,
                                    color: AppTheme.textMuted,
                                  ),
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  '\u20B9${_formatAmount(totalAmount.toInt())}',
                                  style: GoogleFonts.inter(
                                    fontSize: 20,
                                    fontWeight: FontWeight.w500,
                                    color: AppTheme.textMuted,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 20),
                            ClipRRect(
                              borderRadius: BorderRadius.circular(4),
                              child: SizedBox(
                                height: 8,
                                child: LinearProgressIndicator(
                                  value: percent,
                                  backgroundColor:
                                      const Color(0xFFF1F5F9),
                                  valueColor:
                                      const AlwaysStoppedAnimation<Color>(
                                    AppTheme.success,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 12),
                            Row(
                              mainAxisAlignment:
                                  MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  '$percentLabel%',
                                  style: GoogleFonts.inter(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                    color: Colors.white,
                                  ),
                                ),
                                Text(
                                  '\u20B9${_formatAmount(remaining.toInt())} remaining',
                                  style: GoogleFonts.inter(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w400,
                                    color: AppTheme.textMuted,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(height: 16),

                      // ── Passengers Paid Card ────────────────
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 14,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(6),
                          boxShadow: AppTheme.cardShadow,
                        ),
                        child: Row(
                          children: [
                            const Icon(
                              Icons.people,
                              size: 18,
                              color: AppTheme.textSecondary,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              'Passengers Paid',
                              style: GoogleFonts.inter(
                                fontSize: 14,
                                fontWeight: FontWeight.w400,
                                color: AppTheme.textPrimary,
                              ),
                            ),
                            const Spacer(),
                            Text(
                              '$paidCount',
                              style: GoogleFonts.inter(
                                fontSize: 22,
                                fontWeight: FontWeight.w700,
                                color: AppTheme.textPrimary,
                              ),
                            ),
                            const SizedBox(width: 4),
                            Text(
                              'of ${allPassengers.length}',
                              style: GoogleFonts.inter(
                                fontSize: 13,
                                fontWeight: FontWeight.w400,
                                color: AppTheme.textSecondary,
                              ),
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(height: 24),

                      // ── Passenger List Header ───────────────
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            'Passengers',
                            style: GoogleFonts.inter(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                              color: AppTheme.textPrimary,
                            ),
                          ),
                          GestureDetector(
                            onTap: () {
                              setState(() {
                                if (_filter == 'All') {
                                  _filter = 'Paid';
                                } else if (_filter == 'Paid') {
                                  _filter = 'Pending';
                                } else {
                                  _filter = 'All';
                                }
                              });
                            },
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 5,
                              ),
                              decoration: BoxDecoration(
                                color: AppTheme.bgLight,
                                borderRadius: BorderRadius.circular(100),
                                border:
                                    Border.all(color: AppTheme.borderLight),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(
                                    Icons.filter_list,
                                    size: 12,
                                    color: AppTheme.textSecondary,
                                  ),
                                  const SizedBox(width: 4),
                                  Text(
                                    _filter,
                                    style: GoogleFonts.inter(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w500,
                                      color: AppTheme.textSecondary,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),

                      const SizedBox(height: 12),

                      // ── Passenger Items ─────────────────────
                      if (filteredPassengers.isEmpty)
                        Center(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                                vertical: 24),
                            child: Text(
                              'No passengers yet',
                              style: GoogleFonts.inter(
                                fontSize: 14,
                                color: AppTheme.textMuted,
                              ),
                            ),
                          ),
                        )
                      else
                        ...filteredPassengers.map((p) {
                          final amount =
                              (p.requestedSeats * pricePerSeat).toInt();
                          final isPaid =
                              p.paymentStatus == PaymentStatus.paid;
                          final seatLabel = p.assignedSeats.isNotEmpty
                              ? p.assignedSeats.join(', ')
                              : '${p.requestedSeats} seat${p.requestedSeats > 1 ? 's' : ''}';

                          return Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Container(
                              padding: const EdgeInsets.all(16),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(6),
                                boxShadow: AppTheme.cardShadow,
                              ),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          p.name,
                                          style: GoogleFonts.inter(
                                            fontSize: 15,
                                            fontWeight: FontWeight.w600,
                                            color: AppTheme.textPrimary,
                                          ),
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          'Seat $seatLabel \u00B7 \u20B9${_formatAmount(amount)}',
                                          style: GoogleFonts.inter(
                                            fontSize: 13,
                                            fontWeight: FontWeight.w400,
                                            color:
                                                AppTheme.textSecondary,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  if (isPaid)
                                    Container(
                                      padding:
                                          const EdgeInsets.symmetric(
                                        horizontal: 10,
                                        vertical: 5,
                                      ),
                                      decoration: BoxDecoration(
                                        color: AppTheme.successLight,
                                        borderRadius:
                                            BorderRadius.circular(100),
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          const Icon(
                                            Icons.check_circle,
                                            size: 12,
                                            color: AppTheme.success,
                                          ),
                                          const SizedBox(width: 4),
                                          Text(
                                            'Collected',
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
                                        tourCtrl
                                            .updatePassengerPayment(
                                          widget.tourId,
                                          p.id,
                                          PaymentStatus.paid,
                                        );
                                        AppSnackBar.success(
                                          '\u20B9${_formatAmount(amount)} from ${p.name}',
                                          title: 'Cash Collected',
                                        );
                                      },
                                      child: Container(
                                        padding:
                                            const EdgeInsets.symmetric(
                                          horizontal: 12,
                                          vertical: 6,
                                        ),
                                        decoration: BoxDecoration(
                                          color: AppTheme.warning,
                                          borderRadius:
                                              BorderRadius.circular(6),
                                        ),
                                        child: Text(
                                          'Collect \u20B9${_formatAmount(amount)}',
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
                            ),
                          );
                        }),

                      const SizedBox(height: 16),

                      // ── Note Row ────────────────────────────
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 12,
                        ),
                        decoration: BoxDecoration(
                          color: AppTheme.infoLight,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Row(
                          children: [
                            const Icon(
                              Icons.description_outlined,
                              size: 16,
                              color: AppTheme.info,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'All cash collected on-trip',
                                style: GoogleFonts.inter(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w400,
                                  color: AppTheme.info,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(height: 20),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    });
  }

  String _formatAmount(int amount) {
    if (amount >= 1000) {
      final str = amount.toString();
      final len = str.length;
      if (len <= 3) return str;
      final last3 = str.substring(len - 3);
      var rest = str.substring(0, len - 3);
      var result = '';
      while (rest.length > 2) {
        result = ',${rest.substring(rest.length - 2)}$result';
        rest = rest.substring(0, rest.length - 2);
      }
      return '$rest$result,$last3';
    }
    return amount.toString();
  }
}
