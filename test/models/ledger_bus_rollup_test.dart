import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/ledger_bus_rollup.dart';

void main() {
  group('LedgerBusRollup.fromMap', () {
    test('parses minor columns into rupees', () {
      final r = LedgerBusRollup.fromMap({
        'tour_id': 't1',
        'bus_id': 'b1',
        'outstanding_handover_minor': 150000,
        'billed_minor': 200000,
        'income_minor': 5000,
        'ground_expenses_minor': 20000,
        'rent_minor': 50000,
        'owner_unpaid_minor': 50000,
        'collected_minor': 180000,
        'handed_over_minor': 10000,
        'to_collect_minor': 25000,
        'to_return_minor': 0,
      });

      expect(r.tourId, 't1');
      expect(r.busId, 'b1');
      expect(r.outstandingHandover, 1500);
      expect(r.billed, 2000);
      expect(r.income, 50);
      expect(r.groundExpenses, 200);
      expect(r.rent, 500);
      expect(r.collected, 1800);
      expect(r.handedOver, 100);
      expect(r.toCollect, 250);
      expect(r.toReturn, 0);
      expect(r.expensesTotal, 700);
    });

    test('null bus_id stays null (tour-level orphan bucket)', () {
      final r = LedgerBusRollup.fromMap({
        'tour_id': 't1',
        'bus_id': null,
        'outstanding_handover_minor': 0,
        'billed_minor': 0,
        'income_minor': 0,
        'ground_expenses_minor': 0,
        'rent_minor': 0,
        'owner_unpaid_minor': 0,
        'collected_minor': 0,
        'handed_over_minor': 0,
        'to_collect_minor': 0,
        'to_return_minor': 0,
      });
      expect(r.busId, isNull);
    });
  });

  group('LedgerBusRollup.toBusMoneySummary', () {
    test('maps ledger fields onto BusMoneySummary getters', () {
      final r = LedgerBusRollup(
        tourId: 't1',
        busId: 'b1',
        outstandingHandover: 1500,
        billed: 2000,
        income: 50,
        groundExpenses: 200,
        rent: 500,
        // expected = collected + income − ground = 1650; handed 150 → outstanding 1500
        collected: 1800,
        handedOver: 150,
        toCollect: 250,
        toReturn: 0,
      );
      final s = r.toBusMoneySummary();
      expect(s.busId, 'b1');
      expect(s.collected, 1800);
      expect(s.revenueBilled, 2000);
      expect(s.income, 50);
      expect(s.busRent, 500);
      expect(s.expensesTotal, 700);
      expect(s.handedOver, 150);
      expect(s.toCollectTotal, 250);
      expect(s.toReturnTotal, 0);
      expect(s.expectedHandover, 1650);
      expect(s.outstandingHandover, closeTo(1500, 0.001));
      expect(s.outstandingHandover, closeTo(r.outstandingHandover, 0.001));
    });
  });
}
