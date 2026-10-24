import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/collection.dart';
import 'package:occubusbooking/models/expense.dart';
import 'package:occubusbooking/models/bus_handover.dart';
import 'package:occubusbooking/models/income_entry.dart';
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

    test('bus rent is OUTSIDE the handover expectation (admin settles owner)',
        () {
      final s = BusMoneySummary.compute(
        busId: 'bus1',
        collections: collections,
        expenses: expenses,
        handovers: const [],
        busRent: 20000,
      );
      // Pakku bhadu: diesel 3000 is inside the 20000 rent; driver 5000 is on
      // top (owner's rule 2026-10-25: every driver cost is extra).
      //   cost = max(20000, 3000) + 5000 on top = 25000
      //   owner still owed = 20000 − 3000 = 17000
      expect(s.expensesTotal, 25000);
      expect(s.busMalikPayable, 17000);
      expect(s.groundExpenses, 8000);
      // The handler hands over cash less their GROUND costs only …
      expect(s.expectedHandover, 2100 - 8000); // -5900
      // … and the admin's cash net is that, less what they still owe the
      // owner: −5900 − 17000 = 2100 − 25000 = −22900.
      expect(s.netCollected, 2100 - 25000);
      expect(s.netCollected, s.expectedHandover - s.busMalikPayable);
      // Contract cost in P&L minus cash paid on the ground = owner remaining.
      expect(s.expensesTotal - s.groundExpenses, 17000);
    });

    test('totalExpectedHandover excludes the rents (= totalNet + rents)', () {
      final t = TourMoneySummary.compute(
        collections: collections,
        expenses: expenses,
        handovers: handovers,
        busRentsTotal: 20000,
      );
      expect(t.totalExpenses, 9000 + 20000);
      expect(t.totalGroundExpenses, 9000);
      expect(t.totalExpectedHandover, 2800 - 9000);
      expect(t.totalExpectedHandover, t.totalNet + 20000);
    });
  });

  // A bus whose owner rent was never entered reads as ₹0 — indistinguishable
  // from a genuinely free bus (`bus_price` is `not null default 0`). The billed
  // P&L then counts that bus's fares as pure profit, so the headline is
  // overstated by a whole missing cost. These flag that state so the UI can say
  // so instead of painting a confident green number.
  group('unrecorded bus rent', () {
    test('no rents missing when every bus has one', () {
      final t = TourMoneySummary.compute(
        collections: const [],
        expenses: const [],
        handovers: const [],
        busRentsTotal: 100000,
        busesMissingRent: 0,
      );
      expect(t.busesMissingRent, 0);
      expect(t.hasUnrecordedRent, isFalse);
    });

    test('flags the count of buses with no rent recorded', () {
      final t = TourMoneySummary.compute(
        collections: const [],
        expenses: const [],
        handovers: const [],
        busRentsTotal: 50000,
        busesMissingRent: 1,
      );
      expect(t.busesMissingRent, 1);
      expect(t.hasUnrecordedRent, isTrue);
    });

    // Same "0 means unknown, never a false alarm" rule the orphan and
    // detached-cash figures follow: an unresolvable fleet must not accuse the
    // agent of forgetting a rent.
    test('pakku bhadu matches reference sheet (₹3,000 profit)', () {
      final expenses = [
        Expense(
          tourId: 't1',
          busId: 'b1',
          amount: 35000,
          category: ExpenseCategory.fuel,
          label: 'Diesel',
        ),
        Expense(
          tourId: 't1',
          busId: 'b1',
          amount: 5000,
          category: ExpenseCategory.busOwner,
          label: 'Advance',
        ),
        Expense(
          tourId: 't1',
          busId: 'b1',
          amount: 500,
          category: ExpenseCategory.food,
          label: 'Driver food',
        ),
        Expense(
          tourId: 't1',
          busId: 'b1',
          amount: 500,
          category: ExpenseCategory.other,
          label: 'Other',
        ),
      ];
      final s = BusMoneySummary.compute(
        busId: 'b1',
        collections: [
          Collection(
            tourId: 't1',
            busId: 'b1',
            passengerId: 'p1',
            amountDue: 53000,
            amountReceived: 53000,
          ),
        ],
        expenses: expenses,
        handovers: const [],
        incomes: [
          IncomeEntry(
            tourId: 't1',
            busId: 'b1',
            amount: 1000,
            label: 'Extra',
          ),
        ],
        busRent: 50000,
        rentIncludesFuel: true,
        revenueBilled: 53000,
      );
      expect(s.busMalikPayable, 10000);
      expect(s.expensesTotal, 51000);
      expect(s.netBilled, 3000);
      expect(s.netCollected, 3000);
    });

    test('stays silent when the caller supplied no bus rents at all', () {
      final t = TourMoneySummary.compute(
        collections: const [],
        expenses: const [],
        handovers: const [],
      );
      expect(t.busesMissingRent, 0);
      expect(t.hasUnrecordedRent, isFalse);
    });
  });
  // The owner's rule (2026-10-25 formula sheet, superseding 10-15's "diesel
  // and the driver is added"): only diesel and owner advances come out of the
  // bhadu; EVERY driver cost is extra, on top.
  group('pakku bhadu — diesel inside the rent, driver on top', () {
    final rows = [
      Expense(
        tourId: 't1',
        busId: 'b1',
        amount: 3200,
        category: ExpenseCategory.fuel,
        label: 'Diesel',
      ),
      Expense(
        tourId: 't1',
        busId: 'b1',
        amount: 5000,
        category: ExpenseCategory.driver,
        label: 'Driver',
      ),
      Expense(
        tourId: 't1',
        busId: 'b1',
        amount: 600,
        category: ExpenseCategory.toll,
        label: 'Toll',
      ),
    ];

    test('rent 40000, diesel 3200, driver 5000 → cost 45000, owed 36800', () {
      final r = BusExpenseRollup.fromExpenses(
        busExpenses: rows.take(2),
        busRent: 40000,
        rentIncludesFuel: true,
      );
      expect(r.effectiveBusCost, 40000);
      expect(r.expensesTotal, 45000); // 40000 rent + 5000 driver on top
      expect(r.busMalikPayable, 36800); // 40000 − 3200 diesel
      expect(r.fuelTotal, 3200);
      expect(r.driverTotal, 0);
      expect(r.otherExpensesTotal, 5000);
    });

    test('toll stays on top of the rent', () {
      final s = BusMoneySummary.compute(
        busId: 'b1',
        collections: const [],
        expenses: rows,
        handovers: const [],
        busRent: 40000,
      );
      // 40000 rent (diesel inside) + 5000 driver + 600 toll = 45600.
      expect(s.expensesTotal, 45600);
      expect(s.busMalikPayable, 36800);
      // Handler still deducts every rupee they paid: 3200 + 5000 + 600.
      expect(s.groundExpenses, 8800);
      expect(s.expectedHandover, -8800);
    });

    test('rent that EXCLUDES fuel keeps diesel + driver on top', () {
      final s = BusMoneySummary.compute(
        busId: 'b1',
        collections: const [],
        expenses: rows,
        handovers: const [],
        busRent: 40000,
        rentIncludesFuel: false,
      );
      // 40000 + 3200 + 5000 + 600 = 48800; owner still owed the full 40000.
      expect(s.expensesTotal, 48800);
      expect(s.busMalikPayable, 40000);
      expect(s.driverTotal, 0);
      expect(s.fuelTotal, 0);
      expect(s.groundExpenses, 8800);
    });

    test('payments past the rent raise the cost instead of vanishing', () {
      final r = BusExpenseRollup.fromExpenses(
        busExpenses: rows.take(2),
        busRent: 3000,
        rentIncludesFuel: true,
      );
      // Diesel 3200 > rent 3000 → bus cost 3200, plus driver 5000 on top =
      // 8200; owner owed 0.
      expect(r.expensesTotal, 8200);
      expect(r.busMalikPayable, 0);
    });

    test('fromLedger agrees with fromExpenses on the same bus', () {
      final a = BusExpenseRollup.fromExpenses(
        busExpenses: rows,
        busRent: 40000,
        rentIncludesFuel: true,
      );
      final b = BusExpenseRollup.fromLedger(
        ground: 8800,
        busRent: 40000,
        fuel: 3200,
        driver: 5000,
        ownerAdvance: 0,
        rentIncludesFuel: true,
      );
      expect(b.expensesTotal, a.expensesTotal);
      expect(b.busMalikPayable, a.busMalikPayable);
      expect(b.otherExpensesTotal, a.otherExpensesTotal);
    });
  });
}
