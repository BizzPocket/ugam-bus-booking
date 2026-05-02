import 'package:flutter/material.dart';
import 'package:get/get.dart';
import '../models/payment_status.dart';
import '../controllers/booking_controller.dart';
import '../config/theme.dart';
import 'platform_dialog.dart';

class PaymentToggle extends StatelessWidget {
  final String bookingId;
  final PaymentStatus currentStatus;

  const PaymentToggle({
    super.key,
    required this.bookingId,
    required this.currentStatus,
  });

  @override
  Widget build(BuildContext context) {
    final controller = Get.find<BookingController>();
    final isPaid = currentStatus == PaymentStatus.paid;

    return SizedBox(
      width: 32,
      height: 32,
      child: IconButton(
        padding: EdgeInsets.zero,
        iconSize: 20,
        icon: Icon(
          isPaid ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
          color: isPaid ? AppTheme.success : AppTheme.warning,
        ),
        onPressed: () async {
          final confirm = await showConfirmDialog(
            context,
            title: isPaid ? 'Mark as Pending?' : 'Mark as Paid?',
            content: isPaid
                ? 'This will mark the booking as pending payment.'
                : 'This will mark the booking as paid.',
          );
          if (confirm) {
            controller.updatePaymentStatus(
              bookingId,
              isPaid ? PaymentStatus.notPaid : PaymentStatus.paid,
            );
          }
        },
      ),
    );
  }
}
