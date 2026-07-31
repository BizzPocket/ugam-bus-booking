import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/collection.dart';
import 'package:occubusbooking/utils/seat_money_state.dart';

void _refundToRecordTests() {
  group('refundToRecord — change auto-booked on overpayment', () {
    test('overpayment with no manual return → the surplus is the change', () {
      // Rider owes 1500, hands over 2000: 500 is change to hand back, recorded
      // so the line settles to net = due instead of looking like extra revenue.
      expect(
        refundToRecord(due: 1500, received: 2000, manualReturned: 0),
        500,
      );
    });

    test('exact payment → nothing returned', () {
      expect(refundToRecord(due: 1500, received: 1500, manualReturned: 0), 0);
    });

    test('underpayment → nothing returned (still owes)', () {
      expect(refundToRecord(due: 1500, received: 1000, manualReturned: 0), 0);
    });

    test('an explicit manual return always wins over the auto change', () {
      expect(
        refundToRecord(due: 1500, received: 2000, manualReturned: 300),
        300,
      );
    });

    test('manual return on an exactly-paid line is kept (genuine refund)', () {
      expect(refundToRecord(due: 1500, received: 1500, manualReturned: 200), 200);
    });
  });
}

/// Helpers to build the collection shapes the rider resolver keys off.
Collection _paid({double amount = 100}) => Collection(
      tourId: 't',
      busId: 'b',
      passengerId: 'p',
      amountDue: amount,
      amountReceived: amount,
    );

Collection _shortfall() => Collection(
      tourId: 't',
      busId: 'b',
      passengerId: 'p',
      amountDue: 100,
      amountReceived: 40,
    );

Collection _changeDue() => Collection(
      tourId: 't',
      busId: 'b',
      passengerId: 'p',
      amountDue: 100,
      amountReceived: 120,
    );

void _manualReturnToSeedTests() {
  group('manualReturnToSeed — collect sheet re-open (admin == handler)', () {
    test('no collection → blank', () {
      expect(manualReturnToSeed(null), isNull);
    });

    test('auto-recorded change (overpay) → blank so a re-open re-derives it', () {
      // Owed 500, paid 1000, 500 auto-booked as change. Re-opening must NOT
      // freeze 500 into "returned" — correcting received to 500 would otherwise
      // leave a phantom 500 shortfall.
      final overpaid = Collection(
        tourId: 't',
        busId: 'b',
        passengerId: 'p',
        amountDue: 500,
        amountReceived: 1000,
        amountRefunded: 500,
      );
      expect(manualReturnToSeed(overpaid), isNull);
    });

    test('a GENUINE manual return is pre-seeded', () {
      // Exactly paid (no auto-change) but 200 was explicitly returned → keep it.
      final refunded = Collection(
        tourId: 't',
        busId: 'b',
        passengerId: 'p',
        amountDue: 1500,
        amountReceived: 1500,
        amountRefunded: 200,
      );
      expect(manualReturnToSeed(refunded), 200);
    });

    test('manual return LARGER than the auto-change is kept', () {
      // Paid 1600 on a 1500 due (auto-change 100) but 300 was returned → 300 is
      // a real manual return (differs from the 100 auto-change), so seed it.
      final mixed = Collection(
        tourId: 't',
        busId: 'b',
        passengerId: 'p',
        amountDue: 1500,
        amountReceived: 1600,
        amountRefunded: 300,
      );
      expect(manualReturnToSeed(mixed), 300);
    });

    test('no refund at all → blank', () {
      final paid = Collection(
        tourId: 't',
        busId: 'b',
        passengerId: 'p',
        amountDue: 500,
        amountReceived: 500,
      );
      expect(manualReturnToSeed(paid), isNull);
    });
  });
}

void main() {
  _refundToRecordTests();
  _manualReturnToSeedTests();

  group('riderMoneyStateOf', () {
    test('no collection but money owed reads as owing', () {
      expect(riderMoneyStateOf(100, null), SeatMoneyState.owing);
    });

    test('no collection and nothing owed reads as uncollected', () {
      expect(riderMoneyStateOf(0, null), SeatMoneyState.uncollected);
    });

    test('squared-off collection with cash in reads as paid', () {
      expect(riderMoneyStateOf(100, _paid()), SeatMoneyState.paid);
    });

    test('shortfall reads as owing', () {
      expect(riderMoneyStateOf(100, _shortfall()), SeatMoneyState.owing);
    });

    test('overpayment (change due) reads as returnDue', () {
      expect(riderMoneyStateOf(100, _changeDue()), SeatMoneyState.returnDue);
    });
  });

  // Fares are per-BUS, so carrying a paid rider onto another bus re-prices them
  // immediately while their row still carries the OLD bus's amount_due. The
  // state has to follow the LIVE fare or a rider who owes the band difference
  // keeps reading as settled until someone happens to re-save the row.
  group('riderMoneyStateOf — live fare beats the stored snapshot', () {
    Collection paidAt(double amount) => Collection(
      tourId: 't',
      busId: 'b',
      passengerId: 'p',
      amountDue: amount,
      amountReceived: amount,
    );

    test('carried into a DEARER band reads as owing, not paid', () {
      // Paid ₹1,500 in full on bus 1; bus 2 bills ₹2,000 for the new seat.
      expect(riderMoneyStateOf(2000, paidAt(1500)), SeatMoneyState.owing);
      expect(liveBalanceOf(2000, paidAt(1500)), -500);
    });

    test('carried into a CHEAPER band reads as returnDue', () {
      expect(riderMoneyStateOf(1300, paidAt(1500)), SeatMoneyState.returnDue);
      expect(liveBalanceOf(1300, paidAt(1500)), 200);
    });

    test('a matching band still reads as paid', () {
      expect(riderMoneyStateOf(1500, paidAt(1500)), SeatMoneyState.paid);
      expect(liveBalanceOf(1500, paidAt(1500)), 0);
    });

    test('a refund counts, so a partly-refunded row is not "paid"', () {
      final refunded = Collection(
        tourId: 't',
        busId: 'b',
        passengerId: 'p',
        amountDue: 1500,
        amountReceived: 1500,
        amountRefunded: 200,
      );
      expect(netCollectedOf(refunded), 1300);
      expect(riderMoneyStateOf(1500, refunded), SeatMoneyState.owing);
    });

    test('no collection at all is unchanged: owed reads as owing', () {
      expect(netCollectedOf(null), 0);
      expect(liveBalanceOf(100, null), -100);
    });
  });

  group('seatMoneyStateOf — shared-sofa aggregation', () {
    test('green ONLY when every rider has paid', () {
      expect(
        seatMoneyStateOf(const [SeatMoneyState.paid, SeatMoneyState.paid]),
        SeatMoneyState.paid,
      );
    });

    test('one paid + one still owing stays owing (red), never green', () {
      // The reported bug: entering one rider\'s payment must NOT turn the
      // shared sofa green while the co-rider is unpaid.
      expect(
        seatMoneyStateOf(const [SeatMoneyState.paid, SeatMoneyState.owing]),
        SeatMoneyState.owing,
      );
    });

    test('owing wins over a co-rider who is merely due change', () {
      expect(
        seatMoneyStateOf(const [SeatMoneyState.owing, SeatMoneyState.returnDue]),
        SeatMoneyState.owing,
      );
    });

    test('change-due wins over uncollected when nobody owes', () {
      expect(
        seatMoneyStateOf(
            const [SeatMoneyState.returnDue, SeatMoneyState.uncollected]),
        SeatMoneyState.returnDue,
      );
    });

    test('a single fully-paid rider is paid', () {
      expect(seatMoneyStateOf(const [SeatMoneyState.paid]), SeatMoneyState.paid);
    });

    test('an empty seat reads as uncollected', () {
      expect(
        seatMoneyStateOf(const <SeatMoneyState>[]),
        SeatMoneyState.uncollected,
      );
    });
  });
}
