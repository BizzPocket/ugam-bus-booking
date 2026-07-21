import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/controllers/money_controller.dart';

void main() {
  test('outstandingHandoverFor reads the per-tour snapshot cache', () {
    final c = MoneyController();
    // No snapshot yet → null (distinct from 0 "settled").
    expect(c.outstandingHandoverFor('t9'), isNull);
    c.settlementByTour['t9'] = 4200.0;
    expect(c.outstandingHandoverFor('t9'), 4200.0);
  });
}
