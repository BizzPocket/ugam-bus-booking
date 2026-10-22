import 'package:intl/intl.dart';

class Formatters {
  // PERF: constructing a NumberFormat/DateFormat parses its pattern and loads
  // locale symbols — ~5us a call on a desktop, several times that on the
  // low-end phones this app runs on, and these run once per ROW on every money
  // and roster screen. One instance per (pattern, resolved locale) is reused;
  // the locale is part of the key, so switching language still switches the
  // output. Bounded: a handful of patterns x 3 app locales.
  static final Map<String, DateFormat> _dateFormats = {};
  static final Map<String, NumberFormat> _numberFormats = {};

  static DateFormat _date(String pattern, String? locale) {
    final resolved = Intl.verifiedLocale(
      locale ?? Intl.getCurrentLocale(),
      DateFormat.localeExists,
      onFailure: (_) => 'en_US',
    );
    return _dateFormats.putIfAbsent(
      '$pattern|$resolved',
      () => DateFormat(pattern, locale),
    );
  }

  static String formatDateTime(DateTime dateTime) {
    // Pin the locale to 'en_US' so the AM/PM ('a') marker always renders;
    // it is locale-dependent and comes out empty under some locales (e.g. gu).
    return _date('MMM dd, yyyy hh:mm a', 'en_US').format(dateTime);
  }

  static String formatSeatDetails(List<String> seats) {
    if (seats.isEmpty) return 'No seats';
    return seats.join(', ');
  }

  static String formatCurrency(double amount) {
    final key = 'usd|${Intl.getCurrentLocale()}';
    return _numberFormats
        .putIfAbsent(
          key,
          () => NumberFormat.currency(symbol: '\$', decimalDigits: 2),
        )
        .format(amount);
  }

  /// Canonical Indian-rupee formatter: `₹1,23,456` (lakh grouping, no decimals).
  /// One place for the whole app — replaces the per-screen `_money()` helpers
  /// that diverged on sign and grouping.
  static String formatMoneyInr(num amount) {
    final rounded = amount.round();
    final n = _numberFormats
        .putIfAbsent('inr', () => NumberFormat.decimalPattern('en_IN'))
        .format(rounded.abs());
    final sign = rounded < 0 ? '-' : '';
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
    return _date('d MMM', locale).format(date);
  }

  /// Localized day-month-year, e.g. `12 Jun 2026`.
  static String formatDateMedium(DateTime date, {String? locale}) {
    return _date('d MMM yyyy', locale).format(date);
  }
}
