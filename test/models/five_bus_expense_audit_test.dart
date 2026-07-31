import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/bus_handover.dart';
import 'package:occubusbooking/models/collection.dart';
import 'package:occubusbooking/models/expense.dart';
import 'package:occubusbooking/models/income_entry.dart';
import 'package:occubusbooking/models/money_summary.dart';

/// FIVE-BUS EXPENSE AUDIT
///
/// Reproduces the reported doubt: "I added five buses, each with its own
/// expenses, and the expenses are not calculated as per the things."
///
/// Drives the REAL aggregation the app uses ([BusMoneySummary.compute] per bus,
/// [TourMoneySummary.compute] for the trip) with a five-bus tour, then checks
/// the two invariants every money surface silently assumes:
///
///   1. per-bus isolation  — bus N's ledger contains ONLY bus N's rows
///   2. roll-up identity   — Σ(per-bus figure) == the trip-level figure
///
/// It also replays [FinanceController]'s own fold (collections − refunds,
/// expense rows, `buses.bus_price`) so the Settings → Finance number can be
/// compared against the per-tour money board on identical data.
void main() {
  // ── Fixture: 5 buses, each with its OWN rent, expenses, income, cash ──────
  //
  // Deliberately uneven so a cross-bus bleed cannot cancel out and hide itself.
  const busIds = ['bus1', 'bus2', 'bus3', 'bus4', 'bus5'];

  // buses.bus_price — the owner's rent. NEVER a DB expense row; folded in by
  // the summaries as a `busOwner` expense.
  const rents = <String, double>{
    'bus1': 40000,
    'bus2': 35000,
    'bus3': 52000,
    'bus4': 28000,
    'bus5': 61000,
  };

  // Ground expense ROWS (what the handler spends): 2-3 per bus, all different.
  final expenses = <Expense>[
    Expense(tourId: 't1', busId: 'bus1', amount: 5000, label: 'Driver', category: ExpenseCategory.driver),
    Expense(tourId: 't1', busId: 'bus1', amount: 3200, label: 'Fuel', category: ExpenseCategory.fuel),
    Expense(tourId: 't1', busId: 'bus2', amount: 1500, label: 'Toll', category: ExpenseCategory.toll),
    Expense(tourId: 't1', busId: 'bus2', amount: 4100, label: 'Food', category: ExpenseCategory.food),
    Expense(tourId: 't1', busId: 'bus2', amount: 900, label: 'Misc', category: ExpenseCategory.other),
    Expense(tourId: 't1', busId: 'bus3', amount: 7250, label: 'Fuel', category: ExpenseCategory.fuel),
    Expense(tourId: 't1', busId: 'bus4', amount: 2000, label: 'Toll', category: ExpenseCategory.toll),
    Expense(tourId: 't1', busId: 'bus4', amount: 6400, label: 'Driver', category: ExpenseCategory.driver),
    Expense(tourId: 't1', busId: 'bus5', amount: 3300, label: 'Food', category: ExpenseCategory.food),
    Expense(tourId: 't1', busId: 'bus5', amount: 1750, label: 'Fuel', category: ExpenseCategory.fuel),
    Expense(tourId: 't1', busId: 'bus5', amount: 800, label: 'Misc', category: ExpenseCategory.other),
  ];

  const groundExpectedByBus = <String, double>{
    'bus1': 8200, // 5000 + 3200
    'bus2': 6500, // 1500 + 4100 + 900
    'bus3': 7250,
    'bus4': 8400, // 2000 + 6400
    'bus5': 5850, // 3300 + 1750 + 800
  };

  final collections = <Collection>[
    Collection(tourId: 't1', busId: 'bus1', passengerId: 'p1', amountDue: 1500, amountReceived: 1500),
    Collection(tourId: 't1', busId: 'bus1', passengerId: 'p2', amountDue: 1500, amountReceived: 1000),
    Collection(tourId: 't1', busId: 'bus2', passengerId: 'p3', amountDue: 1200, amountReceived: 1200),
    Collection(tourId: 't1', busId: 'bus3', passengerId: 'p4', amountDue: 2000, amountReceived: 2500, amountRefunded: 500),
    Collection(tourId: 't1', busId: 'bus4', passengerId: 'p5', amountDue: 1800, amountReceived: 1800),
    Collection(tourId: 't1', busId: 'bus5', passengerId: 'p6', amountDue: 900, amountReceived: 900),
  ];

  final incomes = <IncomeEntry>[
    IncomeEntry(tourId: 't1', busId: 'bus2', amount: 2000, label: 'Cabin', category: IncomeCategory.cabin),
    IncomeEntry(tourId: 't1', busId: 'bus5', amount: 1500, label: 'Gallery', category: IncomeCategory.gallery),
  ];

  final handovers = <BusHandover>[
    BusHandover(tourId: 't1', busId: 'bus1', expectedAmount: 0, handedOverAmount: 1000),
  ];

  const totalRents = 216000.0; // 40000+35000+52000+28000+61000
  const totalGround = 36200.0; // 8200+6500+7250+8400+5850

  List<BusMoneySummary> summarise() => [
        for (final id in busIds)
          BusMoneySummary.compute(
            busId: id,
            collections: collections,
            expenses: expenses,
            handovers: handovers,
            incomes: incomes,
            busRent: rents[id]!,
          ),
      ];

  TourMoneySummary tourSummary() => TourMoneySummary.compute(
        collections: collections,
        expenses: expenses,
        handovers: handovers,
        incomes: incomes,
        busRentsTotal: totalRents,
      );

  group('5 buses — per-bus expense isolation', () {
    test('each bus counts ONLY its own expense rows + its own rent', () {
      for (final s in summarise()) {
        expect(
          s.groundExpenses,
          groundExpectedByBus[s.busId],
          reason: '${s.busId} ground expenses bled across buses',
        );
        expect(s.busRent, rents[s.busId], reason: '${s.busId} rent wrong');
        expect(
          s.expensesTotal,
          groundExpectedByBus[s.busId]! + rents[s.busId]!,
          reason: '${s.busId} expensesTotal != own rows + own rent',
        );
      }
    });

    test('each bus counts ONLY its own income', () {
      final byId = {for (final s in summarise()) s.busId: s};
      expect(byId['bus2']!.income, 2000);
      expect(byId['bus5']!.income, 1500);
      expect(byId['bus1']!.income, 0);
      expect(byId['bus3']!.income, 0);
      expect(byId['bus4']!.income, 0);
    });
  });

  group('5 buses — roll-up identity (per-bus Σ == trip total)', () {
    test('expenses', () {
      final perBus = summarise().fold<double>(0, (a, s) => a + s.expensesTotal);
      expect(perBus, totalGround + totalRents);
      expect(tourSummary().totalExpenses, perBus);
    });

    test('collected / income / handed over', () {
      final buses = summarise();
      final t = tourSummary();
      expect(buses.fold<double>(0, (a, s) => a + s.collected), t.totalCollected);
      expect(buses.fold<double>(0, (a, s) => a + s.income), t.totalIncome);
      expect(buses.fold<double>(0, (a, s) => a + s.handedOver), t.totalHandedOver);
    });

    test('net + expected handover', () {
      final buses = summarise();
      final t = tourSummary();
      expect(buses.fold<double>(0, (a, s) => a + s.netCollected), t.totalNet);
      expect(
        buses.fold<double>(0, (a, s) => a + s.expectedHandover),
        t.totalExpectedHandover,
      );
      expect(
        buses.fold<double>(0, (a, s) => a + s.outstandingHandover),
        t.totalOutstandingHandover,
      );
    });
  });

  group('5 buses — orphan rows break the roll-up', () {
    // tour_money_board_screen renders one row per bus in `tour.buses` and
    // computes those rows via summariesForBuses(tour.buses.map(id)), but the
    // totals capsule + P&L card use tourSummary(), which folds EVERY expense
    // row carrying this tour_id. A row whose bus_id is not among tour.buses
    // (bus detached/re-added, or buses list not fully loaded) is therefore
    // counted in the total but shown on NO bus row — the five rows no longer
    // add up to the capsule above them.
    final withOrphan = [
      ...expenses,
      Expense(
        tourId: 't1',
        busId: 'bus6-detached',
        amount: 9999,
        label: 'Orphan',
        category: ExpenseCategory.fuel,
      ),
    ];

    // What the five visible rows add up to.
    double perBusVisible() => [
          for (final id in busIds)
            BusMoneySummary.compute(
              busId: id,
              collections: collections,
              expenses: withOrphan,
              handovers: handovers,
              incomes: incomes,
              busRent: rents[id]!,
            ),
        ].fold<double>(0, (a, s) => a + s.expensesTotal);

    TourMoneySummary orphanTrip() => TourMoneySummary.compute(
          collections: collections,
          expenses: withOrphan,
          handovers: handovers,
          incomes: incomes,
          busRentsTotal: totalRents,
          knownBusIds: busIds.toSet(),
        );

    test('the orphan is surfaced, so rows + orphan == the trip total', () {
      final t = orphanTrip();
      expect(t.hasOrphanMoney, isTrue);
      expect(t.orphanExpenses, 9999);
      // The whole point: the board can now render the remainder and the
      // arithmetic on screen reconciles.
      expect(perBusVisible() + t.orphanExpenses, t.totalExpenses);
    });

    test('orphan money stays INSIDE the trip total (never silently dropped)',
        () {
      expect(orphanTrip().totalExpenses, totalGround + totalRents + 9999);
    });

    test('a clean 5-bus tour reports no orphan money', () {
      final t = TourMoneySummary.compute(
        collections: collections,
        expenses: expenses,
        handovers: handovers,
        incomes: incomes,
        busRentsTotal: totalRents,
        knownBusIds: busIds.toSet(),
      );
      expect(t.hasOrphanMoney, isFalse);
      expect(t.orphanExpenses, 0);
      expect(t.orphanCollected, 0);
      expect(t.orphanIncome, 0);
    });

    test('omitting knownBusIds disables orphan detection entirely', () {
      final t = TourMoneySummary.compute(
        collections: collections,
        expenses: withOrphan,
        handovers: handovers,
        incomes: incomes,
        busRentsTotal: totalRents,
      );
      expect(t.hasOrphanMoney, isFalse);
      // …but the money is still counted.
      expect(t.totalExpenses, totalGround + totalRents + 9999);
    });
  });

  group('Settings → Finance must agree with the per-tour money board', () {
    // Replays FinanceController.load()'s fold verbatim: revenue from
    // `collections` (received − refunded), expenses from `expenses` rows PLUS
    // every `buses.bus_price`, income from `incomes`.
    test('FinanceController fold == TourMoneySummary.totalNet', () {
      final revenue = collections.fold<double>(
        0,
        (a, c) => a + (c.amountReceived - c.amountRefunded),
      );
      final expenseTotal =
          expenses.fold<double>(0, (a, e) => a + e.amount) + totalRents;
      final incomeTotal = incomes.fold<double>(0, (a, i) => a + i.amount);
      final financeNet = revenue + incomeTotal - expenseTotal;

      expect(financeNet, tourSummary().totalNet);
    });
  });
}
