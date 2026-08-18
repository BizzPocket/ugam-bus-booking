import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/bus_details.dart';
import 'package:occubusbooking/models/passenger.dart';
import 'package:occubusbooking/models/request_band.dart';
import 'package:occubusbooking/models/request_line.dart';
import 'package:occubusbooking/models/seat_layout.dart';
import 'package:occubusbooking/models/seat_type.dart';
import 'package:occubusbooking/models/trip_type.dart';
import 'package:occubusbooking/services/seating_engine.dart';

/// A rider who PAID for a band bought a seat in those rows. The engine has to
/// honour that: seating a Rs 1,600 front-band payer in the Rs 1,200 back row is
/// taking the higher fare and delivering the cheaper seat.
void main() {
  SeatCell cell(int row, int col, SeatType type, String id) =>
      SeatCell(row: row, col: col, seatType: type, seatId: id);

  /// Six rows, one single sofa each. Front band = rows 0-3, back band = 4-5.
  Bus bus() => Bus(
        id: 'b1',
        name: 'b1',
        busType: 'Sleeper',
        pricePerSeat: 1000,
        priceBands: const [
          PriceBand(label: 'front', fromRow: 0, toRow: 3, price: 1600),
          PriceBand(label: 'back', fromRow: 4, toRow: 5, price: 1200),
        ],
        layout: BusLayout(
          rows: 6,
          cols: SeatGridCols.count,
          grid: [
            for (var r = 0; r < 6; r++)
              cell(r, 0, SeatType.singleSofa, 'SU$r'),
          ],
        ),
      );

  const backBand =
      RequestBand(label: 'back', fromRow: 4, toRow: 5, pricePaise: 120000);
  const frontBand =
      RequestBand(label: 'front', fromRow: 0, toRow: 3, pricePaise: 160000);

  Passenger rider({
    required String id,
    RequestBand? band,
    int qty = 1,
  }) =>
      Passenger(
        id: id,
        tourId: 't1',
        name: 'rider$id',
        phone: '+91982401122$id',
        requestLines: [
          RequestLine(
            seatType: SeatType.singleSofa,
            qty: qty,
            leg: TripType.roundTrip,
            band: band,
          ),
        ],
      );

  /// Row of the seat the plan gave [passengerId].
  int rowOf(SeatingPlan plan, String passengerId, Bus b) {
    final seat = plan.forPassenger(passengerId).single;
    return b.layout!.grid.firstWhere((c) => c.seatId == seat.seatId).row;
  }

  test('a back-band payer is seated in the back band, not the front', () {
    // The engine sweeps seats in order, so without a band filter this rider
    // lands in row 0 — the band they did NOT pay for.
    final b = bus();
    final plan = SeatingEngine.propose(
      buses: [b],
      passengers: [rider(id: '1', band: backBand)],
    );

    expect(rowOf(plan, '1', b), inInclusiveRange(4, 5));
  });

  test('a front-band payer stays in the front band', () {
    final b = bus();
    final plan = SeatingEngine.propose(
      buses: [b],
      passengers: [rider(id: '1', band: frontBand)],
    );

    expect(rowOf(plan, '1', b), inInclusiveRange(0, 3));
  });

  test('an unbanded rider is still seated anywhere', () {
    // Legacy requests and one-leg waitlist riders carry no band. They must not
    // become unseatable.
    final b = bus();
    final plan = SeatingEngine.propose(
      buses: [b],
      passengers: [rider(id: '1')],
    );

    expect(plan.forPassenger('1'), hasLength(1));
  });

  test('two riders in the same band take different seats in it', () {
    final b = bus();
    final plan = SeatingEngine.propose(
      buses: [b],
      passengers: [
        rider(id: '1', band: backBand),
        rider(id: '2', band: backBand),
      ],
    );

    final r1 = rowOf(plan, '1', b);
    final r2 = rowOf(plan, '2', b);
    expect(r1, inInclusiveRange(4, 5));
    expect(r2, inInclusiveRange(4, 5));
    expect(r1, isNot(r2));
  });

  test('a band with no seats left raises an exception, not a wrong seat', () {
    // The back band holds two seats. A third back-band payer must surface as a
    // decision for the agent — never be quietly dropped into the front band
    // they did not pay for.
    final b = bus();
    final plan = SeatingEngine.propose(
      buses: [b],
      passengers: [
        rider(id: '1', band: backBand),
        rider(id: '2', band: backBand),
        rider(id: '3', band: backBand),
      ],
    );

    expect(plan.forPassenger('3'), isEmpty);
    expect(plan.exceptions.any((e) => e.passengerId == '3'), isTrue);
  });
}
