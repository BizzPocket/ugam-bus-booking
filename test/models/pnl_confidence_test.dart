import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/money_summary.dart';
import 'package:occubusbooking/models/pnl_confidence.dart';
import 'package:occubusbooking/models/tour_status.dart';

TourMoneySummary _summary({
  double collected = 0,
  double billed = 109200,
  double expenses = 50000,
  int busesMissingRent = 0,
}) =>
    TourMoneySummary(
      totalCollected: collected,
      totalRevenueBilled: billed,
      totalExpenses: expenses,
      totalHandedOver: 0,
      totalToReturn: 0,
      totalToCollect: billed - collected,
      busesMissingRent: busesMissingRent,
    );

void main() {
  group('PnlConfidence', () {
    // The reported case: seats assigned, trip not departed, nothing collected.
    // The billed net is a forecast off the seat chart, not an outcome.
    test('is projected while the trip is active and nothing is collected', () {
      final c = PnlConfidence.of(_summary(), TourStatus.assigning);
      expect(c.isProjected, isTrue);
      expect(c.isProvisional, isTrue);
    });

    test('is not projected once cash has been collected', () {
      final c = PnlConfidence.of(
        _summary(collected: 5000),
        TourStatus.locked,
      );
      expect(c.isProjected, isFalse);
    });

    test('is not projected once the trip is completed', () {
      final c = PnlConfidence.of(_summary(), TourStatus.completed);
      expect(c.isProjected, isFalse);
    });

    test('a completed, collected trip carries no caveat at all', () {
      final c = PnlConfidence.of(
        _summary(collected: 109200),
        TourStatus.completed,
      );
      expect(c.isProvisional, isFalse);
      expect(c.costsIncomplete, isFalse);
    });

    // Orthogonal to the projection rule: a missing rent overstates the net
    // whether or not the trip has concluded.
    test('flags incomplete costs when a bus has no rent recorded', () {
      final c = PnlConfidence.of(
        _summary(collected: 109200, busesMissingRent: 1),
        TourStatus.completed,
      );
      expect(c.costsIncomplete, isTrue);
      expect(c.isProjected, isFalse);
      expect(c.isProvisional, isTrue);
    });
  });
}
