import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/collection.dart';
import 'package:occubusbooking/models/expense.dart';
import 'package:occubusbooking/models/income_entry.dart';
import 'package:occubusbooking/models/passenger.dart';
import 'package:occubusbooking/models/seat_assignment.dart';
import 'package:occubusbooking/models/handler_bus_money.dart';

/// The handler's per-bus "in hand" money must be SEAT-AGNOSTIC: a rider's cash
/// is tied to their collection row, never to the seat they currently sit in.
///
/// Regression for the real raj-bus bug — the handler matched each collection to
/// the rider's CURRENT seat, so riders who paid then changed seats had their
/// cash silently dropped from "collected" (and double-counted back into "to
/// collect"). The screen showed ₹23,000 while the admin (which sums by bus_id)
/// correctly showed ₹30,000.
void main() {
  // A flat per-seat fare keeps the "uncollected rider" path deterministic.
  double dueForSeat(Passenger p, String seatId) => 2000;

  Passenger pax(String id, List<String> seats, {String bus = 'bus1'}) =>
      Passenger(
        id: id,
        tourId: 't1',
        name: id,
        phone: '+910000000000',
        assignedSeats: [
          for (final s in seats) SeatAssignment(busId: bus, seatId: s),
        ],
      );

  group('seat moves never orphan collected cash', () {
    test('a rider who paid then changed seats still counts as collected', () {
      // Paid IN FULL on DU1 (₹2000), then moved to SU3. The collection row
      // keeps its original seatId (DU1); the rider now sits on SU3.
      final collections = [
        Collection(
          tourId: 't1',
          busId: 'bus1',
          passengerId: 'mahesh',
          seatId: 'DU1', // old seat — rider has since moved off it
          amountDue: 2000,
          amountReceived: 2000,
        ),
      ];

      final m = HandlerBusMoney.compute(
        busId: 'bus1',
        passengers: [pax('mahesh', ['SU3'])], // now sits on SU3
        collections: collections,
        expenses: const [],
        incomes: const [],
        dueForSeat: dueForSeat,
      );

      // The ₹2000 is counted as collected (NOT dropped because the seat moved)…
      expect(m.collected, 2000);
      // …and NOT double-counted as still-to-collect.
      expect(m.toCollect, 0);
      expect(m.toReturn, 0);
      expect(m.inHand, 2000);
    });

    test('reproduces the raj-bus ₹30,000 total after a full reshuffle', () {
      // 10 fully-paid rows totalling ₹30,000 (the real raj-bus figures), then
      // every rider is moved to a different seat. Bus-scoped summing must still
      // report the full ₹30,000 — the seat moves are irrelevant to the cash.
      final amounts = <String, int>{
        'c1': 8000, 'c2': 2000, 'c3': 3000, 'c4': 2000, 'c5': 6000,
        'c6': 2000, 'c7': 1000, 'c8': 2000, 'c9': 2000, 'c10': 2000,
      };
      final collections = [
        for (final e in amounts.entries)
          Collection(
            tourId: 't1',
            busId: 'bus1',
            passengerId: e.key,
            seatId: 'PAID-${e.key}', // whatever seat they paid on
            amountDue: e.value.toDouble(),
            amountReceived: e.value.toDouble(),
          ),
      ];

      final m = HandlerBusMoney.compute(
        busId: 'bus1',
        // Everyone now sits somewhere else entirely.
        passengers: [for (final id in amounts.keys) pax(id, ['NOW-$id'])],
        collections: collections,
        expenses: const [],
        incomes: const [],
        // Each rider's seat costs what they actually paid, so this fixture
        // describes ten SETTLED riders who merely moved seats — which is the
        // invariant under test. The flat ₹2000 `dueForSeat` used elsewhere would
        // contradict the rows (c7 paid ₹1000), and to-collect is now priced from
        // the LIVE fare, so it would correctly report that rider ₹1000 short and
        // bury the seat-move question under a pricing one.
        dueForSeat: (p, seatId) => amounts[p.id]!.toDouble(),
      );

      expect(m.collected, 30000);
      expect(m.toCollect, 0);
      expect(m.toReturn, 0);
    });

    test('a collection on a different bus never leaks in', () {
      final m = HandlerBusMoney.compute(
        busId: 'bus1',
        passengers: const [],
        collections: [
          Collection(
            tourId: 't1',
            busId: 'bus2', // other bus
            passengerId: 'p1',
            amountDue: 9999,
            amountReceived: 9999,
          ),
        ],
        expenses: const [],
        incomes: const [],
        dueForSeat: dueForSeat,
      );
      expect(m.collected, 0);
    });
  });

  group('ledger lines', () {
    test('income adds to in-hand, ground expense subtracts, no rent', () {
      final m = HandlerBusMoney.compute(
        busId: 'bus1',
        passengers: const [],
        collections: [
          Collection(
            tourId: 't1',
            busId: 'bus1',
            passengerId: 'p1',
            amountDue: 5000,
            amountReceived: 5000,
          ),
        ],
        expenses: [
          Expense(
            tourId: 't1',
            busId: 'bus1',
            category: ExpenseCategory.fuel,
            label: '',
            amount: 500,
          ),
        ],
        incomes: [
          IncomeEntry(
            tourId: 't1',
            busId: 'bus1',
            category: IncomeCategory.cabin,
            label: '',
            amount: 1500,
          ),
        ],
        dueForSeat: dueForSeat,
      );
      expect(m.collected, 5000);
      expect(m.income, 1500);
      // "spent" is the handler's ground expense only — the bus owner's rent is
      // admin-only and can't reach any handler figure.
      expect(m.spent, 500);
      expect(m.inHand, 6000); // 5000 + 1500 - 500
    });

    test('a seated rider with NO collection row owes their full fare', () {
      final m = HandlerBusMoney.compute(
        busId: 'bus1',
        passengers: [pax('newbie', ['SU1'])], // seated, never collected from
        collections: const [],
        expenses: const [],
        incomes: const [],
        dueForSeat: dueForSeat, // ₹2000
      );
      expect(m.collected, 0);
      expect(m.toCollect, 2000);
    });

    test('partial payment leaves the shortfall to collect', () {
      final m = HandlerBusMoney.compute(
        busId: 'bus1',
        passengers: [pax('p1', ['SU1'])],
        collections: [
          Collection(
            tourId: 't1',
            busId: 'bus1',
            passengerId: 'p1',
            seatId: 'SU1',
            amountDue: 2000,
            amountReceived: 1500, // ₹500 short
          ),
        ],
        expenses: const [],
        incomes: const [],
        dueForSeat: dueForSeat, // ₹2000
      );
      expect(m.collected, 1500);
      expect(m.toCollect, 500);
    });

    test('the shortfall follows the LIVE fare, not the stored amount_due', () {
      // The row was written when this seat cost ₹1500 and the rider paid it in
      // full, so `Collection.balance` reads settled forever. The bus has since
      // been re-priced to ₹2000 — `dueForSeat` is the live fare — and the rider
      // genuinely owes the ₹500 difference.
      //
      // This is the admin-side half of the bug behind the ₹449 phantom refund:
      // to-collect used to be summed from the stored `amount_due` SNAPSHOT, so a
      // re-priced bus went on reporting the old expectation while the collection
      // roster (which always priced live) showed the truth.
      final m = HandlerBusMoney.compute(
        busId: 'bus1',
        passengers: [pax('p1', ['SU1'])],
        collections: [
          Collection(
            tourId: 't1',
            busId: 'bus1',
            passengerId: 'p1',
            seatId: 'SU1',
            amountDue: 1500, // stale snapshot: settled against the OLD fare
            amountReceived: 1500,
          ),
        ],
        expenses: const [],
        incomes: const [],
        dueForSeat: dueForSeat, // live fare is now ₹2000
      );
      expect(m.collected, 1500);
      expect(m.toCollect, 500);
      expect(m.toReturn, 0);
    });

    test('cash from a rider who holds no seat here is not a refund due', () {
      // They paid ₹1500 on this bus and have since left it entirely (unseated,
      // or moved to another bus that re-prices them). This bus bills them
      // nothing, so it is owed nothing and owes nothing back: the cash is
      // BusMoneySummary.detachedCash, surfaced on its own and display-only.
      //
      // Reading it as money to hand back is exactly the phantom "refund ₹X" with
      // nobody behind it that the To-return filter could never match.
      final m = HandlerBusMoney.compute(
        busId: 'bus1',
        passengers: const [],
        collections: [
          Collection(
            tourId: 't1',
            busId: 'bus1',
            passengerId: 'p1',
            seatId: 'SU1',
            amountDue: 2000,
            amountReceived: 1500,
          ),
        ],
        expenses: const [],
        incomes: const [],
        dueForSeat: dueForSeat,
      );
      expect(m.collected, 1500);
      expect(m.toCollect, 0);
      expect(m.toReturn, 0);
    });
  });
}
