// A bus is priced EITHER from one uniform per-seat price OR by price bands —
// never a mix (owner, 2026-10-25). The live bug this pins: bus a48fe549 (RSR,
// 13-09 trip) saved BOTH bands on rows 0–4, so row 5 fell back to a leftover
// per-seat price of ₹0.14 and its riders priced at ₹0.

import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/bus_details.dart';
import 'package:occubusbooking/models/seat_type.dart';

void main() {
  group('PriceBand.uncoveredRows', () {
    test('the live a48fe549 bands leave row 5 (0-based) unpriced', () {
      const bands = [
        PriceBand(label: 'Front', fromRow: 0, toRow: 4, price: 1700),
        PriceBand(label: 'Back', fromRow: 0, toRow: 4, price: 1200),
      ];
      expect(PriceBand.uncoveredRows(bands, 6), [5]);
    });

    test('bands that cover every row leave nothing unpriced', () {
      const bands = [
        PriceBand(label: 'Front', fromRow: 0, toRow: 4, price: 1700),
        PriceBand(label: 'Back', fromRow: 5, toRow: 5, price: 1200),
      ];
      expect(PriceBand.uncoveredRows(bands, 6), isEmpty);
    });

    test('a backwards band still counts, gaps in the middle are found', () {
      const bands = [
        PriceBand(label: 'A', fromRow: 2, toRow: 0, price: 1500),
        PriceBand(label: 'B', fromRow: 5, toRow: 6, price: 1000),
      ];
      expect(PriceBand.uncoveredRows(bands, 7), [3, 4]);
    });

    test('no bands at all = every row unpriced', () {
      expect(PriceBand.uncoveredRows(const [], 3), [0, 1, 2]);
    });
  });

  group('Bus.copyWith(clearSeatTypePrices)', () {
    Bus leftover() => Bus(
          name: 'RSR',
          pricePerSeat: 0.14,
          singleSofaPrice: 0.14,
          doubleSofaPrice: 2757,
          seaterPrice: 900,
          rearRows: 2,
          rearPrice: 800,
          priceBands: const [
            PriceBand(label: 'Front', fromRow: 0, toRow: 4, price: 1700),
          ],
        );

    test('drops every per-type price and the rear zone, keeps the bands', () {
      final b = leftover().copyWith(clearSeatTypePrices: true);
      expect(b.singleSofaPrice, isNull);
      expect(b.doubleSofaPrice, isNull);
      expect(b.seaterPrice, isNull);
      expect(b.rearRows, 0);
      expect(b.rearPrice, isNull);
      expect(b.priceBands, hasLength(1));
    });

    test('the cleared bus can never price a banded row from a leftover', () {
      final b = leftover().copyWith(clearSeatTypePrices: true);
      expect(b.berthPriceFor(SeatType.singleSofa, 0), 1700);
      expect(b.berthPriceFor(SeatType.doubleSofa, 4), 1700);
    });

    test('without the flag nothing is cleared (?? semantics unchanged)', () {
      final b = leftover().copyWith();
      expect(b.singleSofaPrice, 0.14);
      expect(b.doubleSofaPrice, 2757);
      expect(b.rearRows, 2);
    });

    test('the clear reaches the write payload as explicit nulls', () {
      final patch = leftover()
          .copyWith(clearSeatTypePrices: true)
          .toPatch(includeLayout: false);
      expect(patch['single_sofa_price'], isNull);
      expect(patch.containsKey('single_sofa_price'), isTrue);
      expect(patch['double_sofa_price'], isNull);
      expect(patch['rear_price'], isNull);
    });
  });
}
