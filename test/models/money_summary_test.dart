import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/collection.dart';
import 'package:occubusbooking/models/expense.dart';
import 'package:occubusbooking/models/bus_handover.dart';
import 'package:occubusbooking/models/money_summary.dart';

void main() {
  group('money summary', () {
    // bus1 rows.
    final collections = [
      // +50 to return.
      Collection(
        tourId: 't1',
        busId: 'bus1',
        passengerId: 'p1',
        amountDue: 1550,
        amountReceived: 1600,
      ),
      // -400 to collect.
      Collection(
        tourId: 't1',
        busId: 'bus1',
        passengerId: 'p2',
        amountDue: 900,
        amountReceived: 500,
      ),
      // bus2 row — must NOT affect bus1's summary.
      Collection(
        tourId: 't1',
        busId: 'bus2',
        passengerId: 'p3',
        amountDue: 700,
        amountReceived: 700,
      ),
    ];

    final expenses = [
      Expense(
        tourId: 't1',
        busId: 'bus1',
        amount: 5000,
        category: ExpenseCategory.driver,
        label: 'Driver',
      ),
      Expense(
        tourId: 't1',
        busId: 'bus1',
        amount: 3000,
        category: ExpenseCategory.fuel,
        label: 'Fuel',
      ),
      // bus2 row — must NOT affect bus1's summary.
      Expense(
        tourId: 't1',
        busId: 'bus2',
        amount: 1000,
        category: ExpenseCategory.other,
        label: 'Misc',
      ),
    ];

    final handovers = [
      BusHandover(
        tourId: 't1',
        busId: 'bus1',
        handedOverAmount: 1000,
        expectedAmount: -5900,
      ),
    ];

    test('BusMoneySummary.compute filters by busId', () {
      final s = BusMoneySummary.compute(
        busId: 'bus1',
        collections: collections,
        expenses: expenses,
        handovers: handovers,
      );
      expect(s.collected, 2100); // 1600 + 500
      expect(s.expensesTotal, 8000); // 5000 + 3000
      expect(s.expectedHandover, -5900); // 2100 - 8000
      expect(s.handedOver, 1000);
      expect(s.outstandingHandover, -6900); // -5900 - 1000
      expect(s.toReturnTotal, 50);
      expect(s.toCollectTotal, 400);
    });

    test('TourMoneySummary.compute sums across both buses', () {
      final t = TourMoneySummary.compute(
        collections: collections,
        expenses: expenses,
        handovers: handovers,
      );
      // 1600 + 500 + 700
      expect(t.totalCollected, 2800);
      // 5000 + 3000 + 1000
      expect(t.totalExpenses, 9000);
      expect(t.totalNet, 2800 - 9000);
      expect(t.totalHandedOver, 1000);
    });

    test('bus rent is INSIDE the handover expectation (handler settles owner)',
        () {
      final s = BusMoneySummary.compute(
        busId: 'bus1',
        collections: collections,
        expenses: expenses,
        handovers: const [],
        busRent: 20000,
      );
      // ground 8000 + rent 20000 folded into expensesTotal.
      expect(s.expensesTotal, 28000);
      // The settlement figure now deducts rent too — it IS the cash net.
      expect(s.expectedHandover, s.netCollected);
      expect(s.expectedHandover, 2100 - 28000); // -25900
    });

    test('totalExpectedHandover equals totalNet with rent folded in', () {
      final t = TourMoneySummary.compute(
        collections: collections,
        expenses: expenses,
        handovers: handovers,
        busRentsTotal: 20000,
      );
      expect(t.totalExpenses, 9000 + 20000);
      expect(t.totalExpectedHandover, t.totalNet);
    });
  });
}
