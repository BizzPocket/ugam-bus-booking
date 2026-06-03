import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/bus_details.dart';
import 'package:occubusbooking/models/seat_layout.dart';
import 'package:occubusbooking/models/seat_type.dart';
import 'package:occubusbooking/models/passenger.dart';
import 'package:occubusbooking/models/seat_assignment.dart';
import 'package:occubusbooking/models/trip_type.dart';

void main() {
  // A bus with one of each seat type and known prices.
  //   Double Sofa (whole) = 1550, one berth = 775
  //   Single Sofa         = 1200
  //   Seater              = 900
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
          SeatCell(
            row: 1,
            col: 0,
            seatType: SeatType.seater,
            seatId: 'ST1',
          ),
        ]),
      );

  Passenger passenger({
    required List<SeatAssignment> seats,
    TripType tripType = TripType.roundTrip,
  }) =>
      Passenger(
        tourId: 't1',
        name: 'x',
        phone: '1',
        assignedSeats: seats,
        tripType: tripType,
      );

  group('fare calculation', () {
    test('whole Double Sofa — round/outbound/return', () {
      final bus = buildBus();
      final whole = [
        const SeatAssignment(busId: 'bus1', seatId: 'DL1'),
        const SeatAssignment(busId: 'bus1', seatId: 'DL1'),
      ];
      expect(
        bus.amountDueFor(passenger(seats: whole, tripType: TripType.roundTrip)),
        1550,
      );
      expect(
        bus.amountDueFor(
            passenger(seats: whole, tripType: TripType.outboundOnly)),
        closeTo(775, 1e-9),
      );
      expect(
        bus.amountDueFor(passenger(seats: whole, tripType: TripType.returnOnly)),
        closeTo(775, 1e-9),
      );
    });

    test('shared Double Sofa — one berth', () {
      final bus = buildBus();
      final shared = [const SeatAssignment(busId: 'bus1', seatId: 'DL1')];
      expect(
        bus.amountDueFor(
            passenger(seats: shared, tripType: TripType.roundTrip)),
        closeTo(775, 1e-9),
      );
      expect(
        bus.amountDueFor(
            passenger(seats: shared, tripType: TripType.outboundOnly)),
        closeTo(387.5, 1e-9),
      );
    });

    test('Single Sofa', () {
      final bus = buildBus();
      final single = [const SeatAssignment(busId: 'bus1', seatId: 'SL1')];
      expect(
        bus.amountDueFor(
            passenger(seats: single, tripType: TripType.roundTrip)),
        1200,
      );
      expect(
        bus.amountDueFor(
            passenger(seats: single, tripType: TripType.outboundOnly)),
        closeTo(600, 1e-9),
      );
    });

    test('Seater', () {
      final bus = buildBus();
      final seater = [const SeatAssignment(busId: 'bus1', seatId: 'ST1')];
      expect(
        bus.amountDueFor(
            passenger(seats: seater, tripType: TripType.roundTrip)),
        900,
      );
      expect(
        bus.amountDueFor(
            passenger(seats: seater, tripType: TripType.outboundOnly)),
        closeTo(450, 1e-9),
      );
    });

    test('price fallback to pricePerSeat when type price null', () {
      final bus = Bus(
        id: 'bus1',
        name: 'Bus 1',
        pricePerSeat: 1000,
        // singleSofaPrice and doubleSofaPrice left null.
        layout: BusLayout(rows: 1, cols: 5, grid: const [
          SeatCell(
            row: 0,
            col: 1,
            seatType: SeatType.singleSofa,
            position: SeatPosition.lower,
            seatId: 'SL1',
          ),
          SeatCell(
            row: 0,
            col: 4,
            seatType: SeatType.doubleSofa,
            position: SeatPosition.lower,
            seatId: 'DL1',
          ),
        ]),
      );
      // No overrides: every berth is the per-person base price.
      expect(bus.berthPriceFor(SeatType.singleSofa, 0), 1000);
      expect(bus.berthPriceFor(SeatType.doubleSofa, 0), 1000);

      // A WHOLE double sofa (two entries on the same seatId) now costs
      // 2 × pricePerSeat under the per-person model, not 1 × as before.
      final whole = [
        const SeatAssignment(busId: 'bus1', seatId: 'DL1'),
        const SeatAssignment(busId: 'bus1', seatId: 'DL1'),
      ];
      expect(
        bus.amountDueFor(passenger(seats: whole, tripType: TripType.roundTrip)),
        2000,
      );
    });

    test('tripFactor', () {
      expect(Bus.tripFactor(TripType.roundTrip), 1.0);
      expect(Bus.tripFactor(TripType.outboundOnly), 0.5);
      expect(Bus.tripFactor(TripType.returnOnly), 0.5);
    });

    test('seats on a different bus contribute 0', () {
      final bus = buildBus();
      final otherBus = [const SeatAssignment(busId: 'bus2', seatId: 'DL1')];
      expect(
        bus.amountDueFor(
            passenger(seats: otherBus, tripType: TripType.roundTrip)),
        0,
      );
    });
  });

  group('rear-zone pricing', () {
    // 4-row bus, base 10/seat, last 2 rows (rows 2 & 3) priced at 8/seat, no
    // per-type overrides. Front seats live in rows 0–1, rear in rows 2–3.
    //   Front (rows 0–1): single SLf=10, double DLf whole=20 / berth=10
    //   Rear  (rows 2–3): single SLr=8,  double DLr whole=16 / berth=8
    Bus rearBus() => Bus(
          id: 'rbus',
          name: 'Rear Bus',
          pricePerSeat: 10,
          rearRows: 2,
          rearPrice: 8,
          layout: BusLayout(rows: 4, cols: 5, grid: const [
            // Front row.
            SeatCell(
              row: 0,
              col: 1,
              seatType: SeatType.singleSofa,
              position: SeatPosition.lower,
              seatId: 'SLf',
            ),
            SeatCell(
              row: 0,
              col: 4,
              seatType: SeatType.doubleSofa,
              position: SeatPosition.lower,
              seatId: 'DLf',
            ),
            // Rear row (in the last 2 rows).
            SeatCell(
              row: 3,
              col: 1,
              seatType: SeatType.singleSofa,
              position: SeatPosition.lower,
              seatId: 'SLr',
            ),
            SeatCell(
              row: 3,
              col: 4,
              seatType: SeatType.doubleSofa,
              position: SeatPosition.lower,
              seatId: 'DLr',
            ),
          ]),
        );

    test('single sofa berth: front = base, rear = rearPrice', () {
      final bus = rearBus();
      // berthPriceFor keys off the row index directly.
      expect(bus.berthPriceFor(SeatType.singleSofa, 0), 10);
      expect(bus.berthPriceFor(SeatType.singleSofa, 3), 8);
    });

    test('whole double sofa: front = 20, rear = 16', () {
      final bus = rearBus();
      final wholeFront = [
        const SeatAssignment(busId: 'rbus', seatId: 'DLf'),
        const SeatAssignment(busId: 'rbus', seatId: 'DLf'),
      ];
      final wholeRear = [
        const SeatAssignment(busId: 'rbus', seatId: 'DLr'),
        const SeatAssignment(busId: 'rbus', seatId: 'DLr'),
      ];
      expect(
        bus.amountDueFor(
            passenger(seats: wholeFront, tripType: TripType.roundTrip)),
        20,
      );
      expect(
        bus.amountDueFor(
            passenger(seats: wholeRear, tripType: TripType.roundTrip)),
        16,
      );
    });

    test('one shared double berth: front = 10, rear = 8', () {
      final bus = rearBus();
      final sharedFront = [const SeatAssignment(busId: 'rbus', seatId: 'DLf')];
      final sharedRear = [const SeatAssignment(busId: 'rbus', seatId: 'DLr')];
      expect(
        bus.amountDueFor(
            passenger(seats: sharedFront, tripType: TripType.roundTrip)),
        10,
      );
      expect(
        bus.amountDueFor(
            passenger(seats: sharedRear, tripType: TripType.roundTrip)),
        8,
      );
    });

    test('rear zone wins over per-type override; front row uses override', () {
      // doubleSofaPrice override (whole = 30 → berth = 15) set AND a rear zone.
      // A double in the REAR row must price at rearPrice (override ignored);
      // the same type in a FRONT row must use the override.
      final bus = Bus(
        id: 'obus',
        name: 'Override Bus',
        pricePerSeat: 10,
        doubleSofaPrice: 30, // whole-sofa override; berth = 15.
        singleSofaPrice: 25, // per-person override.
        rearRows: 1,
        rearPrice: 8,
        layout: BusLayout(rows: 3, cols: 5, grid: const [
          SeatCell(
            row: 0,
            col: 4,
            seatType: SeatType.doubleSofa,
            position: SeatPosition.lower,
            seatId: 'DLf',
          ),
          SeatCell(
            row: 0,
            col: 1,
            seatType: SeatType.singleSofa,
            position: SeatPosition.lower,
            seatId: 'SLf',
          ),
          // Rear (last row, index 2).
          SeatCell(
            row: 2,
            col: 4,
            seatType: SeatType.doubleSofa,
            position: SeatPosition.lower,
            seatId: 'DLr',
          ),
          SeatCell(
            row: 2,
            col: 1,
            seatType: SeatType.singleSofa,
            position: SeatPosition.lower,
            seatId: 'SLr',
          ),
        ]),
      );
      // Front rows: overrides apply.
      expect(bus.berthPriceFor(SeatType.doubleSofa, 0), 15); // 30 / 2
      expect(bus.berthPriceFor(SeatType.singleSofa, 0), 25);
      // Rear row: rearPrice wins for all types, overrides ignored.
      expect(bus.berthPriceFor(SeatType.doubleSofa, 2), 8);
      expect(bus.berthPriceFor(SeatType.singleSofa, 2), 8);
    });

    test('rearRows greater than total rows clamps to whole bus', () {
      // rearRows (5) > layout.rows (2): every row — including the front-most —
      // is in the rear zone, so front-row seats also get rearPrice.
      final bus = Bus(
        id: 'cbus',
        name: 'Clamp Bus',
        pricePerSeat: 10,
        rearRows: 5,
        rearPrice: 8,
        layout: BusLayout(rows: 2, cols: 5, grid: const [
          SeatCell(
            row: 0,
            col: 1,
            seatType: SeatType.singleSofa,
            position: SeatPosition.lower,
            seatId: 'SL0',
          ),
          SeatCell(
            row: 1,
            col: 1,
            seatType: SeatType.singleSofa,
            position: SeatPosition.lower,
            seatId: 'SL1',
          ),
        ]),
      );
      // row 0 - (2 - 5) = row 0 >= -3 → true, so even the front-most row is rear.
      expect(bus.berthPriceFor(SeatType.singleSofa, 0), 8);
      expect(bus.berthPriceFor(SeatType.singleSofa, 1), 8);
    });

    test('rearRows > 0 but rearPrice null falls back to base/override', () {
      // No rear effect when rearPrice is null — rear rows use base/override.
      final bus = Bus(
        id: 'nbus',
        name: 'Null Rear Bus',
        pricePerSeat: 10,
        seaterPrice: 12, // override to prove the front-path still applies.
        rearRows: 2,
        // rearPrice intentionally left null.
        layout: BusLayout(rows: 4, cols: 5, grid: const [
          SeatCell(
            row: 0,
            col: 0,
            seatType: SeatType.seater,
            seatId: 'STf',
          ),
          SeatCell(
            row: 3,
            col: 0,
            seatType: SeatType.seater,
            seatId: 'STr',
          ),
          SeatCell(
            row: 3,
            col: 1,
            seatType: SeatType.singleSofa,
            position: SeatPosition.lower,
            seatId: 'SLr',
          ),
        ]),
      );
      // Rear rows behave exactly like front rows: override / base, no rear price.
      expect(bus.berthPriceFor(SeatType.seater, 0), 12); // front, override
      expect(bus.berthPriceFor(SeatType.seater, 3), 12); // rear row, still override
      expect(bus.berthPriceFor(SeatType.singleSofa, 3), 10); // rear row, base
    });

    test('trip factor halves a rear-zone seat for a single leg', () {
      final bus = rearBus();
      final sharedRear = [const SeatAssignment(busId: 'rbus', seatId: 'DLr')];
      final wholeRear = [
        const SeatAssignment(busId: 'rbus', seatId: 'DLr'),
        const SeatAssignment(busId: 'rbus', seatId: 'DLr'),
      ];
      // Shared rear berth: round = 8, single leg = 4.
      expect(
        bus.amountDueFor(
            passenger(seats: sharedRear, tripType: TripType.roundTrip)),
        8,
      );
      expect(
        bus.amountDueFor(
            passenger(seats: sharedRear, tripType: TripType.outboundOnly)),
        closeTo(4, 1e-9),
      );
      expect(
        bus.amountDueFor(
            passenger(seats: sharedRear, tripType: TripType.returnOnly)),
        closeTo(4, 1e-9),
      );
      // Whole rear double: round = 16, single leg = 8.
      expect(
        bus.amountDueFor(
            passenger(seats: wholeRear, tripType: TripType.outboundOnly)),
        closeTo(8, 1e-9),
      );
      // amountDueForSeat on one rear berth also honours the trip factor.
      expect(
        bus.amountDueForSeat(
            passenger(seats: sharedRear, tripType: TripType.outboundOnly),
            'DLr'),
        closeTo(4, 1e-9),
      );
    });
  });
}
