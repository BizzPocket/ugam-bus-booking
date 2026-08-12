import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/seat_layout.dart';
import 'package:occubusbooking/models/seat_type.dart';
import 'package:occubusbooking/models/trip_type.dart';
import 'package:occubusbooking/utils/chart_basket.dart';
import 'package:occubusbooking/utils/chart_selection.dart';

/// A basket entry is a PERSON's berth on a PERSON's leg.
///
/// The basket used to be `seatId -> berths`, which silently assumed every seat
/// in it shared one trip type. That assumption is what made "4 go, 2 come back"
/// impossible to express.
void main() {
  SeatCell cell(String id, {SeatType type = SeatType.singleSofa}) => SeatCell(
        row: 0,
        col: 0,
        seatType: type,
        position: SeatPosition.lower,
        seatId: id,
      );

  group('ChartBasket', () {
    test('it stores a leg beside the berth count', () {
      final b = ChartBasket();
      b.setBerths(
        busId: 'bus1',
        seatId: 'SU1',
        berths: 1,
        leg: TripType.outboundOnly,
      );

      expect(b.berthsFor(busId: 'bus1', seatId: 'SU1'), 1);
      expect(
        b.entryFor(busId: 'bus1', seatId: 'SU1')!.leg,
        TripType.outboundOnly,
      );
    });

    test('it defaults to round-trip so untouched call sites are unchanged', () {
      final b = ChartBasket();
      b.setBerths(busId: 'bus1', seatId: 'SU1', berths: 1);
      expect(b.entryFor(busId: 'bus1', seatId: 'SU1')!.leg, TripType.roundTrip);
    });

    test('berthsForLeg counts one bucket across every bus', () {
      final b = ChartBasket();
      b.setBerths(busId: 'bus1', seatId: 'SU1', berths: 2);
      b.setBerths(
        busId: 'bus2',
        seatId: 'SU1',
        berths: 1,
        leg: TripType.outboundOnly,
      );

      expect(b.berthsForLeg(TripType.roundTrip), 2);
      expect(b.berthsForLeg(TripType.outboundOnly), 1);
      expect(b.berthsForLeg(TripType.returnOnly), 0);
      expect(b.totalBerths, 3);
    });

    test('setting zero berths removes the entry and its leg', () {
      final b = ChartBasket();
      b.setBerths(busId: 'bus1', seatId: 'SU1', berths: 1);
      b.setBerths(busId: 'bus1', seatId: 'SU1', berths: 0);
      expect(b.entryFor(busId: 'bus1', seatId: 'SU1'), isNull);
      expect(b.isEmpty, isTrue);
    });
  });

  group('chart_selection', () {
    test('the claim payload carries each seat own leg', () {
      final picks = [
        ChartPick(cell: cell('SU1'), berths: 1),
        ChartPick(
          cell: cell('SU2'),
          berths: 1,
          leg: TripType.outboundOnly,
        ),
      ];

      expect(claimPayload(picks), [
        {'seatId': 'SU1', 'berths': 1, 'leg': 'roundTrip'},
        {'seatId': 'SU2', 'berths': 1, 'leg': 'outboundOnly'},
      ]);
    });

    test('request lines split by leg, not just by type', () {
      final picks = [
        ChartPick(cell: cell('SU1'), berths: 1),
        ChartPick(
          cell: cell('SU2'),
          berths: 1,
          leg: TripType.outboundOnly,
        ),
      ];

      final lines = requestLinesFor(picks: picks);
      expect(lines, hasLength(2));
      expect(
        lines.map((l) => l.leg).toSet(),
        {TripType.roundTrip, TripType.outboundOnly},
      );
      expect(lines.every((l) => l.qty == 1), isTrue);
    });

    test('same type and same leg still collapse into one line', () {
      final picks = [
        ChartPick(cell: cell('SU1'), berths: 1),
        ChartPick(cell: cell('SU2'), berths: 1),
      ];
      final lines = requestLinesFor(picks: picks);
      expect(lines, hasLength(1));
      expect(lines.single.qty, 2);
    });

    test('assignments are stamped per pick', () {
      final picks = [
        ChartPick(
          cell: cell('DU1', type: SeatType.doubleSofa),
          berths: 2,
          leg: TripType.returnOnly,
        ),
      ];
      final out = assignmentsFor(picks: picks, busId: 'bus1');
      expect(out, hasLength(2));
      expect(out.every((a) => a.leg == TripType.returnOnly), isTrue);
    });

    test('a mixed basket derives round-trip as its coarse leg', () {
      final picks = [
        ChartPick(cell: cell('SU1'), berths: 1, leg: TripType.outboundOnly),
        ChartPick(cell: cell('SU2'), berths: 1, leg: TripType.roundTrip),
      ];
      expect(summaryLegOf(picks), TripType.roundTrip);
      expect(
        claimPayload(picks).map((m) => m['leg']),
        ['outboundOnly', 'roundTrip'],
        reason: 'the coarse summary must never overwrite the per-seat truth',
      );
    });

    test('the summary leg is round-trip whenever the legs are mixed', () {
      expect(
        summaryLegOf([
          ChartPick(cell: cell('SU1'), berths: 1, leg: TripType.outboundOnly),
          ChartPick(cell: cell('SU2'), berths: 1, leg: TripType.returnOnly),
        ]),
        TripType.roundTrip,
      );
      expect(
        summaryLegOf([
          ChartPick(cell: cell('SU1'), berths: 1, leg: TripType.outboundOnly),
        ]),
        TripType.outboundOnly,
      );
    });
  });
}
