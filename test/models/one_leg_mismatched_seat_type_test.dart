import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/bus_details.dart';
import 'package:occubusbooking/models/seat_layout.dart';
import 'package:occubusbooking/models/seat_type.dart';
import 'package:occubusbooking/models/passenger.dart';
import 'package:occubusbooking/models/request_line.dart';
import 'package:occubusbooking/models/seat_assignment.dart';
import 'package:occubusbooking/models/trip_type.dart';

/// Regression for the live-data bug: a ONE-LEG rider charged FULL price because
/// they were seated in a seat TYPE they did not request.
///
/// Real case (live DB): "ravi vasoya" requested a single sofa RETURN-only, but
/// was assigned to a DOUBLE-sofa berth (DU3) to leg-share the physical sofa with
/// an outbound rider. [Passenger.legForSeatType] keyed the leg off the ASSIGNED
/// seat's type (doubleSofa), found no matching request line, and fell back to
/// round-trip — so the one-leg discount silently vanished and the rider was
/// billed the full fare. Leg-sharing a double sofa is a core feature, so this
/// hits many real passengers, not a rare edge.
void main() {
  // doubleSofaPrice 1550 → one berth 775; singleSofa 1200; seater 900.
  Bus buildBus() => Bus(
        id: 'bus1',
        name: 'Bus 1',
        pricePerSeat: 1000,
        singleSofaPrice: 1200,
        doubleSofaPrice: 1550,
        seaterPrice: 900,
        layout: BusLayout(rows: 3, cols: 5, grid: const [
          SeatCell(
            row: 0,
            col: 4,
            seatType: SeatType.doubleSofa,
            position: SeatPosition.lower,
            seatId: 'DL1',
          ),
          SeatCell(
            row: 0,
            col: 1,
            seatType: SeatType.singleSofa,
            position: SeatPosition.lower,
            seatId: 'SL1',
          ),
        ]),
      );

  group('one-leg rider seated in an unrequested seat type', () {
    test('legForSeatType falls back to the rider overall leg, not round-trip',
        () {
      final rider = Passenger(
        tourId: 't1',
        name: 'ravi',
        phone: '1',
        requestLines: const [
          RequestLine(
            seatType: SeatType.singleSofa,
            qty: 1,
            leg: TripType.returnOnly,
          ),
        ],
        tripType: TripType.returnOnly,
      );
      // Asked about a DOUBLE-sofa seat the rider never requested: must still
      // resolve to the rider's actual leg (return-only), not round-trip.
      expect(rider.legForSeatType(SeatType.doubleSofa), TripType.returnOnly);
    });

    test('single-sofa return-only rider on a double-sofa berth pays HALF', () {
      final bus = buildBus();
      final rider = Passenger(
        tourId: 't1',
        name: 'ravi',
        phone: '1',
        requestLines: const [
          RequestLine(
            seatType: SeatType.singleSofa,
            qty: 1,
            leg: TripType.returnOnly,
          ),
        ],
        assignedSeats: const [SeatAssignment(busId: 'bus1', seatId: 'DL1')],
        tripType: TripType.returnOnly,
      );
      // One double-sofa berth (775) on a single leg → half = 387.5, rounded to
      // a whole rupee at source → 388 (not 775, and never a fractional due).
      expect(bus.amountDueForSeat(rider, 'DL1'), closeTo(388, 1e-9));
      expect(bus.amountDueFor(rider), closeTo(388, 1e-9));
    });

    test('outbound-only rider on an unrequested seater berth pays HALF', () {
      final bus = Bus(
        id: 'b2',
        name: 'B2',
        pricePerSeat: 1000,
        seaterPrice: 900,
        layout: BusLayout(rows: 1, cols: 5, grid: const [
          SeatCell(row: 0, col: 0, seatType: SeatType.seater, seatId: 'ST1'),
        ]),
      );
      final rider = Passenger(
        tourId: 't1',
        name: 'x',
        phone: '1',
        requestLines: const [
          RequestLine(
            seatType: SeatType.singleSofa,
            qty: 1,
            leg: TripType.outboundOnly,
          ),
        ],
        assignedSeats: const [SeatAssignment(busId: 'b2', seatId: 'ST1')],
        tripType: TripType.outboundOnly,
      );
      expect(bus.amountDueForSeat(rider, 'ST1'), closeTo(450, 1e-9));
    });

    test('mixed-leg rider stays round-trip for an unrequested type (no '
        'under-charge)', () {
      final rider = Passenger(
        tourId: 't1',
        name: 'mix',
        phone: '1',
        requestLines: const [
          RequestLine(
            seatType: SeatType.singleSofa,
            qty: 1,
            leg: TripType.roundTrip,
          ),
          RequestLine(
            seatType: SeatType.doubleSofa,
            qty: 1,
            leg: TripType.outboundOnly,
          ),
        ],
        tripType: TripType.roundTrip,
      );
      // Lines disagree on leg → the conservative round-trip, never a discount.
      expect(rider.legForSeatType(SeatType.seater), TripType.roundTrip);
    });

    test('rider with no request lines stays round-trip for any type', () {
      final rider = Passenger(tourId: 't1', name: 'n', phone: '1');
      expect(rider.legForSeatType(SeatType.doubleSofa), TripType.roundTrip);
    });
  });
}
