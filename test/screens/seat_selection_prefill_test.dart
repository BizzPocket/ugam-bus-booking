import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/components/chart_seat_tile.dart';
import 'package:occubusbooking/models/booking_mode.dart';
import 'package:occubusbooking/models/bus_details.dart';
import 'package:occubusbooking/models/tour.dart';
import 'package:occubusbooking/models/tour_status.dart';
import 'package:occubusbooking/models/trip_type.dart';
import 'package:occubusbooking/screens/seat_selection_screen.dart';
import 'package:occubusbooking/utils/chart_seat_availability.dart';
import 'package:occubusbooking/utils/party_fit.dart';
import 'package:occubusbooking/widgets/chart_summary_bar.dart';

/// The chart must OPEN already answered.
///
/// Facing 36 unlabelled cells and being asked to solve them is what actually
/// defeated non-technical customers — not the styling. So the picker runs on
/// load, the seats arrive selected, and the map becomes a proposal to adjust
/// rather than a test to pass.
void main() {
  const busId = 'ab8a5ef3-26ff-4ccb-8c99-f144cdd5f744';

  Map<String, dynamic> cell(
    int row,
    int col,
    String seatId,
    String type,
    String pos,
  ) =>
      {
        'row': row,
        'col': col,
        'seatId': seatId,
        'seatType': type,
        'position': pos,
      };

  Bus bus(String id, List<Map<String, dynamic>> grid) =>
      Bus.fromMap(Map<String, dynamic>.from(jsonDecode(jsonEncode({
        'id': id,
        'name': 'Bus $id',
        'is_ac': true,
        'tour_id': 'tour-1',
        'bus_type': 'Sleeper',
        'rear_rows': 0,
        'price_bands': <dynamic>[],
        'boarding_point': 'Udhna',
        'departure_time': '21:30',
        'price_per_seat': 900.0,
        'registration_no': 'GJ05T',
        'double_sofa_price': 2200.0,
        'single_sofa_price': 1400.0,
        'layout': {
          'rows': grid.length,
          'cols': 5,
          'hasBalcony': false,
          'grid': grid,
        },
      })) as Map));

  /// Three rows of single berths: an upper and a lower on each.
  List<Map<String, dynamic>> threeRows() => [
        for (var r = 0; r < 3; r++) ...[
          cell(r, 0, 'SU${r + 1}', 'singleSofa', 'upper'),
          cell(r, 1, 'SL${r + 1}', 'singleSofa', 'lower'),
        ],
      ];

  Tour chartTour() => Tour(
        id: 'tour-1',
        title: 'TEST',
        fromCity: 'Surat',
        toCity: 'Shirdi',
        departureDate: DateTime(2026, 9, 15),
        // A tour with a return leg: a party that is partly one-way is only a
        // meaningful scenario on one, and the return tab has nothing to show
        // without it.
        returnDate: DateTime(2026, 9, 18),
        pricePerSeat: 900,
        status: TourStatus.busBooked,
        bookingMode: BookingMode.chart,
      );

  Widget harness(
    List<Bus> buses, {
    required PartyIntent intent,
    Map<String, SeatAvailability> availability = const {},
  }) =>
      MaterialApp(
        home: SeatSelectionScreen(
          tour: chartTour(),
          intent: intent,
          loadBuses: (_) async => buses,
          loadAvailability: (_) async => availability,
        ),
      );

  int selectedBerths(WidgetTester tester) => tester
      .widgetList<ChartSeatTile>(find.byType(ChartSeatTile))
      .fold<int>(0, (sum, t) => sum + t.selectedBerths);

  /// Seat ids currently held, whichever tab is on screen.
  Set<String> selectedSeatIds(WidgetTester tester) => {
        for (final t in tester.widgetList<ChartSeatTile>(
          find.byType(ChartSeatTile),
        ))
          if (t.selectedBerths > 0) t.cell.seatId!,
      };

  group('the leg tabs are a view filter, not a change of purchase', () {
    testWidgets('a single-leg party sees no tab strip', (tester) async {
      await tester.pumpWidget(harness(
        [bus(busId, threeRows())],
        intent: const PartyIntent(roundTrip: 2),
      ));
      await tester.pumpAndSettle();

      expect(find.byKey(SeatSelectionScreen.returnTabKey), findsNothing);
      expect(find.byKey(SeatSelectionScreen.goTabKey), findsNothing);
    });

    testWidgets('a return-only party sees only the return map', (tester) async {
      await tester.pumpWidget(harness(
        [bus(busId, threeRows())],
        intent: const PartyIntent(returnOnly: 2),
      ));
      await tester.pumpAndSettle();

      expect(
        find.byKey(SeatSelectionScreen.goTabKey),
        findsNothing,
        reason: 'nothing is being filled on the outbound leg',
      );
    });

    testWidgets('a mixed party gets both tabs', (tester) async {
      await tester.pumpWidget(harness(
        [bus(busId, threeRows())],
        intent: const PartyIntent(roundTrip: 1, returnOnly: 1),
      ));
      await tester.pumpAndSettle();

      expect(find.byKey(SeatSelectionScreen.goTabKey), findsOneWidget);
      expect(find.byKey(SeatSelectionScreen.returnTabKey), findsOneWidget);
    });

    testWidgets('switching tabs keeps the selection', (tester) async {
      await tester.pumpWidget(harness(
        [bus(busId, threeRows())],
        intent: const PartyIntent(roundTrip: 1, returnOnly: 1),
      ));
      await tester.pumpAndSettle();

      final goSeats = selectedSeatIds(tester);
      expect(goSeats, isNotEmpty);

      await tester.tap(find.byKey(SeatSelectionScreen.returnTabKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(SeatSelectionScreen.goTabKey));
      await tester.pumpAndSettle();

      expect(
        selectedSeatIds(tester),
        goSeats,
        reason: 'the tab is a view filter now, not a change of what is bought',
      );
    });

    testWidgets('a round-trip berth shows on BOTH tabs, a one-way berth on one',
        (tester) async {
      await tester.pumpWidget(harness(
        [bus(busId, threeRows())],
        intent: const PartyIntent(roundTrip: 1, returnOnly: 1),
      ));
      await tester.pumpAndSettle();

      final onGo = selectedSeatIds(tester);
      await tester.tap(find.byKey(SeatSelectionScreen.returnTabKey));
      await tester.pumpAndSettle();
      final onReturn = selectedSeatIds(tester);

      // The round-trip berth is one berth on both legs, so it appears on both
      // maps. The return-only berth belongs to the return map alone.
      expect(
        onGo.intersection(onReturn),
        hasLength(1),
        reason: 'the round-trip berth is the same physical seat on both legs',
      );
      expect(onReturn.difference(onGo), hasLength(1));
    });

    testWidgets(
        'untapping a round-trip berth on the return tab clears it '
        'from the go tab too', (tester) async {
      await tester.pumpWidget(harness(
        [bus(busId, threeRows())],
        intent: const PartyIntent(roundTrip: 1, returnOnly: 1),
      ));
      await tester.pumpAndSettle();

      final shared = selectedSeatIds(tester);
      await tester.tap(find.byKey(SeatSelectionScreen.returnTabKey));
      await tester.pumpAndSettle();

      await tester.tap(find.byWidgetPredicate(
        (w) => w is ChartSeatTile && w.cell.seatId == shared.first,
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(SeatSelectionScreen.goTabKey));
      await tester.pumpAndSettle();

      expect(
        selectedSeatIds(tester).contains(shared.first),
        isFalse,
        reason: 'it is ONE berth on ONE booking — it cannot survive on one map '
            'after being given back on the other',
      );
    });
  });

  testWidgets('a party of three arrives with three berths already picked',
      (tester) async {
    await tester.pumpWidget(harness(
      [bus(busId, threeRows())],
      intent: const PartyIntent(roundTrip:3),
    ));
    await tester.pumpAndSettle();

    expect(
      selectedBerths(tester),
      3,
      reason: 'the whole point: the customer should not have to solve the map',
    );
  });

  testWidgets('a solo traveller still gets a seat chosen for them',
      (tester) async {
    await tester.pumpWidget(harness(
      [bus(busId, threeRows())],
      intent: const PartyIntent(roundTrip:1),
    ));
    await tester.pumpAndSettle();

    expect(selectedBerths(tester), 1);
  });

  testWidgets('the summary bar states what was picked', (tester) async {
    await tester.pumpWidget(harness(
      [bus(busId, threeRows())],
      intent: const PartyIntent(roundTrip:3),
    ));
    await tester.pumpAndSettle();

    expect(find.byType(ChartSummaryBar), findsOneWidget);
    final bar = tester.widget<ChartSummaryBar>(find.byType(ChartSummaryBar));
    expect(bar.people, 3);
    expect(bar.pickedBerths, 3);
    expect(bar.shortfall, isEmpty);
  });

  testWidgets(
      'when the bus cannot hold the whole party, it seats who it can and '
      'names the gap', (tester) async {
    await tester.pumpWidget(harness(
      // Two berths only.
      [
        bus(busId, [
          cell(0, 0, 'SU1', 'singleSofa', 'upper'),
          cell(0, 1, 'SL1', 'singleSofa', 'lower'),
        ]),
      ],
      intent: const PartyIntent(roundTrip: 5),
    ));
    await tester.pumpAndSettle();

    expect(
      selectedBerths(tester),
      2,
      reason: 'the two real berths are worth keeping — discarding them would '
          'hand the customer a blank map to solve by hand',
    );

    final bar = tester.widget<ChartSummaryBar>(find.byType(ChartSummaryBar));
    expect(
      bar.shortfall,
      {TripType.roundTrip: 3},
      reason: 'a partial pick that says nothing would quietly under-book the '
          'family; the bar must name the leg and the count',
    );
  });

  testWidgets('the pre-fill counts lower berths, for the summary line',
      (tester) async {
    await tester.pumpWidget(harness(
      [bus(busId, threeRows())],
      intent: const PartyIntent(roundTrip:2),
    ));
    await tester.pumpAndSettle();

    final bar = tester.widget<ChartSummaryBar>(find.byType(ChartSummaryBar));
    expect(
      bar.lowerBerths,
      greaterThanOrEqualTo(1),
      reason: 'the picker prefers lower berths, and the summary has to be able '
          'to say so — that is what replaces asking about elders',
    );
  });

  testWidgets('a party that refuses to share is never pre-filled onto a half',
      (tester) async {
    // One double with a stranger already on one berth. Sharing is refused.
    await tester.pumpWidget(harness(
      [
        bus(busId, [cell(0, 4, 'DL1', 'doubleSofa', 'lower')]),
      ],
      intent: const PartyIntent(roundTrip:1, shareOk: false),
      availability: availabilityByKey(const [
        SeatAvailability(busId: busId, seatId: 'DL1', usedGo: 1, usedRet: 1),
      ]),
    ));
    await tester.pumpAndSettle();

    expect(
      selectedBerths(tester),
      0,
      reason: 'they said no at the gate — auto-picking a shared berth anyway '
          'would make the answer meaningless',
    );
  });
}
