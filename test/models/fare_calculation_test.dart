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

  // ─────────────────────────────────────────────────────────────────────────
  // WHOLE-SOFA FIX: amountDueForSeat is the per-collection-record amount.
  // Collections are keyed (passenger, bus, seat), so a whole double sofa is ONE
  // record that must carry the FULL sofa price; a shared double is half.
  // ─────────────────────────────────────────────────────────────────────────
  group('amountDueForSeat — whole vs shared double sofa', () {
    test('sole occupant of a whole double sofa → FULL sofa price', () {
      final bus = buildBus(); // doubleSofaPrice = 1550
      // Two entries on the same seat held by one passenger = whole sofa.
      final whole = passenger(seats: const [
        SeatAssignment(busId: 'bus1', seatId: 'DL1'),
        SeatAssignment(busId: 'bus1', seatId: 'DL1'),
      ]);
      // The single collection record for DL1 owes the full 1550, NOT 775.
      expect(bus.amountDueForSeat(whole, 'DL1'), 1550);
    });

    test('shared double sofa (one berth held) → HALF price', () {
      final bus = buildBus();
      final shared = passenger(
          seats: const [SeatAssignment(busId: 'bus1', seatId: 'DL1')]);
      expect(bus.amountDueForSeat(shared, 'DL1'), closeTo(775, 1e-9));
    });

    test('whole double sofa honours the trip factor on the single leg', () {
      final bus = buildBus();
      final whole = passenger(
        seats: const [
          SeatAssignment(busId: 'bus1', seatId: 'DL1'),
          SeatAssignment(busId: 'bus1', seatId: 'DL1'),
        ],
        tripType: TripType.outboundOnly,
      );
      expect(bus.amountDueForSeat(whole, 'DL1'), closeTo(775, 1e-9));
    });

    test('single sofa is always one berth', () {
      final bus = buildBus(); // singleSofaPrice = 1200
      final p = passenger(
          seats: const [SeatAssignment(busId: 'bus1', seatId: 'SL1')]);
      expect(bus.amountDueForSeat(p, 'SL1'), 1200);
    });

    test('seater is always one berth', () {
      final bus = buildBus(); // seaterPrice = 900
      final p = passenger(
          seats: const [SeatAssignment(busId: 'bus1', seatId: 'ST1')]);
      expect(bus.amountDueForSeat(p, 'ST1'), 900);
    });

    test('whole sofa with no doubleSofaPrice override → 2 × base', () {
      final bus = Bus(
        id: 'bus1',
        name: 'Bus 1',
        pricePerSeat: 1000, // no doubleSofaPrice override
        layout: BusLayout(rows: 1, cols: 5, grid: const [
          SeatCell(
            row: 0,
            col: 4,
            seatType: SeatType.doubleSofa,
            position: SeatPosition.lower,
            seatId: 'DL1',
          ),
        ]),
      );
      final whole = passenger(seats: const [
        SeatAssignment(busId: 'bus1', seatId: 'DL1'),
        SeatAssignment(busId: 'bus1', seatId: 'DL1'),
      ]);
      // berth = 1000, both berths held = 2000.
      expect(bus.amountDueForSeat(whole, 'DL1'), 2000);
    });

    test('amountDueFor and per-seat agree for a whole sofa', () {
      // The passenger total (summed per entry) equals the single per-seat
      // record amount for a whole sofa — both are the full 1550.
      final bus = buildBus();
      final whole = passenger(seats: const [
        SeatAssignment(busId: 'bus1', seatId: 'DL1'),
        SeatAssignment(busId: 'bus1', seatId: 'DL1'),
      ]);
      expect(bus.amountDueFor(whole), 1550);
      expect(bus.amountDueForSeat(whole, 'DL1'), 1550);
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

  // ─────────────────────────────────────────────────────────────────────────
  // FLEXIBLE PRICE BANDS: named row ranges that override base/per-type pricing.
  // ─────────────────────────────────────────────────────────────────────────
  group('price bands', () {
    // 4-row bus, base 10/berth, type overrides on single/seater. A FRONT band
    // (rows 0-0) prices that row at 15/berth; a BACK band (rows 3-3) at 6/berth.
    Bus bandedBus() => Bus(
          id: 'pbus',
          name: 'Banded Bus',
          pricePerSeat: 10,
          singleSofaPrice: 25,
          seaterPrice: 12,
          priceBands: const [
            PriceBand(label: 'Front premium', fromRow: 0, toRow: 0, price: 15),
            PriceBand(label: 'Back discount', fromRow: 3, toRow: 3, price: 6),
          ],
          layout: BusLayout(rows: 4, cols: 5, grid: const [
            SeatCell(
              row: 0,
              col: 1,
              seatType: SeatType.singleSofa,
              position: SeatPosition.lower,
              seatId: 'SL0',
            ),
            SeatCell(
              row: 0,
              col: 4,
              seatType: SeatType.doubleSofa,
              position: SeatPosition.lower,
              seatId: 'DL0',
            ),
            SeatCell(
              row: 1,
              col: 1,
              seatType: SeatType.singleSofa,
              position: SeatPosition.lower,
              seatId: 'SL1',
            ),
            SeatCell(
              row: 3,
              col: 4,
              seatType: SeatType.doubleSofa,
              position: SeatPosition.lower,
              seatId: 'DL3',
            ),
          ]),
        );

    test('PriceBand.covers is inclusive and order-agnostic', () {
      const b = PriceBand(label: 'x', fromRow: 1, toRow: 3, price: 5);
      expect(b.covers(0), isFalse);
      expect(b.covers(1), isTrue);
      expect(b.covers(3), isTrue);
      expect(b.covers(4), isFalse);
      // Backwards bounds normalise to the same range.
      const rev = PriceBand(label: 'x', fromRow: 3, toRow: 1, price: 5);
      expect(rev.covers(2), isTrue);
    });

    test('band wins over per-type override and base, per type-independent', () {
      final bus = bandedBus();
      // Row 0 in the front band: every type prices at 15, ignoring overrides.
      expect(bus.berthPriceFor(SeatType.singleSofa, 0), 15);
      expect(bus.berthPriceFor(SeatType.doubleSofa, 0), 15);
      // Row 1 has no band: single uses its override (25).
      expect(bus.berthPriceFor(SeatType.singleSofa, 1), 25);
      // Row 3 in the back band: 6 regardless of type.
      expect(bus.berthPriceFor(SeatType.doubleSofa, 3), 6);
    });

    test('whole double sofa inside a band = 2 × band price', () {
      final bus = bandedBus();
      final wholeFront = passenger(seats: const [
        SeatAssignment(busId: 'pbus', seatId: 'DL0'),
        SeatAssignment(busId: 'pbus', seatId: 'DL0'),
      ]);
      // Front band 15/berth → whole = 30.
      expect(bus.amountDueForSeat(wholeFront, 'DL0'), 30);
      final wholeBack = passenger(seats: const [
        SeatAssignment(busId: 'pbus', seatId: 'DL3'),
        SeatAssignment(busId: 'pbus', seatId: 'DL3'),
      ]);
      // Back band 6/berth → whole = 12.
      expect(bus.amountDueForSeat(wholeBack, 'DL3'), 12);
    });

    test('first matching band wins on overlap', () {
      final bus = Bus(
        id: 'ovl',
        name: 'Overlap',
        pricePerSeat: 10,
        priceBands: const [
          PriceBand(label: 'A', fromRow: 0, toRow: 2, price: 20),
          PriceBand(label: 'B', fromRow: 1, toRow: 3, price: 30),
        ],
        layout: BusLayout.empty(4),
      );
      // Row 1 is covered by both; the first (A=20) wins.
      expect(bus.berthPriceFor(SeatType.seater, 1), 20);
      // Row 3 only by B.
      expect(bus.berthPriceFor(SeatType.seater, 3), 30);
    });

    test('legacy rear zone becomes an effective trailing band', () {
      // Only rear_rows/rear_price set (no explicit priceBands): the engine
      // still prices the last rows via the synthesized band.
      final bus = Bus(
        id: 'legacy',
        name: 'Legacy Rear',
        pricePerSeat: 10,
        rearRows: 2,
        rearPrice: 8,
        layout: BusLayout.empty(4),
      );
      expect(bus.berthPriceFor(SeatType.seater, 0), 10); // front
      expect(bus.berthPriceFor(SeatType.seater, 2), 8); // rear
      expect(bus.berthPriceFor(SeatType.seater, 3), 8); // rear
      // effectiveBands exposes exactly one synthesized 'Rear' band.
      expect(bus.effectiveBands.length, 1);
      expect(bus.effectiveBands.first.label, 'Rear');
      expect(bus.effectiveBands.first.fromRow, 2);
      expect(bus.effectiveBands.first.toRow, 3);
    });

    test('explicit bands take priority over the legacy rear zone', () {
      final bus = Bus(
        id: 'mix',
        name: 'Mix',
        pricePerSeat: 10,
        rearRows: 2, // rear band would cover rows 2-3 at 8
        rearPrice: 8,
        priceBands: const [
          // Explicit band also covers row 3 at 5 — listed first, so it wins.
          PriceBand(label: 'VIP back', fromRow: 3, toRow: 3, price: 5),
        ],
        layout: BusLayout.empty(4),
      );
      expect(bus.berthPriceFor(SeatType.seater, 3), 5); // explicit wins
      expect(bus.berthPriceFor(SeatType.seater, 2), 8); // rear band only
      expect(bus.berthPriceFor(SeatType.seater, 0), 10); // base
    });

    test('serialization round-trips price bands', () {
      final bus = bandedBus();
      final restored = Bus.fromMap(bus.toMap());
      expect(restored.priceBands.length, 2);
      expect(restored.priceBands.first.label, 'Front premium');
      expect(restored.priceBands.first.price, 15);
      expect(restored.berthPriceFor(SeatType.doubleSofa, 0), 15);
      expect(restored.berthPriceFor(SeatType.singleSofa, 3), 6);
    });

    test('price_bands parses from a JSON string column', () {
      final map = bandedBus().toMap();
      // Simulate jsonb handed back as a String.
      map['price_bands'] =
          '[{"label":"Solo","fromRow":2,"toRow":2,"price":99}]';
      final restored = Bus.fromMap(map);
      expect(restored.priceBands.length, 1);
      expect(restored.berthPriceFor(SeatType.seater, 2), 99);
    });

    test('malformed price_bands falls back to empty', () {
      final map = bandedBus().toMap();
      map['price_bands'] = 'not json at all';
      final restored = Bus.fromMap(map);
      expect(restored.priceBands, isEmpty);
    });
  });
}
