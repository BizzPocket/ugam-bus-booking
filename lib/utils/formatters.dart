import 'package:intl/intl.dart';

class Formatters {
  static String formatDateTime(DateTime dateTime) {
    // Pin the locale to 'en_US' so the AM/PM ('a') marker always renders;
    // it is locale-dependent and comes out empty under some locales (e.g. gu).
    return DateFormat('MMM dd, yyyy hh:mm a', 'en_US').format(dateTime);
  }

  static String formatSeatDetails(List<String> seats) {
    if (seats.isEmpty) return 'No seats';
    return seats.join(', ');
  }

  static String formatCurrency(double amount) {
    return NumberFormat.currency(symbol: '\$', decimalDigits: 2).format(amount);
  }
}
