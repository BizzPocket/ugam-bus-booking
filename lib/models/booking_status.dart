import 'package:easy_localization/easy_localization.dart';

enum BookingStatus { confirmed, cancelled, completed }

extension BookingStatusExtension on BookingStatus {
  String get displayName {
    switch (this) {
      case BookingStatus.confirmed:
        return tr('enums.booking_status.confirmed');
      case BookingStatus.cancelled:
        return tr('enums.booking_status.cancelled');
      case BookingStatus.completed:
        return tr('enums.booking_status.completed');
    }
  }
}
