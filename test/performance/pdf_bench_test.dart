import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/chart_footer.dart';
import 'package:occubusbooking/services/seat_chart_pdf.dart';

import 'money_summary_bench_test.dart' show bigTour;

/// Microbenchmark (prints only): how long the A4 chart PDF build holds the UI
/// isolate for a full 4-bus trip, and one per-passenger single-bus page.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('BENCH seat chart PDF build', () async {
    final tour = bigTour();
    const footer = ChartFooter(
      boardingPlace: 'Surat',
      departureTime: '5 PM',
      note: 'Handler',
    );
    // First call pays the one-off font parse.
    final cold = Stopwatch()..start();
    await SeatChartPdf.buildTourChartPdf(tour: tour, footer: footer);
    cold.stop();

    final warm = Stopwatch()..start();
    await SeatChartPdf.buildTourChartPdf(tour: tour, footer: footer);
    warm.stop();

    final one = Stopwatch()..start();
    for (var i = 0; i < 5; i++) {
      await SeatChartPdf.buildTourChartPdf(
        tour: tour,
        footer: footer,
        onlyBusId: 'b0',
        fitOnePage: true,
      );
    }
    one.stop();
    // ignore: avoid_print
    print('BENCH pdf 4-bus cold=${cold.elapsedMilliseconds}ms '
        'warm=${warm.elapsedMilliseconds}ms '
        'per-passenger page=${(one.elapsedMilliseconds / 5).toStringAsFixed(0)}ms');
  });
}
