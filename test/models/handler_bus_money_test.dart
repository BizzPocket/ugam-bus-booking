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
        dueForSeat: dueForSeat,
      );

      expect(m.collected, 30000);
      expect(m.toCollect, 0);
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
        passengers: const [],
        collections: [
          Collection(
            tourId: 't1',
            busId: 'bus1',
            passengerId: 'p1',
            amountDue: 2000,
            amountReceived: 1500, // ₹500 short
          ),
        ],
        expenses: const [],
        incomes: const [],
        dueForSeat: dueForSeat,
      );
      expect(m.collected, 1500);
      expect(m.toCollect, 500);
    });
  });
}
