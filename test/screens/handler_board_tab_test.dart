import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:occubusbooking/controllers/handler_controller.dart';
import 'package:occubusbooking/design/ugam.dart';
import 'package:occubusbooking/models/bus_details.dart';
import 'package:occubusbooking/models/handler_manifest.dart';
import 'package:occubusbooking/models/handler_phase.dart';
import 'package:occubusbooking/models/passenger.dart';
import 'package:occubusbooking/models/request_line.dart';
import 'package:occubusbooking/models/seat_assignment.dart';
import 'package:occubusbooking/models/seat_layout.dart';
import 'package:occubusbooking/models/seat_type.dart';
import 'package:occubusbooking/models/trip_type.dart';
import 'package:occubusbooking/screens/handler/handler_shell.dart';
import 'package:occubusbooking/widgets/handler/handler_attendance_row.dart';

/// The Board tab as a roll call actually happens: at the depot, with a real
/// stop's worth of riders.
///
/// Rendered against the live 2026-09-05 manifest the tab put THREE riders on a
/// phone screen — every row two lines tall with a call button on its own line
/// — so the main stop's 17 riders were six screens of scrolling, with "Board
/// all 17 here" at the very bottom, and the tally called all 24 "Left behind"
/// while the bus was still parked.
///
/// EasyLocalization is not initialised, so `tr(key)` returns the raw key.
void main() {
  tearDown(Get.reset);

  const busId = 'bus-1';

  Bus bus() => Bus(
    id: busId,
    tourId: 'tour-1',
    name: 'Bus 1',
    pricePerSeat: 1000,
    layout: BusLayout(
      rows: 3,
      cols: SeatGridCols.count,
      grid: [
        for (var r = 0; r < 3; r++) ...[
          SeatCell(
            row: r,
            col: SeatGridCols.singleLower,
            seatType: SeatType.singleSofa,
            position: SeatPosition.lower,
            seatId: 'SL$r',
          ),
          SeatCell(
            row: r,
            col: SeatGridCols.singleUpper,
            seatType: SeatType.singleSofa,
            position: SeatPosition.upper,
            seatId: 'SU$r',
          ),
        ],
      ],
    ),
  );

  /// Six round-trip riders at one pickup point.
  List<Passenger> riders() => [
    for (var i = 0; i < 6; i++)
      Passenger(
        id: 'p-$i',
        tourId: 'tour-1',
        name: 'Rider $i',
        phone: '999000000$i',
        pickupLocationName: 'Vraj Bhoomi Parking',
        assignedSeats: [
          SeatAssignment(busId: busId, seatId: i < 3 ? 'SL$i' : 'SU${i - 3}'),
        ],
        requestLines: [
          RequestLine(
            seatType: SeatType.singleSofa,
            qty: 1,
            leg: TripType.roundTrip,
          ),
        ],
        tripType: TripType.roundTrip,
      ),
  ];

  Widget app() => GetMaterialApp(
    theme: ThemeData(brightness: Brightness.dark),
    home: HandlerShell(
      requestId: 'req-1',
      manifestReader: (_) async =>
          HandlerManifest(buses: [bus()], passengers: riders()),
    ),
  );

  Future<void> mount(WidgetTester tester) async {
    tester.view.physicalSize = const Size(393 * 3, 852 * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
  }

  HandlerController controller() =>
      Get.find<HandlerController>(tag: 'handler-req-1');

  group('the tally', () {
    testWidgets('calls unmarked riders "not yet boarded" before departure', (
      tester,
    ) async {
      await mount(tester);

      expect(find.text('handler_chart.att_not_boarded'), findsOneWidget);
      expect(find.text('handler_chart.att_left_behind'), findsNothing);
    });

    testWidgets('calls unmarked riders "left behind" once the bus has gone', (
      tester,
    ) async {
      await mount(tester);
      controller().tripState[busId] = HandlerTripState(
        busId: busId,
        goDepartedAt: DateTime(2026, 9, 5, 17),
      );
      await tester.pumpAndSettle();

      expect(find.text('handler_chart.att_left_behind'), findsOneWidget);
      expect(find.text('handler_chart.att_not_boarded'), findsNothing);
    });
  });

  group('the current stop', () {
    testWidgets('fits a rider row in 64 logical pixels', (tester) async {
      await mount(tester);

      final rows = find.byType(HandlerAttendanceRow);
      expect(rows, findsWidgets);
      final h = tester.getSize(rows.first).height;
      expect(
        h,
        lessThanOrEqualTo(64),
        reason:
            'a $h px row puts three riders on a phone screen; a roll call '
            'needs the name, the toggle and a call button on ONE line',
      );
    });

    testWidgets('offers "board all" ABOVE its riders, not after them', (
      tester,
    ) async {
      await mount(tester);

      final boardAll = find.widgetWithText(
        UgamButton,
        'handler_chart.stop_board_all',
      );
      expect(boardAll, findsOneWidget);
      final firstRow = find.byType(HandlerAttendanceRow).first;
      expect(
        tester.getTopLeft(boardAll).dy,
        lessThan(tester.getTopLeft(firstRow).dy),
        reason: 'the bulk action must not sit below a stop-long scroll',
      );
    });
  });
}
