import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:occubusbooking/utils/formatters.dart';

/// PERF pin: the money/date formatters run once per row on every money and
/// roster screen. They now reuse one NumberFormat/DateFormat per locale; these
/// tests prove the output is unchanged and still follows the locale.
void main() {
  setUpAll(() async {
    await initializeDateFormatting('en');
    await initializeDateFormatting('gu');
    await initializeDateFormatting('hi');
  });

  test('formatMoneyInr output unchanged (lakh grouping, sign, rounding)', () {
    expect(Formatters.formatMoneyInr(0), '₹0');
    expect(Formatters.formatMoneyInr(123456), '₹1,23,456');
    expect(Formatters.formatMoneyInr(-1500.6), '-₹1,501');
    expect(Formatters.formatMoneyInr(99.4), '₹99');
  });

  test('date formatters still follow the locale passed per call', () {
    final d = DateTime(2026, 6, 12);
    expect(Formatters.formatDateShort(d, locale: 'en'),
        DateFormat('d MMM', 'en').format(d));
    expect(Formatters.formatDateShort(d, locale: 'gu'),
        DateFormat('d MMM', 'gu').format(d));
    expect(Formatters.formatDateShort(d, locale: 'gu'),
        isNot(Formatters.formatDateShort(d, locale: 'en')));
    expect(Formatters.formatDateMedium(d, locale: 'hi'),
        DateFormat('d MMM yyyy', 'hi').format(d));
  });

  test('null locale follows Intl.defaultLocale changes', () {
    final d = DateTime(2026, 6, 12);
    final prev = Intl.defaultLocale;
    addTearDown(() => Intl.defaultLocale = prev);
    Intl.defaultLocale = 'en';
    final en = Formatters.formatDateShort(d);
    Intl.defaultLocale = 'gu';
    final gu = Formatters.formatDateShort(d);
    expect(en, DateFormat('d MMM', 'en').format(d));
    expect(gu, DateFormat('d MMM', 'gu').format(d));
    expect(Formatters.formatCurrency(12.5), r'$12.50');
  });

  test('BENCH formatter calls', () {
    final d = DateTime(2026, 7, 1);
    double per(void Function(int) f) {
      for (var i = 0; i < 200; i++) {
        f(i);
      }
      final sw = Stopwatch()..start();
      for (var i = 0; i < 2000; i++) {
        f(i);
      }
      return sw.elapsedMicroseconds / 2000;
    }

    final money = per((i) => Formatters.formatMoneyInr(i * 137));
    final date = per((_) => Formatters.formatDateShort(d, locale: 'en'));
    // ignore: avoid_print
    print('BENCH formatMoneyInr=${money.toStringAsFixed(2)}us '
        'formatDateShort=${date.toStringAsFixed(2)}us per call');
  });
}
