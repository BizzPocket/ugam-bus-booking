import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/bus_handover.dart';
import 'package:occubusbooking/models/collection.dart';
import 'package:occubusbooking/models/expense.dart';
import 'package:occubusbooking/models/handler_bus_money.dart';
import 'package:occubusbooking/models/money_summary.dart';
import 'package:occubusbooking/models/passenger.dart';
import 'package:occubusbooking/models/seat_assignment.dart';

// Settlement, from the handler's side.
//
// Before handovers were wired the handler's screen read the full "in hand"
// figure forever: they handed ₹18,800 to the organiser on the roadside and the
// phone still said ₹18,800, with nothing anywhere to record that the cash had
// moved.
//
// The fix must NOT move `inHand`. That figure is the gross the bus generated
// and is pinned to the admin's `BusMoneySummary.expectedHandover` by
// cross_system_invariants_test; what settles is the new `outstanding`.

const _bus = 'bus1';

Passenger _pax(String id, List<String> seats) => Passenger(
      id: id,
      tourId: 't1',
      name: id,
      phone: '+910000000000',
      assignedSeats: [
        for (final s in seats) SeatAssignment(busId: _bus, seatId: s),
      ],
    );

Collection _paid(String passengerId, String seatId, double amount) => Collection(
      tourId: 't1',
      busId: _bus,
      passengerId: passengerId,
      seatId: seatId,
      amountDue: amount,
      amountReceived: amount,
    );

BusHandover _handover(double amount, {String source = 'handler'}) => BusHandover(
      tourId: 't1',
      busId: _bus,
      handedOverAmount: amount,
      source: source,
    );

HandlerBusMoney _money({
  List<Collection> collections = const [],
  List<Expense> expenses = const [],
  List<BusHandover> handovers = const [],
  List<Passenger> passengers = const [],
}) =>
    HandlerBusMoney.compute(
      busId: _bus,
      passengers: passengers,
      collections: collections,
      expenses: expenses,
      handovers: handovers,
      dueForSeat: (p, s) => 2000,
    );

void main() {
  group('handover settles what the handler owes', () {
    test('with no handover, outstanding is the whole in-hand figure', () {
      final m = _money(collections: [_paid('a', 'A1', 2000)]);

      expect(m.inHand, 2000);
      expect(m.handedOver, 0);
      expect(m.outstanding, 2000);
      expect(m.isSettled, isFalse);
    });

    test('handing over everything settles the bus WITHOUT moving inHand', () {
      final m = _money(
        collections: [_paid('a', 'A1', 2000)],
        handovers: [_handover(2000)],
      );

      // The gross figure must not move — it is the admin's expectedHandover.
      expect(m.inHand, 2000);
      expect(m.handedOver, 2000);
      expect(m.outstanding, 0);
      expect(m.isSettled, isTrue);
    });

    test('a partial handover leaves exactly the remainder outstanding', () {
      final m = _money(
        collections: [_paid('a', 'A1', 2000), _paid('b', 'A2', 2000)],
        handovers: [_handover(2500)],
      );

      expect(m.inHand, 4000);
      expect(m.handedOver, 2500);
      expect(m.outstanding, 1500);
      expect(m.isSettled, isFalse);
    });

    test('several handovers accumulate', () {
      final m = _money(
        collections: [_paid('a', 'A1', 2000), _paid('b', 'A2', 2000)],
        handovers: [_handover(1000), _handover(1500), _handover(1500)],
      );

      expect(m.handedOver, 4000);
      expect(m.outstanding, 0);
      expect(m.isSettled, isTrue);
    });

    test('an ADMIN-recorded handover counts toward settlement too', () {
      // Who typed it in does not change whether the organiser has the cash.
      final m = _money(
        collections: [_paid('a', 'A1', 2000)],
        handovers: [_handover(2000, source: 'admin')],
      );

      expect(m.handedOver, 2000);
      expect(m.isSettled, isTrue);
    });

    test('sub-rupee dust still reads as settled', () {
      final m = _money(
        collections: [_paid('a', 'A1', 2000)],
        handovers: [_handover(1999.998)],
      );

      expect(m.isSettled, isTrue, reason: 'within kMoneyEpsilon');
    });

    test('ground expenses reduce what must be handed over', () {
      final m = _money(
        collections: [_paid('a', 'A1', 2000)],
        expenses: [
          Expense(
            tourId: 't1',
            busId: _bus,
            category: ExpenseCategory.fuel,
            label: 'diesel',
            amount: 500,
          ),
        ],
        handovers: [_handover(1500)],
      );

      expect(m.inHand, 1500, reason: '2000 collected − 500 spent');
      expect(m.outstanding, 0);
      expect(m.isSettled, isTrue);
    });

    test('a handover on ANOTHER bus never settles this one', () {
      final m = HandlerBusMoney.compute(
        busId: _bus,
        passengers: const [],
        collections: [_paid('a', 'A1', 2000)],
        expenses: const [],
        handovers: [
          BusHandover(tourId: 't1', busId: 'other-bus', handedOverAmount: 2000),
        ],
        dueForSeat: (p, s) => 2000,
      );

      expect(m.handedOver, 0);
      expect(m.outstanding, 2000);
      expect(m.isSettled, isFalse);
    });
  });

  group('the admin/handler seam still holds after settlement', () {
    test('inHand tracks admin expectedHandover regardless of handovers', () {
      final collections = [_paid('a', 'A1', 2000), _paid('b', 'A2', 2000)];
      final expenses = [
        Expense(
          tourId: 't1',
          busId: _bus,
          category: ExpenseCategory.fuel,
          label: 'diesel',
          amount: 700,
        ),
      ];
      final handovers = [_handover(1200)];

      final handler = _money(
        collections: collections,
        expenses: expenses,
        handovers: handovers,
      );
      // The admin carries the owner's rent; the handler never sees it, and it
      // must not disturb the seam.
      final admin = BusMoneySummary.compute(
        busId: _bus,
        collections: collections,
        expenses: expenses,
        handovers: handovers,
        busRent: 50000,
      );

      expect(handler.inHand, admin.expectedHandover);
      expect(handler.handedOver, admin.handedOver);
      expect(handler.outstanding, admin.outstandingHandover);
    });
  });

  group('unpaid riders are unaffected by settlement', () {
    test('a seated rider with no collection still shows in toCollect', () {
      final m = _money(
        passengers: [_pax('unpaid', ['A9'])],
        collections: [_paid('a', 'A1', 2000)],
        handovers: [_handover(2000)],
      );

      expect(m.toCollect, 2000, reason: 'the unpaid rider still owes');
      expect(m.isSettled, isTrue, reason: 'settlement is about cash in hand');
    });
  });
}
