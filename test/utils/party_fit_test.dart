import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/seat_layout.dart';
import 'package:occubusbooking/models/seat_type.dart';
import 'package:occubusbooking/models/trip_type.dart';
import 'package:occubusbooking/utils/chart_seat_availability.dart';
import 'package:occubusbooking/utils/party_fit.dart';

/// Can this bus seat this party, and how do we say so in the customer's terms?
///
/// The gate asks in PEOPLE ("how many of you?") but explains in SOFAS ("fits
/// your 4 — 2 whole sofas"), because a sleeper customer thinks in sofas and a
/// double sofa is two people. Keeping both numbers straight is the whole job:
/// counting cells instead of berths would let a bus with three free doubles
/// claim it can only take three passengers when it can take six.
///
/// Pure Dart — no Flutter, no network — so the arithmetic is pinned
/// independently of any screen.
void main() {
  const busId = 'bus-1';

  SeatCell dbl(String id, int row) => SeatCell(
        row: row,
        col: 4,
        seatType: SeatType.doubleSofa,
        position: SeatPosition.lower,
        seatId: id,
      );
  SeatCell single(String id, int row) => SeatCell(
        row: row,
        col: 0,
        seatType: SeatType.singleSofa,
        position: SeatPosition.upper,
        seatId: id,
      );

  BusLayout layout(List<SeatCell> cells) => BusLayout(
        rows: cells.length,
        cols: SeatGridCols.count,
        grid: cells,
      );

  group('counting what is free', () {
    test('an empty bus of 3 doubles seats six people as three whole sofas', () {
      final fit = busFit(
        busId: busId,
        layout: layout([dbl('DU1', 0), dbl('DU2', 1), dbl('DU3', 2)]),
        availability: const {},
        leg: TripType.roundTrip,
        people: 6,
      );

      expect(fit.freeBerths, 6, reason: 'a double is TWO people');
      expect(fit.wholeSofas, 3);
      expect(fit.fitsWholeParty, isTrue);
    });

    test('a party of 7 does not fit a 6-berth bus', () {
      final fit = busFit(
        busId: busId,
        layout: layout([dbl('DU1', 0), dbl('DU2', 1), dbl('DU3', 2)]),
        availability: const {},
        leg: TripType.roundTrip,
        people: 7,
      );
      expect(fit.fitsWholeParty, isFalse);
      expect(fit.shortfall, 1);
    });

    test('half-sold doubles reduce berths but also whole sofas', () {
      final fit = busFit(
        busId: busId,
        layout: layout([dbl('DU1', 0), dbl('DU2', 1)]),
        availability: availabilityByKey(const [
          SeatAvailability(busId: busId, seatId: 'DU1', usedGo: 1, usedRet: 1),
        ]),
        leg: TripType.roundTrip,
        people: 3,
      );

      expect(fit.freeBerths, 3, reason: 'one berth of DU1 plus all of DU2');
      expect(
        fit.wholeSofas,
        1,
        reason: 'DU1 can no longer be taken as a whole sofa',
      );
      expect(fit.fitsWholeParty, isTrue);
    });

    test('singles count one berth each and are never whole sofas', () {
      final fit = busFit(
        busId: busId,
        layout: layout([single('SU1', 0), single('SL1', 0)]),
        availability: const {},
        leg: TripType.roundTrip,
        people: 2,
      );
      expect(fit.freeBerths, 2);
      expect(fit.wholeSofas, 0);
      expect(fit.fitsWholeParty, isTrue);
    });

    test('a reserved seat is not offered to anyone', () {
      final fit = busFit(
        busId: busId,
        layout: layout([
          const SeatCell(
            row: 0,
            col: 4,
            seatType: SeatType.doubleSofa,
            position: SeatPosition.lower,
            seatId: 'DU1',
            reserved: true,
          ),
        ]),
        availability: const {},
        leg: TripType.roundTrip,
        people: 1,
      );
      expect(fit.freeBerths, 0);
      expect(fit.fitsWholeParty, isFalse);
    });
  });

  group('legs', () {
    test('a bus sold out on GO can still seat a RETURN-only party', () {
      final avail = availabilityByKey(const [
        SeatAvailability(busId: busId, seatId: 'DU1', usedGo: 2, usedRet: 0),
      ]);

      expect(
        busFit(
          busId: busId,
          layout: layout([dbl('DU1', 0)]),
          availability: avail,
          leg: TripType.outboundOnly,
          people: 1,
        ).fitsWholeParty,
        isFalse,
      );
      expect(
        busFit(
          busId: busId,
          layout: layout([dbl('DU1', 0)]),
          availability: avail,
          leg: TripType.returnOnly,
          people: 2,
        ).fitsWholeParty,
        isTrue,
        reason: 'the return leg of those berths is untouched — this is the '
            'half-seat resale the whole leg model exists for',
      );
    });
  });

  group('choosing across buses', () {
    test('together-only keeps just the buses that seat everyone', () {
      final buses = [
        busFit(
          busId: 'a',
          layout: layout([dbl('DU1', 0), dbl('DU2', 1)]),
          availability: const {},
          leg: TripType.roundTrip,
          people: 4,
        ),
        busFit(
          busId: 'b',
          layout: layout([single('SU1', 0)]),
          availability: const {},
          leg: TripType.roundTrip,
          people: 4,
        ),
      ];

      expect(buses.where((b) => b.fitsWholeParty).map((b) => b.busId), ['a']);
    });

    test('split-allowed totals berths across every bus', () {
      final total = [
        busFit(
          busId: 'a',
          layout: layout([dbl('DU1', 0)]),
          availability: const {},
          leg: TripType.roundTrip,
          people: 4,
        ),
        busFit(
          busId: 'b',
          layout: layout([dbl('DU1', 0)]),
          availability: const {},
          leg: TripType.roundTrip,
          people: 4,
        ),
      ].fold<int>(0, (sum, b) => sum + b.freeBerths);

      expect(
        total,
        4,
        reason: 'neither bus alone seats 4, but together they do — which is '
            'exactly what the split option is for',
      );
    });
  });

  // The `shouldAskTogether` group was deleted along with the question it
  // guarded. The gate no longer asks "same bus or split?" — `autoPick` keeps a
  // party together when it can and splits only when no single bus will hold
  // them, and `ChartSummaryBar` says which buses when that happens. Asking the
  // customer to predict that was asking them to do the picker's job.
  //
  // `busFit` below is kept: the summary bar uses it to explain a shortfall.
}
