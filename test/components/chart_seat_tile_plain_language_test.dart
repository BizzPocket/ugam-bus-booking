import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/components/chart_seat_tile.dart';
import 'package:occubusbooking/models/seat_layout.dart';
import 'package:occubusbooking/models/seat_type.dart';
import 'package:occubusbooking/models/trip_type.dart';
import 'package:occubusbooking/utils/chart_seat_availability.dart';

/// A tile has to SAY what it is.
///
/// `SU1` is Single Upper 1 and `DL1` is Double Lower 1 — engineer output, with
/// nothing on screen to decode it. Worse, the letter hides the single most
/// consequential fact in Indian sleeper travel: upper vs lower berth. An
/// elderly passenger who must have a lower berth had no way to see which seats
/// those were.
///
/// So the tile now leads with the FACT (upper / lower / seats two) and the
/// PRICE, and demotes the code to a corner reference — it still has to match
/// the printed ticket and the organiser's chart, so it cannot simply go away.
void main() {
  SeatCell cell({
    required String id,
    required SeatType type,
    SeatPosition? pos,
    int col = 0,
  }) =>
      SeatCell(row: 0, col: col, seatType: type, position: pos, seatId: id);

  Widget harness(Widget child) => MaterialApp(
        home: Scaffold(body: Center(child: UnconstrainedBox(child: child))),
      );

  group('the berth word', () {
    test('a lower berth is named lower', () {
      expect(
        berthWordKey(cell(
          id: 'SL1',
          type: SeatType.singleSofa,
          pos: SeatPosition.lower,
        )),
        'seat_ui.berth_lower',
      );
    });

    test('an upper berth is named upper', () {
      expect(
        berthWordKey(cell(
          id: 'SU1',
          type: SeatType.singleSofa,
          pos: SeatPosition.upper,
        )),
        'seat_ui.berth_upper',
      );
    });

    test('a double sofa says it seats two, not which deck', () {
      expect(
        berthWordKey(cell(
          id: 'DL1',
          type: SeatType.doubleSofa,
          pos: SeatPosition.lower,
          col: 4,
        )),
        'seat_ui.berth_sofa_two',
        reason: 'how many people it holds is what a customer is choosing on; '
            'the deck is secondary and the glyph already shows it',
      );
    });

    test('a seater is just a seat — it has no deck', () {
      expect(
        berthWordKey(cell(id: 'ST1', type: SeatType.seater)),
        'seat_ui.berth_seater',
      );
    });
  });

  group('the tile face', () {
    testWidgets('a free seat shows its price', (tester) async {
      await tester.pumpWidget(harness(
        ChartSeatTile(
          cell: cell(
            id: 'SL1',
            type: SeatType.singleSofa,
            pos: SeatPosition.lower,
          ),
          occupancy: null,
          leg: TripType.roundTrip,
          berthPrice: 1400,
        ),
      ));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('1,400'),
        findsOneWidget,
        reason: 'band pricing was invisible until the footer total moved',
      );
    });

    testWidgets('a double quotes the WHOLE sofa', (tester) async {
      await tester.pumpWidget(harness(
        ChartSeatTile(
          cell: cell(
            id: 'DL1',
            type: SeatType.doubleSofa,
            pos: SeatPosition.lower,
            col: 4,
          ),
          occupancy: null,
          leg: TripType.roundTrip,
          berthPrice: 1100,
        ),
      ));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('2,200'),
        findsOneWidget,
        reason: 'the headline for a two-person sofa is what the sofa costs; '
            'the half price belongs in the share sheet',
      );
    });

    testWidgets('the seat code survives, because tickets carry it',
        (tester) async {
      await tester.pumpWidget(harness(
        ChartSeatTile(
          cell: cell(
            id: 'SL1',
            type: SeatType.singleSofa,
            pos: SeatPosition.lower,
          ),
          occupancy: null,
          leg: TripType.roundTrip,
          berthPrice: 1400,
        ),
      ));
      await tester.pumpAndSettle();

      expect(
        find.text('SL1'),
        findsOneWidget,
        reason: 'the handler calls this code out at boarding — demoting it is '
            'safe, deleting it is not',
      );
    });

    testWidgets('a taken seat does not advertise a price', (tester) async {
      await tester.pumpWidget(harness(
        ChartSeatTile(
          cell: cell(
            id: 'SL1',
            type: SeatType.singleSofa,
            pos: SeatPosition.lower,
          ),
          occupancy: const SeatAvailability(
            busId: 'a',
            seatId: 'SL1',
            usedGo: 1,
            usedRet: 1,
          ),
          leg: TripType.roundTrip,
          berthPrice: 1400,
        ),
      ));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('1,400'),
        findsNothing,
        reason: 'quoting a price on a seat nobody can buy is noise',
      );
    });
  });

  group('geometry', () {
    testWidgets('tiles are big enough to carry a word and a price',
        (tester) async {
      await tester.pumpWidget(harness(
        ChartSeatTile(
          cell: cell(
            id: 'SL1',
            type: SeatType.singleSofa,
            pos: SeatPosition.lower,
          ),
          occupancy: null,
          leg: TripType.roundTrip,
          berthPrice: 1400,
        ),
      ));
      await tester.pumpAndSettle();

      final size = tester.getSize(find.byType(ChartSeatTile));
      expect(size.width, ChartSeatMetrics.width);
      expect(size.height, ChartSeatMetrics.height);
      expect(
        ChartSeatMetrics.width,
        greaterThanOrEqualTo(56),
        reason: 'the old 40x42 could not fit a word and a price. This grows '
            'ONLY the customer tile — no shared density token, and no '
            'operator or handler chart, changes.',
      );
      expect(ChartSeatMetrics.height, greaterThanOrEqualTo(52));
    });
  });
}
