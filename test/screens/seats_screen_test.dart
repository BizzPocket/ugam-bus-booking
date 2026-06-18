import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:occubusbooking/controllers/tour_controller.dart';
import 'package:occubusbooking/models/bus_details.dart';
import 'package:occubusbooking/models/bus_type.dart';
import 'package:occubusbooking/models/passenger.dart';
import 'package:occubusbooking/models/request_line.dart';
import 'package:occubusbooking/models/seat_layout.dart';
import 'package:occubusbooking/models/seat_type.dart';
import 'package:occubusbooking/models/tour.dart';
import 'package:occubusbooking/screens/seats_screen.dart';

/// Test double: skip the real network load + realtime wiring so registering
/// the controller doesn't need Supabase/GetX services.
class _FakeTourController extends TourController {
  @override
  // ignore: must_call_super
  void onInit() {}
}

Bus _bus(String id, String name, {required int seats}) => Bus(
      id: id,
      name: name,
      busType: 'Sleeper',
      layout: BusLayout.generate(busType: BusType.sleeper, totalSeats: seats),
    );

Passenger _passenger(String id, String tourId) => Passenger(
      id: id,
      tourId: tourId,
      name: id,
      phone: '+910000000000',
      requestLines: [RequestLine(seatType: SeatType.doubleSofa, qty: 1)],
    );

Tour _fakeTour() {
  const tourId = 't1';
  return Tour(
    id: tourId,
    title: 'Dwarka Yatra',
    fromCity: 'Surat',
    toCity: 'Dwarka',
    departureDate: DateTime(2026, 7, 1),
    pricePerSeat: 1200,
    buses: [_bus('b1', 'Bus 1', seats: 30), _bus('b2', 'Bus 2', seats: 30)],
    passengers: [
      _passenger('p1', tourId),
      _passenger('p2', tourId),
      _passenger('p3', tourId),
    ],
  );
}

Widget _harness() => GetMaterialApp(
      theme: ThemeData(brightness: Brightness.dark),
      home: const SeatsScreen(tourId: 't1'),
    );

void main() {
  tearDown(Get.reset);

  // The screen was redesigned from a 3-mode segmented control into a
  // SUMMARY → GRID relationship (see SeatsScreen doc-comment). There is no
  // segmented control any more; the header carries the tour title + a
  // mode subtitle (summary vs grid), and the body is the embedded
  // TourOverviewScreen (summary) which exposes the auto-fill / edit-by-hand
  // CTAs. EasyLocalization isn't initialised in tests so tr() returns the
  // raw key — we assert those.

  testWidgets('renders the tour title + summary subtitle in the header',
      (tester) async {
    final ctrl = _FakeTourController();
    Get.put<TourController>(ctrl);
    ctrl.tours.assignAll([_fakeTour()]);

    await tester.pumpWidget(_harness());
    await tester.pump();

    expect(find.text('Dwarka Yatra'), findsOneWidget);
    // Lands on the summary face → its subtitle key renders (grid subtitle does
    // not). Confirms the redesigned summary→grid header, not a segmented bar.
    expect(find.text('seats.summary_subtitle'), findsOneWidget);
    expect(find.text('seats.grid_subtitle'), findsNothing);
  });

  testWidgets('defaults to the summary face (the auto-fill cockpit is visible)',
      (tester) async {
    final ctrl = _FakeTourController();
    Get.put<TourController>(ctrl);
    ctrl.tours.assignAll([_fakeTour()]);

    await tester.pumpWidget(_harness());
    await tester.pump();

    // Embedded summary cockpit → both of its sticky CTAs render (raw keys):
    // the primary "edit by hand" entry into the grid and the auto-fill button.
    expect(find.text('tour_overview.cta_edit_by_hand'), findsOneWidget);
    expect(find.text('tour_overview.fill_bus'), findsOneWidget);
  });

  testWidgets('edit-by-hand swaps the body to the grid face', (tester) async {
    final ctrl = _FakeTourController();
    Get.put<TourController>(ctrl);
    ctrl.tours.assignAll([_fakeTour()]);

    await tester.pumpWidget(_harness());
    await tester.pump();

    // Start on the summary face: its subtitle + auto-fill CTA are present.
    expect(find.text('seats.summary_subtitle'), findsOneWidget);
    expect(find.text('tour_overview.fill_bus'), findsOneWidget);

    // Tap "Edit seats by hand" → SeatsScreen flips to the grid face. The
    // header subtitle switches and the summary's auto-fill cockpit goes
    // offstage (IndexedStack hides it).
    await tester.tap(find.text('tour_overview.cta_edit_by_hand'));
    await tester.pumpAndSettle();

    expect(find.text('seats.grid_subtitle'), findsOneWidget);
    expect(find.text('seats.summary_subtitle'), findsNothing);
    expect(find.text('tour_overview.fill_bus'), findsNothing);

    // Tap the "Summary" back-affordance (the grid's leading control carries
    // this semantic label) → the summary cockpit returns.
    await tester.tap(find.bySemanticsLabel('seats.back_to_summary'));
    await tester.pumpAndSettle();

    expect(find.text('seats.summary_subtitle'), findsOneWidget);
    expect(find.text('tour_overview.fill_bus'), findsOneWidget);
  });
}
