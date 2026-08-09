// What an anonymous customer is told about a tour's price and availability.
//
// These are the numbers a stranger reads before deciding to book, so the
// failure modes that matter are the ones that MISLEAD: advertising a berth that
// is already sold, quoting the dearest seat as if it were the cheapest, or
// printing "₹0" for a tour the agent simply hasn't priced yet.

import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/bus_details.dart';
import 'package:occubusbooking/models/seat_layout.dart';
import 'package:occubusbooking/models/seat_type.dart';
import 'package:occubusbooking/models/trip_type.dart';
import 'package:occubusbooking/utils/chart_seat_availability.dart';
import 'package:occubusbooking/utils/tour_public_summary.dart';

/// A bus whose layout is exactly the cells given, so each test states its own
/// seating rather than inheriting a generated one.
Bus busWith({
  required String id,
  required List<SeatCell> grid,
  double pricePerSeat = 0,
  double? singleSofaPrice,
  double? doubleSofaPrice,
  double? seaterPrice,
  List<PriceBand> priceBands = const [],
}) {
  return Bus(
    id: id,
    name: 'Bus $id',
    pricePerSeat: pricePerSeat,
    singleSofaPrice: singleSofaPrice,
    doubleSofaPrice: doubleSofaPrice,
    seaterPrice: seaterPrice,
    priceBands: priceBands,
    layout: BusLayout(rows: 3, cols: SeatGridCols.count, grid: grid),
  );
}

SeatCell seater(int row, int col, String id, {bool reserved = false}) =>
    SeatCell(
      row: row,
      col: col,
      seatType: SeatType.seater,
      seatId: id,
      reserved: reserved,
    );

SeatCell doubleSofa(int row, int col, String id) =>
    SeatCell(row: row, col: col, seatType: SeatType.doubleSofa, seatId: id);

void main() {
  group('Bus.fromBerthPrice — the "from ₹X" a customer is quoted', () {
    test('quotes the CHEAPEST berth, never the dearest', () {
      // A bus with a premium front and a cheap back. Quoting 900 would be a
      // promise the seat picker then breaks.
      final bus = busWith(
        id: 'b1',
        pricePerSeat: 900,
        grid: [seater(0, 0, 'A1'), seater(2, 0, 'C1')],
        priceBands: const [
          PriceBand(label: 'Back', fromRow: 2, toRow: 2, price: 500),
        ],
      );

      expect(bus.fromBerthPrice(TripType.roundTrip), 500);
    });

    test('an unpriced bus reports null, so the page shows nothing not "₹0"', () {
      final bus = busWith(id: 'b1', grid: [seater(0, 0, 'A1')]);

      expect(bus.fromBerthPrice(TripType.roundTrip), isNull);
    });

    test('a seat the organiser held back never sets the price floor', () {
      // The cheap seat exists but is reserved — offering it as the "from" price
      // would advertise a berth nobody can buy.
      final bus = busWith(
        id: 'b1',
        pricePerSeat: 900,
        grid: [seater(0, 0, 'A1'), seater(2, 0, 'C1', reserved: true)],
        priceBands: const [
          PriceBand(label: 'Back', fromRow: 2, toRow: 2, price: 500),
        ],
      );

      expect(bus.fromBerthPrice(TripType.roundTrip), 900);
    });

    test('one leg is half fare', () {
      final bus = busWith(
        id: 'b1',
        pricePerSeat: 800,
        grid: [seater(0, 0, 'A1')],
      );

      expect(bus.fromBerthPrice(TripType.outboundOnly), 400);
      expect(bus.fromBerthPrice(TripType.returnOnly), 400);
    });
  });

  group('summariseTourForPublic — how many berths are really left', () {
    test('a tour with no buses is NOT sold out — it has not opened', () {
      final s = summariseTourForPublic(buses: const [], availability: const {});

      // The distinction matters: isSoldOut drives a "TOUR FULL" chip and a
      // waitlist CTA, which would be a lie on a tour the agent is still
      // setting up.
      expect(s.loaded, isTrue);
      expect(s.hasBuses, isFalse);
      expect(s.isSoldOut, isFalse);
      expect(s.hasSeatCount, isFalse);
    });

    test('a double sofa counts as two berths, a seater as one', () {
      final s = summariseTourForPublic(
        buses: [
          busWith(
            id: 'b1',
            pricePerSeat: 100,
            grid: [seater(0, 0, 'A1'), doubleSofa(1, 0, 'D1')],
          ),
        ],
        availability: const {},
      );

      expect(s.berthsTotal, 3);
      expect(s.berthsFree, 3);
    });

    test('a reserved seat is offered to nobody and is not counted', () {
      final s = summariseTourForPublic(
        buses: [
          busWith(
            id: 'b1',
            pricePerSeat: 100,
            grid: [seater(0, 0, 'A1'), seater(0, 1, 'A2', reserved: true)],
          ),
        ],
        availability: const {},
      );

      expect(s.berthsTotal, 1);
      expect(s.berthsFree, 1);
    });

    test(
      'a berth sold on ONE leg is unavailable to a round-trip rider',
      () {
        // The real scenario: an outbound-only rider holds A1. The berth is free
        // on the return, but a round-trip customer cannot have it — so the
        // public count must not advertise it.
        final s = summariseTourForPublic(
          buses: [
            busWith(
              id: 'b1',
              pricePerSeat: 100,
              grid: [seater(0, 0, 'A1'), seater(0, 1, 'A2')],
            ),
          ],
          availability: {
            'b1|A1': const SeatAvailability(
              busId: 'b1',
              seatId: 'A1',
              usedGo: 1,
            ),
          },
        );

        expect(s.berthsTotal, 2);
        expect(s.berthsFree, 1, reason: 'only A2 is bookable end to end');
        expect(s.isSoldOut, isFalse);
      },
    );

    test('half a double sofa gone still leaves one berth', () {
      final s = summariseTourForPublic(
        buses: [
          busWith(id: 'b1', pricePerSeat: 100, grid: [doubleSofa(0, 0, 'D1')]),
        ],
        availability: {
          'b1|D1': const SeatAvailability(
            busId: 'b1',
            seatId: 'D1',
            usedGo: 1,
            usedRet: 1,
          ),
        },
      );

      expect(s.berthsTotal, 2);
      expect(s.berthsFree, 1);
      expect(s.isSoldOut, isFalse);
    });

    test('every berth taken reports sold out', () {
      final s = summariseTourForPublic(
        buses: [
          busWith(id: 'b1', pricePerSeat: 100, grid: [seater(0, 0, 'A1')]),
        ],
        availability: {
          'b1|A1': const SeatAvailability(
            busId: 'b1',
            seatId: 'A1',
            usedGo: 1,
            usedRet: 1,
          ),
        },
      );

      expect(s.berthsFree, 0);
      expect(s.isSoldOut, isTrue);
    });

    test('the "from" price is the cheapest across ALL buses on the tour', () {
      final s = summariseTourForPublic(
        buses: [
          busWith(id: 'b1', pricePerSeat: 900, grid: [seater(0, 0, 'A1')]),
          busWith(id: 'b2', pricePerSeat: 650, grid: [seater(0, 0, 'A1')]),
        ],
        availability: const {},
      );

      expect(s.fromPrice, 650);
      // Seat IDs repeat across buses, so the occupancy key must be scoped by
      // bus or the two would collide.
      expect(s.berthsTotal, 2);
    });

    test('an unpriced tour reports no price rather than zero', () {
      final s = summariseTourForPublic(
        buses: [busWith(id: 'b1', grid: [seater(0, 0, 'A1')])],
        availability: const {},
      );

      expect(s.fromPrice, isNull);
      expect(s.hasSeatCount, isTrue, reason: 'seats are known even unpriced');
    });

    test('pending is distinguishable from "nothing to sell"', () {
      // publicSummary() returns pending when the RPC fails or is not deployed.
      // If that were confused with an answered-but-empty tour, a chart tour
      // would flip its CTA to "seats open soon" on every network blip.
      expect(TourPublicSummary.pending.loaded, isFalse);
      expect(TourPublicSummary.pending.isSoldOut, isFalse);
      expect(TourPublicSummary.none.loaded, isTrue);
    });
  });
}
