enum PaymentStatus { paid, notPaid }

extension PaymentStatusExtension on PaymentStatus {
  String get displayName {
    switch (this) {
      case PaymentStatus.paid:
        return 'Paid';
      case PaymentStatus.notPaid:
        return 'Pending';
    }
  }
}
