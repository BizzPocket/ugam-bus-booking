import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/utils/chart_basket.dart';

/// A selection that survives switching buses.
///
/// *** WHY THIS REPLACES A FLAT MAP ***
/// The chart held picks in a single `Map<seatId, berths>` and CLEARED it every
/// time the customer changed bus tab, because a claim took one `p_bus_id`. A
/// party willing to split across buses therefore could not express that at all:
/// picking two berths on Bus A and two on Bus B was impossible, since choosing
/// Bus B threw away Bus A.
///
/// A seat id is only unique WITHIN a bus, so the bus has to be part of the key —
/// exactly as `SeatAvailability.keyFor` already does for occupancy.
void main() {
  group('per-bus isolation', () {
    test('the same seat id on two buses is two different berths', () {
      final basket = ChartBasket()
        ..setBerths(busId: 'a', seatId: 'DU1', berths: 2)
        ..setBerths(busId: 'b', seatId: 'DU1', berths: 1);

      expect(basket.berthsFor(busId: 'a', seatId: 'DU1'), 2);
      expect(basket.berthsFor(busId: 'b', seatId: 'DU1'), 1);
      expect(
        basket.totalBerths,
        3,
        reason: 'a flat seatId map would have collapsed these into one',
      );
    });

    test('picking on a second bus does not disturb the first', () {
      final basket = ChartBasket()
        ..setBerths(busId: 'a', seatId: 'DU1', berths: 2);
      basket.setBerths(busId: 'b', seatId: 'SU1', berths: 1);

      expect(basket.forBus('a'), {'DU1': 2});
      expect(basket.forBus('b'), {'SU1': 1});
      expect(basket.busIds, containsAll(['a', 'b']));
    });

    test('an untouched bus reads as empty, not null', () {
      expect(ChartBasket().forBus('nobody'), isEmpty);
      expect(ChartBasket().berthsFor(busId: 'nobody', seatId: 'DU1'), 0);
    });
  });

  group('removal', () {
    test('setting zero berths drops the seat entirely', () {
      final basket = ChartBasket()
        ..setBerths(busId: 'a', seatId: 'DU1', berths: 2);
      basket.setBerths(busId: 'a', seatId: 'DU1', berths: 0);

      expect(basket.berthsFor(busId: 'a', seatId: 'DU1'), 0);
      expect(basket.isEmpty, isTrue);
    });

    test('emptying a bus removes it from busIds', () {
      final basket = ChartBasket()
        ..setBerths(busId: 'a', seatId: 'DU1', berths: 1)
        ..setBerths(busId: 'b', seatId: 'SU1', berths: 1);
      basket.setBerths(busId: 'a', seatId: 'DU1', berths: 0);

      expect(
        basket.busIds,
        ['b'],
        reason: 'an empty bus must not reach the claim as a bus with no seats',
      );
    });

    test('a negative count is treated as removal, never as debt', () {
      final basket = ChartBasket()
        ..setBerths(busId: 'a', seatId: 'DU1', berths: 2);
      basket.setBerths(busId: 'a', seatId: 'DU1', berths: -1);

      expect(basket.totalBerths, 0);
    });

    test('clearing one bus leaves the others alone', () {
      final basket = ChartBasket()
        ..setBerths(busId: 'a', seatId: 'DU1', berths: 2)
        ..setBerths(busId: 'b', seatId: 'SU1', berths: 1);
      basket.clearBus('a');

      expect(basket.busIds, ['b']);
      expect(basket.totalBerths, 1);
    });

    test('clearing everything empties the basket', () {
      final basket = ChartBasket()
        ..setBerths(busId: 'a', seatId: 'DU1', berths: 2)
        ..setBerths(busId: 'b', seatId: 'SU1', berths: 1);
      basket.clear();

      expect(basket.isEmpty, isTrue);
      expect(basket.busIds, isEmpty);
    });
  });

  group('totals', () {
    test('berths sum across every bus', () {
      final basket = ChartBasket()
        ..setBerths(busId: 'a', seatId: 'DU1', berths: 2)
        ..setBerths(busId: 'a', seatId: 'DU2', berths: 1)
        ..setBerths(busId: 'b', seatId: 'SU1', berths: 1);

      expect(basket.totalBerths, 4);
    });

    test('a fresh basket is empty and totals zero', () {
      final basket = ChartBasket();
      expect(basket.isEmpty, isTrue);
      expect(basket.totalBerths, 0);
      expect(basket.busIds, isEmpty);
    });

    test('spansMultipleBuses reports whether checkout must go multi-bus', () {
      final basket = ChartBasket()
        ..setBerths(busId: 'a', seatId: 'DU1', berths: 2);
      expect(basket.spansMultipleBuses, isFalse);

      basket.setBerths(busId: 'b', seatId: 'SU1', berths: 1);
      expect(basket.spansMultipleBuses, isTrue);
    });
  });

  group('the view a caller mutates cannot corrupt the basket', () {
    test('forBus hands back a copy, not the live map', () {
      final basket = ChartBasket()
        ..setBerths(busId: 'a', seatId: 'DU1', berths: 2);

      basket.forBus('a')['DU1'] = 99;

      expect(
        basket.berthsFor(busId: 'a', seatId: 'DU1'),
        2,
        reason: 'a leaked internal map lets a screen oversell a sofa by '
            'accident, and the server would be the only thing catching it',
      );
    });
  });
}
