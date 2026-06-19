import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/collection.dart';
import 'package:occubusbooking/utils/seat_money_state.dart';

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

void main() {
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
