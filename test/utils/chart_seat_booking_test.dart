import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/passenger.dart';
import 'package:occubusbooking/models/seat_layout.dart';
import 'package:occubusbooking/models/seat_type.dart';
import 'package:occubusbooking/models/trip_type.dart';
import 'package:occubusbooking/utils/chart_seat_availability.dart';
import 'package:occubusbooking/utils/chart_selection.dart';

/// The customer seat chart's two pure halves: what is still bookable
/// (`chart_seat_availability`) and what a tapped selection becomes
/// (`chart_selection`).
///
/// These mirror migration 048's SQL. The scenarios below are the SAME ones the
/// migration was dry-run against on a local Postgres, so a divergence between
/// client and server shows up here rather than as a customer losing a seat.
void main() {
  const busId = 'bus-1';

  SeatCell single({bool reserved = false}) => SeatCell(
        row: 0,
        col: 0,
        seatType: SeatType.singleSofa,
        position: SeatPosition.upper,
        seatId: 'SU1',
        reserved: reserved,
      );

  SeatCell doubleSofa() => const SeatCell(
        row: 0,
        col: 4,
        seatType: SeatType.doubleSofa,
        position: SeatPosition.lower,
        seatId: 'DL1',
      );

  SeatCell seater() => const SeatCell(
        row: 1,
        col: 0,
        seatType: SeatType.seater,
        seatId: 'ST1',
      );

  SeatAvailability occ({
    int go = 0,
    int ret = 0,
    bool ladyGo = false,
    bool ladyRet = false,
    String seatId = 'SU1',
  }) =>
      SeatAvailability(
        busId: busId,
        seatId: seatId,
        usedGo: go,
        usedRet: ret,
        ladyGo: ladyGo,
        ladyRet: ladyRet,
      );

  group('freeBerths — capacity', () {
    test('an untouched single sofa offers one berth on every leg', () {
      for (final leg in TripType.values) {
        expect(
          freeBerths(cell: single(), occupancy: null, leg: leg),
          1,
          reason: 'leg $leg',
        );
      }
    });

    test('an untouched double sofa offers two berths', () {
      expect(
        freeBerths(
          cell: doubleSofa(),
          occupancy: null,
          leg: TripType.roundTrip,
        ),
        2,
      );
    });

    test('a reserved seat is never claimable', () {
      expect(
        freeBerths(
          cell: single(reserved: true),
          occupancy: null,
          leg: TripType.roundTrip,
        ),
        0,
      );
      expect(
        chartSeatState(
          cell: single(reserved: true),
          occupancy: null,
          leg: TripType.roundTrip,
        ),
        ChartSeatState.blocked,
      );
    });
  });

  group('freeBerths — leg reuse (one berth sells twice)', () {
    test('a double sold whole on GO leaves the RET leg completely free', () {
      final a = occ(go: 2, ret: 0, seatId: 'DL1');
      expect(
        freeBerths(
          cell: doubleSofa(),
          occupancy: a,
          leg: TripType.outboundOnly,
        ),
        0,
        reason: 'GO is full',
      );
      expect(
        freeBerths(
          cell: doubleSofa(),
          occupancy: a,
          leg: TripType.returnOnly,
        ),
        2,
        reason: 'RET is untouched — this is the half-seat resale',
      );
    });

    test('a round-trip rider is limited by the BUSIER leg', () {
      // One berth gone on GO, none on RET. A round-tripper needs both legs, so
      // only one of the two berths is usable to them.
      final a = occ(go: 1, ret: 0, seatId: 'DL1');
      expect(
        freeBerths(
          cell: doubleSofa(),
          occupancy: a,
          leg: TripType.roundTrip,
        ),
        1,
      );
      expect(
        freeBerths(
          cell: doubleSofa(),
          occupancy: a,
          leg: TripType.returnOnly,
        ),
        2,
      );
    });

    test('a fully sold single reads taken on the leg that sold it only', () {
      final a = occ(go: 1);
      expect(
        chartSeatState(
          cell: single(),
          occupancy: a,
          leg: TripType.outboundOnly,
        ),
        ChartSeatState.taken,
      );
      expect(
        chartSeatState(
          cell: single(),
          occupancy: a,
          leg: TripType.returnOnly,
        ),
        ChartSeatState.free,
      );
      expect(
        chartSeatState(
          cell: single(),
          occupancy: a,
          leg: TripType.roundTrip,
        ),
        ChartSeatState.taken,
      );
    });
  });

  group('chartSeatState', () {
    test('half a double reads partlyTaken, not taken', () {
      expect(
        chartSeatState(
          cell: doubleSofa(),
          occupancy: occ(go: 1, ret: 1, seatId: 'DL1'),
          leg: TripType.roundTrip,
        ),
        ChartSeatState.partlyTaken,
      );
    });

    test('a seat in the current selection reads selected', () {
      expect(
        chartSeatState(
          cell: single(),
          occupancy: null,
          leg: TripType.roundTrip,
          selectedBerths: 1,
        ),
        ChartSeatState.selected,
      );
    });
  });

  group('ladies marker', () {
    test('surfaces only on a leg the booking would share', () {
      final a = occ(go: 1, ladyGo: true, seatId: 'DL1');
      expect(hasLadyOn(occupancy: a, leg: TripType.outboundOnly), isTrue);
      expect(hasLadyOn(occupancy: a, leg: TripType.returnOnly), isFalse);
      expect(hasLadyOn(occupancy: a, leg: TripType.roundTrip), isTrue);
    });

    test('absent occupancy is never a lady', () {
      expect(hasLadyOn(occupancy: null, leg: TripType.roundTrip), isFalse);
    });
  });

  group('selection → request lines', () {
    test('a WHOLE double books as one doubleSofa line', () {
      final lines = requestLinesFor(
        picks: [ChartPick(cell: doubleSofa(), berths: 2)],
      );
      expect(lines, hasLength(1));
      expect(lines.single.seatType, SeatType.doubleSofa);
      expect(lines.single.qty, 1);
      expect(lines.single.position, SeatPosition.lower);
    });

    test('HALF a double books as a singleSofa line', () {
      // Matches migration 048: a doubleSofa cell taken at 1 berth becomes a
      // single line, because RequestLine.qty counts whole units and a
      // doubleSofa unit is always two berths.
      final lines = requestLinesFor(
        picks: [ChartPick(cell: doubleSofa(), berths: 1)],
      );
      expect(lines.single.seatType, SeatType.singleSofa);
      expect(lines.single.qty, 1);
    });

    test('a seater carries no position', () {
      final lines = requestLinesFor(
        picks: [ChartPick(cell: seater(), berths: 1)],
      );
      expect(lines.single.seatType, SeatType.seater);
      expect(lines.single.position, isNull);
    });

    test('same type+position collapses into one line with qty', () {
      final lines = requestLinesFor(
        picks: [
          ChartPick(cell: single(), berths: 1),
          ChartPick(cell: single(), berths: 1),
        ],
      );
      expect(lines, hasLength(1));
      expect(lines.single.qty, 2);
    });

    test('each pick own leg is stamped on its line', () {
      final lines = requestLinesFor(
        picks: [
          ChartPick(cell: single(), berths: 1, leg: TripType.returnOnly),
          ChartPick(cell: seater(), berths: 1, leg: TripType.returnOnly),
        ],
      );
      expect(lines.every((l) => l.leg == TripType.returnOnly), isTrue);
    });
  });

  group('assignments', () {
    test('a whole double yields TWO entries on ONE seatId', () {
      final a = assignmentsFor(
        picks: [ChartPick(cell: doubleSofa(), berths: 2)],
        busId: busId,
      );
      expect(a, hasLength(2));
      expect(a.every((s) => s.seatId == 'DL1'), isTrue);
      expect(a.every((s) => s.leg == TripType.roundTrip), isTrue);
    });

    test('half a double yields exactly one entry', () {
      expect(
        assignmentsFor(
          picks: [ChartPick(cell: doubleSofa(), berths: 1)],
          busId: busId,
        ),
        hasLength(1),
      );
    });
  });

  group('CROSS-SYSTEM INVARIANT — a chart passenger is shaped like any other',
      () {
    /// Stamps [leg] onto every pick, then builds. The leg now lives ON the pick
    /// rather than travelling beside it, so the helper restamps instead of
    /// threading a separate argument into the two derivations.
    Passenger build(List<ChartPick> picks, TripType leg) {
      final onLeg = [
        for (final p in picks)
          ChartPick(cell: p.cell, berths: p.berths, leg: leg),
      ];
      return Passenger(
        tourId: 't1',
        name: 'Chart rider',
        phone: '9900000000',
        requestLines: requestLinesFor(picks: onLeg),
        assignedSeats: assignmentsFor(picks: onLeg, busId: busId),
        tripType: leg,
        isConfirmed: true,
      );
    }

    test('seatBerths always equals the number of assignment entries', () {
      final cases = <List<ChartPick>>[
        [ChartPick(cell: single(), berths: 1)],
        [ChartPick(cell: doubleSofa(), berths: 2)],
        [ChartPick(cell: doubleSofa(), berths: 1)],
        [ChartPick(cell: seater(), berths: 1)],
        [
          ChartPick(cell: doubleSofa(), berths: 2),
          ChartPick(cell: single(), berths: 1),
          ChartPick(cell: seater(), berths: 1),
        ],
      ];
      for (final picks in cases) {
        for (final leg in TripType.values) {
          final p = build(picks, leg);
          expect(
            p.seatBerths,
            p.totalSeatsAssigned,
            reason: 'picks=${picks.length} leg=$leg — this equality is what '
                'every capacity and money getter depends on',
          );
          expect(p.seatBerths, totalBerths(picks));
          expect(p.isFullyAssigned, isTrue);
          expect(p.remainingBerths, 0);
        }
      }
    });

    test('a round-trip selection loads both legs fully', () {
      final p = build([
        ChartPick(cell: doubleSofa(), berths: 2),
        ChartPick(cell: single(), berths: 1),
      ], TripType.roundTrip);
      expect(p.goBerths, 3);
      expect(p.retBerths, 3);
      expect(p.seatLoad, 3.0);
    });

    test('a one-way selection loads only its own leg, at half weight', () {
      final p = build(
        [ChartPick(cell: doubleSofa(), berths: 2)],
        TripType.outboundOnly,
      );
      expect(p.goBerths, 2);
      expect(p.retBerths, 0, reason: 'the return leg of that berth stays sellable');
      expect(p.seatLoad, 1.0, reason: 'one-way weighs half a whole seat');
    });

    test('every held seat resolves back to the leg it was booked on', () {
      final p = build(
        [ChartPick(cell: doubleSofa(), berths: 2)],
        TripType.returnOnly,
      );
      expect(p.legForSeat('DL1', busId: busId), TripType.returnOnly);
      expect(p.derivedTripType, TripType.returnOnly);
    });
  });
}
