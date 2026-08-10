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
import 'package:occubusbooking/widgets/sofa_share_sheet.dart';

/// The SHARED-SOFA journey, driven through the real screen.
///
/// `chart_seat_booking_test.dart` already covers the pure `freeBerths` /
/// `chartSeatState` arithmetic thoroughly. What had NO coverage at all was the
/// interaction that actually sells half a sofa: `_tapSeat`'s 1 -> 2 -> off
/// cycle, and the berth cap that guards it. Those are the paths a customer
/// touches, and they lived only inside a private method on the screen.
///
/// Half-double selling is the app's signature behaviour — a solo traveller may
/// take ONE berth of a double and share it with a stranger — so the cycle
/// stopping at the right place matters commercially, not just cosmetically.
String _busJson({
  required String id,
  required String name,
  required List<Map<String, dynamic>> grid,
}) =>
    jsonEncode({
      'id': id,
      'name': name,
      'is_ac': true,
      'tour_id': '341baff4-9c9b-47b7-868f-ad123cffb8d1',
      'bus_type': 'Sleeper',
      'rear_rows': 0,
      'rear_price': null,
      'price_bands': <dynamic>[],
      'seater_price': null,
      'boarding_point': 'Udhna',
      'departure_time': '21:30',
      'price_per_seat': 900.0,
      'registration_no': 'GJ05TEST1',
      'double_sofa_price': 1600.0,
      'single_sofa_price': 900.0,
      'layout': {
        'rows': (grid.map((c) => c['row'] as int).reduce((a, b) => a > b ? a : b)) + 1,
        'cols': 5,
        'hasBalcony': false,
        'grid': grid,
      },
    });

Map<String, dynamic> _cell({
  required int row,
  required int col,
  required String seatId,
  required String seatType,
  String? position,
}) =>
    {
      'row': row,
      'col': col,
      'seatId': seatId,
      'seatType': seatType,
      'position': ?position,
    };

void main() {
  const busId = 'ab8a5ef3-26ff-4ccb-8c99-f144cdd5f744';

  /// One row: a single pair on the left, a double pair on the right.
  /// 1 + 1 + 2 + 2 = 6 berths, which is exactly the booking cap.
  List<Map<String, dynamic>> oneRow() => [
        _cell(row: 0, col: 0, seatId: 'SU1', seatType: 'singleSofa', position: 'upper'),
        _cell(row: 0, col: 1, seatId: 'SL1', seatType: 'singleSofa', position: 'lower'),
        _cell(row: 0, col: 3, seatId: 'DU1', seatType: 'doubleSofa', position: 'upper'),
        _cell(row: 0, col: 4, seatId: 'DL1', seatType: 'doubleSofa', position: 'lower'),
      ];

  /// Four whole doubles = 8 berths, which OVERSHOOTS the 6-berth cap. This is
  /// the fixture that proves the cap counts berths and not cells.
  List<Map<String, dynamic>> fourDoubles() => [
        for (var r = 0; r < 2; r++) ...[
          _cell(row: r, col: 3, seatId: 'DU${r + 1}', seatType: 'doubleSofa', position: 'upper'),
          _cell(row: r, col: 4, seatId: 'DL${r + 1}', seatType: 'doubleSofa', position: 'lower'),
        ],
      ];

  Bus bus(List<Map<String, dynamic>> grid, {String name = 'Test Bus 1'}) =>
      Bus.fromMap(
        Map<String, dynamic>.from(
          jsonDecode(_busJson(id: busId, name: name, grid: grid)) as Map,
        ),
      );

  Tour chartTour() => Tour(
        id: '341baff4-9c9b-47b7-868f-ad123cffb8d1',
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
    Map<String, SeatAvailability> availability = const {},
    PartyIntent intent = PartyIntent.solo,
  }) =>
      MaterialApp(
        home: SeatSelectionScreen(
          tour: chartTour(),
          intent: intent,
          loadBuses: (_) async => buses,
          loadAvailability: (_) async => availability,
        ),
      );

  Finder seat(String seatId) => find.byWidgetPredicate(
        (w) => w is ChartSeatTile && w.cell.seatId == seatId,
      );

  int selectedBerths(WidgetTester tester, String seatId) =>
      tester.widget<ChartSeatTile>(seat(seatId)).selectedBerths;

  Future<void> tapSeat(WidgetTester tester, String seatId) async {
    await tester.tap(seat(seatId));
    await tester.pumpAndSettle();
  }

  /// Taps a two-person sofa and answers the share sheet it opens.
  Future<void> takeSofa(
    WidgetTester tester,
    String seatId, {
    required bool whole,
  }) async {
    await tapSeat(tester, seatId);
    await tester.tap(
      find.byKey(whole ? SofaShareSheet.wholeKey : SofaShareSheet.halfKey),
    );
    await tester.pumpAndSettle();
  }

  /// Clears whatever the picker pre-filled, so a test starts from a blank
  /// selection and measures only its own taps.
  Future<void> clearPrefill(WidgetTester tester) async {
    for (final tile in tester.widgetList<ChartSeatTile>(
      find.byType(ChartSeatTile),
    )) {
      if (tile.selectedBerths > 0) {
        await tapSeat(tester, tile.cell.seatId!);
      }
    }
  }

  testWidgets('taking a sofa is ASKED, not guessed from a tap count',
      (tester) async {
    await tester.pumpWidget(harness([bus(oneRow())]));
    await tester.pumpAndSettle();
    await clearPrefill(tester);

    // One tap opens the question instead of silently taking half the sofa and
    // committing the customer to sleeping beside a stranger.
    await tapSeat(tester, 'DU1');
    expect(
      find.byKey(SofaShareSheet.wholeKey),
      findsOneWidget,
      reason: 'the old flow took half on the first tap and said nothing — the '
          'stranger was communicated only by a tile splitting in half',
    );
    expect(find.byKey(SofaShareSheet.halfKey), findsOneWidget);

    await tester.tap(find.byKey(SofaShareSheet.halfKey));
    await tester.pumpAndSettle();
    expect(selectedBerths(tester, 'DU1'), 1);
  });

  testWidgets('choosing the whole sofa takes both berths', (tester) async {
    await tester.pumpWidget(harness([bus(oneRow())]));
    await tester.pumpAndSettle();
    await clearPrefill(tester);

    await takeSofa(tester, 'DU1', whole: true);
    expect(selectedBerths(tester, 'DU1'), 2);
  });

  testWidgets('tapping a sofa we already hold gives it straight back',
      (tester) async {
    await tester.pumpWidget(harness([bus(oneRow())]));
    await tester.pumpAndSettle();
    await clearPrefill(tester);

    await takeSofa(tester, 'DU1', whole: true);
    await tapSeat(tester, 'DU1');
    expect(
      selectedBerths(tester, 'DU1'),
      0,
      reason: 'undo is one tap for every seat type — the one gesture that '
          'never needs explaining',
    );
  });

  testWidgets('a party that refuses to share is never offered half a sofa',
      (tester) async {
    await tester.pumpWidget(harness(
      [bus(oneRow())],
      intent: const PartyIntent(roundTrip:1, shareOk: false),
    ));
    await tester.pumpAndSettle();
    await clearPrefill(tester);

    await tapSeat(tester, 'DU1');
    // Only one honest option remains, so no sheet is shown at all — the whole
    // sofa is simply taken.
    expect(find.byKey(SofaShareSheet.halfKey), findsNothing);
    expect(selectedBerths(tester, 'DU1'), 2);
  });

  testWidgets('a single sofa is a plain on/off, never a half', (tester) async {
    await tester.pumpWidget(harness([bus(oneRow())]));
    await tester.pumpAndSettle();

    await tapSeat(tester, 'SU1');
    expect(selectedBerths(tester, 'SU1'), 1);

    await tapSeat(tester, 'SU1');
    expect(selectedBerths(tester, 'SU1'), 0);
  });

  testWidgets('a stranger can take the half of a double already half sold',
      (tester) async {
    // One berth of DU1 is gone on both legs — the live half-sold case.
    final avail = availabilityByKey(const [
      SeatAvailability(busId: busId, seatId: 'DU1', usedGo: 1, usedRet: 1),
    ]);

    await tester.pumpWidget(harness([bus(oneRow())], availability: avail));
    await tester.pumpAndSettle();
    await clearPrefill(tester);

    await tapSeat(tester, 'DU1');
    // The whole sofa is not for sale — one berth is already someone else's —
    // so the sheet offers only the berth that exists.
    expect(find.byKey(SofaShareSheet.wholeKey), findsNothing);
    await tester.tap(find.byKey(SofaShareSheet.halfKey));
    await tester.pumpAndSettle();

    expect(
      selectedBerths(tester, 'DU1'),
      1,
      reason: 'the remaining berth must still be sellable to a stranger',
    );
  });

  testWidgets('a fully sold seat is not selectable at all', (tester) async {
    final avail = availabilityByKey(const [
      SeatAvailability(busId: busId, seatId: 'SU1', usedGo: 1, usedRet: 1),
    ]);

    await tester.pumpWidget(harness([bus(oneRow())], availability: avail));
    await tester.pumpAndSettle();

    await tapSeat(tester, 'SU1');
    expect(selectedBerths(tester, 'SU1'), 0);
  });

  testWidgets('the booking cap counts BERTHS, not cells', (tester) async {
    // Four doubles = 8 berths. Taking four whole sofas would be 4 CELLS — under
    // any cell-based cap — but 8 berths, over the 6-berth cap.
    await tester.pumpWidget(harness([bus(fourDoubles())]));
    await tester.pumpAndSettle();
    await clearPrefill(tester);

    for (final id in ['DU1', 'DL1', 'DU2']) {
      await takeSofa(tester, id, whole: true);
    }

    final total = ['DU1', 'DL1', 'DU2', 'DL2']
        .map((id) => selectedBerths(tester, id))
        .fold<int>(0, (a, b) => a + b);
    expect(total, 6, reason: 'three whole sofas is exactly the cap');

    // A fourth whole sofa would be 8 berths. The cap must refuse it.
    await takeSofa(tester, 'DL2', whole: true);
    expect(
      selectedBerths(tester, 'DL2'),
      0,
      reason: 'a 7th berth must be refused — the cap is 6 BERTHS. Migration '
          '048 caps jsonb_array_length(p_seats), which counts CELLS, so a '
          'cell-based cap would have allowed 8 berths here.',
    );
  });
}
