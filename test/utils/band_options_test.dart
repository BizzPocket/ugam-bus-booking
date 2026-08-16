import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/bus_details.dart';
import 'package:occubusbooking/models/seat_layout.dart';
import 'package:occubusbooking/models/seat_type.dart';
import 'package:occubusbooking/utils/band_options.dart';
import 'package:occubusbooking/utils/chart_seat_availability.dart';

void main() {
  /// A cell of [type] at [row].
  SeatCell cell(int row, int col, SeatType type, String id) =>
      SeatCell(row: row, col: col, seatType: type, seatId: id);

  /// The live bus, as read from Supabase on 2026-08-16: 6 rows, every row
  /// carrying both sofa types, priced by three bands that cover every row.
  ///   rows 0-3  Rs 1,600     row 4  Rs 1,500     row 5  Rs 1,200
  /// All three bands share the label 'બેન્ડ' — which is exactly why a band is
  /// identified by price and rows, never by that string.
  Bus liveBus({String id = 'bus1'}) => Bus(
        id: id,
        name: 'મોમાઈ કૃપા',
        pricePerSeat: 1351.35,
        singleSofaPrice: 1351.35,
        doubleSofaPrice: 2702.70,
        priceBands: const [
          PriceBand(label: 'બેન્ડ', fromRow: 0, toRow: 3, price: 1600),
          PriceBand(label: 'બેન્ડ', fromRow: 4, toRow: 4, price: 1500),
          PriceBand(label: 'બેન્ડ', fromRow: 5, toRow: 5, price: 1200),
        ],
        layout: BusLayout(
          rows: 6,
          cols: 5,
          grid: [
            for (var r = 0; r < 6; r++) ...[
              cell(r, 0, SeatType.doubleSofa, 'DL$r'),
              cell(r, 4, SeatType.singleSofa, 'SL$r'),
            ],
          ],
        ),
      );

  group('bandOptionsFor', () {
    test('offers one option per band, priced per berth for a single sofa', () {
      final options =
          bandOptionsFor(buses: [liveBus()], type: SeatType.singleSofa);

      expect(options.map((o) => o.unitPricePaise), [160000, 150000, 120000]);
    });

    test('prices a whole double sofa as two berths of the band', () {
      // Bus.berthPriceFor: a band price is per berth regardless of seat type.
      final options =
          bandOptionsFor(buses: [liveBus()], type: SeatType.doubleSofa);

      expect(options.map((o) => o.unitPricePaise), [320000, 300000, 240000]);
    });

    test('orders options front to back by row', () {
      final options =
          bandOptionsFor(buses: [liveBus()], type: SeatType.singleSofa);

      expect(options.map((o) => o.band.fromRow), [0, 4, 5]);
    });

    test('de-duplicates identical bands across two buses', () {
      // The live tour has two buses carrying the SAME three bands. The customer
      // must see three choices, not six.
      final options = bandOptionsFor(
        buses: [liveBus(id: 'bus1'), liveBus(id: 'bus2')],
        type: SeatType.singleSofa,
      );

      expect(options.length, 3);
    });

    test('excludes a band that holds no seat of the requested type', () {
      // A band is a ROW RANGE. If the front rows are all doubles, there is no
      // such thing as a single sofa in the front band — offering it would take
      // money for a seat that cannot be delivered.
      final bus = Bus(
        id: 'b',
        name: 'b',
        pricePerSeat: 1000,
        priceBands: const [
          PriceBand(label: 'front', fromRow: 0, toRow: 0, price: 1600),
          PriceBand(label: 'back', fromRow: 1, toRow: 1, price: 1200),
        ],
        layout: BusLayout(rows: 2, cols: 2, grid: [
          cell(0, 0, SeatType.doubleSofa, 'DL0'),
          cell(1, 0, SeatType.singleSofa, 'SL1'),
        ]),
      );

      final singles = bandOptionsFor(buses: [bus], type: SeatType.singleSofa);

      expect(singles.length, 1);
      expect(singles.single.band.fromRow, 1);
    });

    test('offers a standard option for rows no band covers', () {
      // Bands cover row 0 only; row 1 falls through to the per-type price.
      final bus = Bus(
        id: 'b',
        name: 'b',
        pricePerSeat: 1000,
        singleSofaPrice: 900,
        priceBands: const [
          PriceBand(label: 'front', fromRow: 0, toRow: 0, price: 1600),
        ],
        layout: BusLayout(rows: 2, cols: 2, grid: [
          cell(0, 0, SeatType.singleSofa, 'SL0'),
          cell(1, 0, SeatType.singleSofa, 'SL1'),
        ]),
      );

      final options = bandOptionsFor(buses: [bus], type: SeatType.singleSofa);

      expect(options.map((o) => o.unitPricePaise), [160000, 90000]);
      expect(options.last.isStandard, isTrue);
    });

    test('an unbanded bus offers a single standard option', () {
      final bus = Bus(
        id: 'b',
        name: 'b',
        pricePerSeat: 800,
        layout: BusLayout(rows: 1, cols: 2, grid: [
          cell(0, 0, SeatType.singleSofa, 'SL0'),
        ]),
      );

      final options = bandOptionsFor(buses: [bus], type: SeatType.singleSofa);

      expect(options.single.unitPricePaise, 80000);
      expect(options.single.isStandard, isTrue);
    });

    test('a bus with no layout offers nothing', () {
      // No grid means no rows to price. Offering a band here would quote a
      // price against seats we cannot prove exist.
      final bus = Bus(id: 'b', name: 'b', pricePerSeat: 800);

      expect(bandOptionsFor(buses: [bus], type: SeatType.singleSofa), isEmpty);
    });

    test('with no occupancy every unit reads free', () {
      // The server only emits OCCUPIED seats, so an empty feed on a loaded
      // summary genuinely means nothing is booked.
      final options =
          bandOptionsFor(buses: [liveBus()], type: SeatType.singleSofa);

      // Rows 0-3 carry one single sofa each.
      expect(options.first.freeUnits, 4);
      expect(options.first.soldOut, isFalse);
    });

    test('a booked seat is removed from its band', () {
      final options = bandOptionsFor(
        buses: [liveBus()],
        type: SeatType.singleSofa,
        availability: availabilityByKey([
          SeatAvailability(busId: 'bus1', seatId: 'SL0', usedGo: 1, usedRet: 1),
        ]),
      );

      expect(options.first.freeUnits, 3);
    });

    test('a one-leg booking still blocks a full-trip unit', () {
      // A round-trip rider needs the berth on BOTH legs. Someone holding only
      // the outbound leg is enough to make it unsellable as a full trip.
      final options = bandOptionsFor(
        buses: [liveBus()],
        type: SeatType.singleSofa,
        availability: availabilityByKey([
          SeatAvailability(busId: 'bus1', seatId: 'SL0', usedGo: 1),
        ]),
      );

      expect(options.first.freeUnits, 3);
    });

    test('a HALF-taken double sofa is not a free double', () {
      // A whole unit must fit — a fresh pair cannot sit on a half-sold sofa.
      final options = bandOptionsFor(
        buses: [liveBus()],
        type: SeatType.doubleSofa,
        availability: availabilityByKey([
          SeatAvailability(busId: 'bus1', seatId: 'DL0', usedGo: 1, usedRet: 1),
        ]),
      );

      expect(options.first.freeUnits, 3);
    });

    test('a band with every seat gone is sold out', () {
      final options = bandOptionsFor(
        buses: [liveBus()],
        type: SeatType.singleSofa,
        availability: availabilityByKey([
          SeatAvailability(busId: 'bus1', seatId: 'SL5', usedGo: 1, usedRet: 1),
        ]),
      );

      // Row 5 is the Rs 1,200 band and holds exactly one single sofa.
      final cheapest = options.last;
      expect(cheapest.band.pricePaise, 120000);
      expect(cheapest.freeUnits, 0);
      expect(cheapest.soldOut, isTrue);
    });

    test('free units SUM across two buses sharing a band', () {
      final options = bandOptionsFor(
        buses: [liveBus(id: 'bus1'), liveBus(id: 'bus2')],
        type: SeatType.singleSofa,
      );

      expect(options.length, 3, reason: 'still one choice per band');
      expect(options.first.freeUnits, 8, reason: '4 rows on each of two buses');
    });

    test('a zero-priced bus offers nothing', () {
      // Request-mode tours routinely sit at price_per_seat 0 until the agent
      // prices the bus. Quoting Rs 0 would let a rider "pay" nothing and be
      // treated as paid.
      final bus = Bus(
        id: 'b',
        name: 'b',
        pricePerSeat: 0,
        layout: BusLayout(rows: 1, cols: 2, grid: [
          cell(0, 0, SeatType.singleSofa, 'SL0'),
        ]),
      );

      expect(bandOptionsFor(buses: [bus], type: SeatType.singleSofa), isEmpty);
    });
  });
}
