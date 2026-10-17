import 'package:easy_localization/easy_localization.dart';

enum PaymentStatus { paid, notPaid }

extension PaymentStatusExtension on PaymentStatus {
  String get displayName => switch (this) {
        PaymentStatus.paid => tr('enums.payment_status.paid'),
        PaymentStatus.notPaid => tr('enums.payment_status.pending'),
      };
}
