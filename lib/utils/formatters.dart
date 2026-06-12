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

  /// Canonical Indian-rupee formatter: `₹1,23,456` (lakh grouping, no decimals).
  /// One place for the whole app — replaces the per-screen `_money()` helpers
  /// that diverged on sign and grouping.
  static String formatMoneyInr(num amount) {
    final n = NumberFormat.decimalPattern('en_IN').format(amount.round().abs());
    final sign = amount < 0 ? '-' : '';
    return '$sign₹$n';
  }

  /// Compact rupee for dense stat/hero tiles: `₹999`, `₹1.2K`, `₹1.2L`, `₹1.2Cr`.
  static String formatMoneyInrCompact(num amount) {
    final a = amount.abs();
    final sign = amount < 0 ? '-' : '';
    String body;
    if (a >= 10000000) {
      body = '${(a / 10000000).toStringAsFixed(1)}Cr';
    } else if (a >= 100000) {
      body = '${(a / 100000).toStringAsFixed(1)}L';
    } else if (a >= 1000) {
      body = '${(a / 1000).toStringAsFixed(1)}K';
    } else {
      body = a.round().toString();
    }
    // Drop a trailing ".0" (₹1.0K → ₹1K).
    body = body.replaceAll('.0', '');
    return '$sign₹$body';
  }

  /// Localized short date, e.g. `12 Jun` (en) / `12 જૂન` (gu) / `12 जून` (hi).
  /// Pass `context.locale.languageCode` so month names follow the app locale —
  /// replaces the hardcoded English month arrays scattered across screens.
  static String formatDateShort(DateTime date, {String? locale}) {
    return DateFormat('d MMM', locale).format(date);
  }

  /// Localized day-month-year, e.g. `12 Jun 2026`.
  static String formatDateMedium(DateTime date, {String? locale}) {
    return DateFormat('d MMM yyyy', locale).format(date);
  }
}
