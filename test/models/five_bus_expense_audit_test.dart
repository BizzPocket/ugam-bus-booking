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

  // Per-bus COST under the pakku-bhadu rule (every bus defaults to
  // rentIncludesFuel): diesel + driver are INSIDE the rent — they only reduce
  // what is owed to the owner; toll / food / misc stay ON TOP.
  //   bus1  max(40000, 5000 drv + 3200 fuel)   + 0 on top             = 40000
  //   bus2  max(35000, 0)                      + 1500+4100+900 = 6500 = 41500
  //   bus3  max(52000, 7250 fuel)              + 0                    = 52000
  //   bus4  max(28000, 6400 drv)               + 2000 toll            = 30000
  //   bus5  max(61000, 1750 fuel)              + 3300+800 = 4100      = 65100
  const costExpectedByBus = <String, double>{
    'bus1': 40000,
    'bus2': 41500,
    'bus3': 52000,
    'bus4': 30000,
    'bus5': 65100,
  };
  // Σ = 228600 = rents 216000 + on-top 12600 (= ground 36200 − absorbed
  // 23600, absorbed = 3200+5000+7250+6400+1750).
  const totalCost = 228600.0;

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

  // As MoneyController.tourSummary() builds it: the per-bus Σ is the trip
  // total (totalExpensesOverride), with the fleet known.
  TourMoneySummary tourSummary() => TourMoneySummary.compute(
        collections: collections,
        expenses: expenses,
        handovers: handovers,
        incomes: incomes,
        busRentsTotal: totalRents,
        knownBusIds: busIds.toSet(),
        totalExpensesOverride:
            summarise().fold<double>(0, (a, s) => a + s.expensesTotal),
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
          costExpectedByBus[s.busId],
          reason: '${s.busId} expensesTotal != own rent (incl. diesel + '
              'driver) + own on-top rows',
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
      expect(perBus, totalCost);
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
          totalExpensesOverride: perBusVisible(),
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
      // Visible buses 228600 (the orphan row is on no visible bus) + the
      // orphan 9999 → 238599.
      expect(orphanTrip().totalExpenses, totalCost + 9999);
    });

    test('a clean 5-bus tour reports no orphan money', () {
      // (No override needed — only the orphan figures are asserted.)
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
      // …but the money is still counted. (No fleet resolved → no per-bus
      // override → the raw `rows + rents` fallback.)
      expect(t.totalExpenses, totalGround + totalRents + 9999);
    });
  });

  group('Settings → Finance must agree with the per-tour money board', () {
    // Replays FinanceController.load()'s fold: revenue from `collections`
    // (received − refunded), income from `incomes`, and per bus the SAME
    // pakku-bhadu rule the board uses — [BusExpenseRollup.fromLedger] over the
    // ledger's ground total + the diesel / driver / advance rows.
    test('FinanceController fold == TourMoneySummary.totalNet', () {
      final revenue = collections.fold<double>(
        0,
        (a, c) => a + (c.amountReceived - c.amountRefunded),
      );
      double sumOf(String bus, ExpenseCategory cat) => expenses
          .where((e) => e.busId == bus && e.category == cat)
          .fold<double>(0, (a, e) => a + e.amount);
      final expenseTotal = busIds.fold<double>(
        0,
        (a, id) =>
            a +
            BusExpenseRollup.fromLedger(
              ground: groundExpectedByBus[id]!,
              busRent: rents[id]!,
              fuel: sumOf(id, ExpenseCategory.fuel),
              driver: sumOf(id, ExpenseCategory.driver),
              ownerAdvance: sumOf(id, ExpenseCategory.busOwner),
              rentIncludesFuel: true,
            ).expensesTotal,
      );
      expect(expenseTotal, totalCost);
      final incomeTotal = incomes.fold<double>(0, (a, i) => a + i.amount);
      final financeNet = revenue + incomeTotal - expenseTotal;

      expect(financeNet, tourSummary().totalNet);
    });
  });
}
