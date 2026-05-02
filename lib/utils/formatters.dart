import 'package:intl/intl.dart';

class Formatters {
  static String formatDateTime(DateTime dateTime) {
    return DateFormat('MMM dd, yyyy hh:mm a').format(dateTime);
  }

  static String formatSeatDetails(List<String> seats) {
    if (seats.isEmpty) return 'No seats';
    return seats.join(', ');
  }

  static String formatCurrency(double amount) {
    return NumberFormat.currency(symbol: '\$', decimalDigits: 2).format(amount);
  }
}
