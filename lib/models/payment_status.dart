import 'package:easy_localization/easy_localization.dart';

enum PaymentStatus { paid, notPaid }

extension PaymentStatusExtension on PaymentStatus {
  String get displayName {
    switch (this) {
      case PaymentStatus.paid:
        return tr('enums.payment_status.paid');
      case PaymentStatus.notPaid:
        return tr('enums.payment_status.pending');
    }
  }
}
