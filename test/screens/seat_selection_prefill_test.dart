import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/components/chart_seat_tile.dart';
import 'package:occubusbooking/models/booking_mode.dart';
import 'package:occubusbooking/models/bus_details.dart';
import 'package:occubusbooking/models/tour.dart';
import 'package:occubusbooking/models/tour_status.dart';
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

  testWidgets('a party of three arrives with three berths already picked',
      (tester) async {
    await tester.pumpWidget(harness(
      [bus(busId, threeRows())],
      intent: const PartyIntent(people: 3),
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
      intent: const PartyIntent(people: 1),
    ));
    await tester.pumpAndSettle();

    expect(selectedBerths(tester), 1);
  });

  testWidgets('the summary bar states what was picked', (tester) async {
    await tester.pumpWidget(harness(
      [bus(busId, threeRows())],
      intent: const PartyIntent(people: 3),
    ));
    await tester.pumpAndSettle();

    expect(find.byType(ChartSummaryBar), findsOneWidget);
    final bar = tester.widget<ChartSummaryBar>(find.byType(ChartSummaryBar));
    expect(bar.people, 3);
    expect(bar.pickedBerths, 3);
    expect(bar.noRoom, isFalse);
  });

  testWidgets('when the bus cannot hold the party, it says so and picks nothing',
      (tester) async {
    await tester.pumpWidget(harness(
      // Two berths only.
      [
        bus(busId, [
          cell(0, 0, 'SU1', 'singleSofa', 'upper'),
          cell(0, 1, 'SL1', 'singleSofa', 'lower'),
        ]),
      ],
      intent: const PartyIntent(people: 5),
    ));
    await tester.pumpAndSettle();

    expect(selectedBerths(tester), 0);
    final bar = tester.widget<ChartSummaryBar>(find.byType(ChartSummaryBar));
    expect(
      bar.noRoom,
      isTrue,
      reason: 'a silent blank chart tells the customer nothing; a partial pick '
          'would quietly under-book the family',
    );
  });

  testWidgets('the pre-fill counts lower berths, for the summary line',
      (tester) async {
    await tester.pumpWidget(harness(
      [bus(busId, threeRows())],
      intent: const PartyIntent(people: 2),
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
      intent: const PartyIntent(people: 1, shareOk: false),
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
