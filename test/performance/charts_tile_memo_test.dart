import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:occubusbooking/components/seat_chart_tile.dart';
import 'package:occubusbooking/controllers/tour_controller.dart';
import 'package:occubusbooking/models/bus_details.dart';
import 'package:occubusbooking/models/bus_type.dart';
import 'package:occubusbooking/models/passenger.dart';
import 'package:occubusbooking/models/request_line.dart';
import 'package:occubusbooking/models/seat_assignment.dart';
import 'package:occubusbooking/models/seat_layout.dart';
import 'package:occubusbooking/models/seat_type.dart';
import 'package:occubusbooking/models/tour.dart';
import 'package:occubusbooking/screens/charts_screen.dart';

/// PERF pin: the Charts tab stays mounted in the shell and re-runs on every
/// `tours` change. Only the tile whose occupants changed may rebuild — and a
/// re-instanced rider (fresh data) must still repaint.

class _FakeTourController extends TourController {
  @override
  // ignore: must_call_super
  void onInit() {}

  @override
  Future<void> ensureTourReadyForSeating(String tourId) async {}
}

Tour _tour() {
  final layout = BusLayout.generate(busType: BusType.sleeper, totalSeats: 37);
  final ids = layout.allSeatIds;
  return Tour(
    id: 't1',
    title: 'Perf Yatra',
    fromCity: 'Surat',
    toCity: 'Dwarka',
    departureDate: DateTime.now().add(const Duration(days: 10)),
    pricePerSeat: 1200,
    buses: [Bus(id: 'b1', name: 'Bus 1', busType: 'Sleeper', layout: layout)],
    passengers: [
      for (var i = 0; i < 10; i++)
        Passenger(
          id: 'p$i',
          tourId: 't1',
          name: 'Rider $i',
          phone: '+91900000000$i',
          requestLines: [RequestLine(seatType: SeatType.singleSofa, qty: 1)],
          assignedSeats: [SeatAssignment(busId: 'b1', seatId: ids[i])],
        ),
    ],
  );
}

List<SeatChartTile> _tiles(WidgetTester t) =>
    t.widgetList<SeatChartTile>(find.byType(SeatChartTile)).toList();

int _rebuilt(List<SeatChartTile> a, List<SeatChartTile> b) {
  var n = 0;
  for (var i = 0; i < b.length; i++) {
    if (i >= a.length || !identical(a[i], b[i])) n++;
  }
  return n;
}

void main() {
  tearDown(Get.reset);

  testWidgets('one rider renamed: 1 tile rebuilt, and it shows the new name',
      (tester) async {
    final ctrl = _FakeTourController();
    Get.put<TourController>(ctrl);
    ctrl.tours.assignAll([_tour()]);
    await tester.binding.setSurfaceSize(const Size(1200, 2600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(GetMaterialApp(
      theme: ThemeData(brightness: Brightness.dark),
      home: const ChartsScreen(),
    ));
    await tester.pumpAndSettle();
    final before = _tiles(tester);
    expect(before.length, greaterThanOrEqualTo(15));

    final t = ctrl.tours[0];
    ctrl.tours[0] = t.copyWith(passengers: [
      for (final p in t.passengers)
        p.id == 'p3' ? p.copyWith(name: 'Renamed Rider') : p,
    ]);
    ctrl.tours.refresh();
    await tester.pumpAndSettle();
    final after = _tiles(tester);
    // ignore: avoid_print
    print('PERF charts tab, one rider changed: '
        '${_rebuilt(before, after)}/${after.length} tiles rebuilt');
    expect(_rebuilt(before, after), 1);
    expect(find.textContaining('Renamed Rider'), findsOneWidget);
    expect(find.textContaining('Rider 3'), findsNothing);

    // Theme flip must repaint every tile (theme is part of the key).
    final beforeTheme = _tiles(tester);
    await tester.pumpWidget(GetMaterialApp(
      theme: ThemeData(brightness: Brightness.light),
      home: const ChartsScreen(),
    ));
    await tester.pumpAndSettle();
    expect(_rebuilt(beforeTheme, _tiles(tester)), _tiles(tester).length);
  });
}
