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
import 'package:occubusbooking/screens/tour_seat_assignment_screen.dart';

/// PERF pin: on a low-end phone the seat workbench must not repaint all ~37
/// seat tiles for UI chrome that never touches the chart (opening/closing the
/// assignment dock). Rebuilds are counted by WIDGET IDENTITY: a tile whose
/// widget instance is unchanged after the interaction was not rebuilt.

class _FakeTourController extends TourController {
  @override
  // ignore: must_call_super
  void onInit() {}
}

const _tourId = 't1';

Tour _tour({required int seated}) {
  final layout = BusLayout.generate(busType: BusType.sleeper, totalSeats: 37);
  final ids = layout.allSeatIds;
  final passengers = <Passenger>[
    for (var i = 0; i < seated; i++)
      Passenger(
        id: 'p$i',
        tourId: _tourId,
        name: 'Rider $i',
        phone: '+91000000000$i',
        requestLines: [RequestLine(seatType: SeatType.singleSofa, qty: 1)],
        assignedSeats: [SeatAssignment(busId: 'b1', seatId: ids[i])],
      ),
    // Two pending riders so the dock has an active passenger to expand.
    for (var i = 0; i < 2; i++)
      Passenger(
        id: 'q$i',
        tourId: _tourId,
        name: 'Pending $i',
        phone: '+91999999999$i',
        requestLines: [RequestLine(seatType: SeatType.singleSofa, qty: 1)],
      ),
  ];
  return Tour(
    id: _tourId,
    title: 'Perf Yatra',
    fromCity: 'Surat',
    toCity: 'Dwarka',
    departureDate: DateTime(2026, 7, 1),
    pricePerSeat: 1200,
    buses: [
      Bus(id: 'b1', name: 'Bus 1', busType: 'Sleeper', layout: layout),
    ],
    passengers: passengers,
  );
}

List<SeatChartTile> _tiles(WidgetTester tester) =>
    tester.widgetList<SeatChartTile>(find.byType(SeatChartTile)).toList();

int _rebuilt(List<SeatChartTile> before, List<SeatChartTile> after) {
  var n = 0;
  for (var i = 0; i < after.length; i++) {
    if (i >= before.length || !identical(before[i], after[i])) n++;
  }
  return n;
}

void main() {
  tearDown(Get.reset);

  Future<_FakeTourController> pump(WidgetTester tester) async {
    final ctrl = _FakeTourController();
    Get.put<TourController>(ctrl);
    ctrl.tours.assignAll([_tour(seated: 12)]);
    await tester.binding.setSurfaceSize(const Size(1200, 2600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(GetMaterialApp(
      theme: ThemeData(brightness: Brightness.dark),
      home: const TourSeatAssignmentScreen(tourId: _tourId),
    ));
    await tester.pumpAndSettle();
    return ctrl;
  }

  testWidgets('expanding / collapsing the dock rebuilds ZERO seat tiles',
      (tester) async {
    await pump(tester);
    final before = _tiles(tester);
    expect(before.length, greaterThanOrEqualTo(15));

    // Tap the active card (it toggles the dock, same as the grab handle).
    await tester.tap(find.text('Pending 0').first);
    await tester.pumpAndSettle();
    final afterExpand = _tiles(tester);
    // ignore: avoid_print
    print('PERF dock expand: ${_rebuilt(before, afterExpand)}/'
        '${afterExpand.length} seat tiles rebuilt');
    expect(_rebuilt(before, afterExpand), 0);
  });

  testWidgets('a tour change (seat assigned) still repaints the chart',
      (tester) async {
    final ctrl = await pump(tester);
    final before = _tiles(tester);
    final t = ctrl.getTour(_tourId)!;
    final ids = t.buses.first.layout!.allSeatIds;
    // Seat the first pending rider on the next free seat.
    final updated = t.copyWith(
      passengers: [
        for (final p in t.passengers)
          p.id == 'q0'
              ? p.copyWith(assignedSeats: [
                  SeatAssignment(busId: 'b1', seatId: ids[12]),
                ])
              : p,
      ],
    );
    ctrl.tours[0] = updated;
    ctrl.tours.refresh();
    await tester.pumpAndSettle();
    final after = _tiles(tester);
    expect(_rebuilt(before, after), greaterThan(0));
    // The newly seated rider shows on the chart (memo invalidated).
    final seated = after.where(
      (w) => w.cell.seatId == ids[12] && w.occupants.any((p) => p.id == 'q0'),
    );
    expect(seated, hasLength(1));
  });
}
