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

    // The grid face renders the full seat workbench (on device it lives in a
    // scrollable InteractiveViewer); it overflows the default 800x600 test
    // window, so give it a tall surface to render cleanly.
    await tester.binding.setSurfaceSize(const Size(1200, 2600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

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

  testWidgets(
      'grid face: no edit-seats chip; dock reads Now-seating + Up-next '
      '(visual polish)', (tester) async {
    final ctrl = _FakeTourController();
    Get.put<TourController>(ctrl);
    ctrl.tours.assignAll([_fakeTour()]);

    await tester.binding.setSurfaceSize(const Size(1200, 2600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(_harness());
    await tester.pump();
    await tester.tap(find.text('tour_overview.cta_edit_by_hand'));
    await tester.pumpAndSettle();

    // On the grid workbench now.
    expect(find.text('seats.grid_subtitle'), findsOneWidget);

    // The removed "સીટ બદલો" edit-seats chip no longer renders (its label key
    // used the raw tr text). Premium/Held moved into the seat tap menu.
    expect(find.text('tour_seat_assignment.edit_seats'), findsNothing);

    // The redesigned dock shows two clearly-separated zones. Both eyebrows go
    // through [UgamSectionLabel], which renders its label VERBATIM — it used
    // to `.toUpperCase()` onto `micro`, a no-op in Gujarati that also split
    // conjuncts, so the caps device was dropped. In tests the rendered string
    // is therefore the raw tr() key, unchanged.
    expect(find.text('tour_seat_assignment.now_seating'), findsOneWidget);
    expect(find.text('tour_seat_assignment.up_next'), findsOneWidget);
  });

  testWidgets(
      'deep-linked straight into grid: back pops to the caller, not the '
      'summary (chart-screen redirect bug)', (tester) async {
    final ctrl = _FakeTourController();
    Get.put<TourController>(ctrl);
    ctrl.tours.assignAll([_fakeTour()]);

    // The grid face renders the full seat workbench, which overflows the
    // default 800x600 test window. Give it a tall surface so the only thing
    // this test can fail on is the back-navigation assertion below.
    await tester.binding.setSurfaceSize(const Size(1200, 2600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    // A stand-in "chart screen" that deep-links directly into the grid face,
    // exactly like ChartsScreen._editSeats → AppRoutes.seatAssignment does.
    await tester.pumpWidget(GetMaterialApp(
      theme: ThemeData(brightness: Brightness.dark),
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () => Get.to(
                () => const SeatsScreen(
                  tourId: 't1',
                  initialMode: SeatsMode.grid,
                ),
              ),
              child: const Text('CHART_CALLER'),
            ),
          ),
        ),
      ),
    ));
    await tester.pump();

    await tester.tap(find.text('CHART_CALLER'));
    await tester.pumpAndSettle();

    // We landed on the grid face without ever seeing the summary.
    expect(find.text('seats.grid_subtitle'), findsOneWidget);
    expect(find.text('seats.summary_subtitle'), findsNothing);

    // Tapping the grid's back arrow must POP the route → back to the caller.
    // The bug: it switched to the summary cockpit (a "bus cards" screen the
    // agent never visited) instead of returning to where they came from.
    await tester.tap(find.byIcon(Icons.arrow_back_rounded));
    await tester.pumpAndSettle();

    expect(find.text('CHART_CALLER'), findsOneWidget);
    expect(find.text('seats.summary_subtitle'), findsNothing);
    expect(find.text('seats.grid_subtitle'), findsNothing);
  });

  testWidgets(
      'pushed onto a nested tab navigator: back pops the nested navigator '
      'back to the caller (not the dead root)', (tester) async {
    final ctrl = _FakeTourController();
    Get.put<TourController>(ctrl);
    ctrl.tours.assignAll([_fakeTour()]);

    // Reproduce MainShell's per-tab nested Navigator: SeatsScreen is pushed
    // onto an INNER navigator (exactly like the Dashboard / Tours / Tour-Detail
    // entries do via Navigator.of(context).push), while the root navigator
    // holds only the shell. A hand-rolled Get.back() pops the ROOT — which has
    // nothing above the shell — so the back arrow is dead and strands the user
    // on the seat screen. AppNav.pop pops the navigator the screen lives on.
    await tester.pumpWidget(GetMaterialApp(
      theme: ThemeData(brightness: Brightness.dark),
      home: Navigator(
        onGenerateRoute: (_) => MaterialPageRoute(
          builder: (innerContext) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => Navigator.of(innerContext).push(
                  MaterialPageRoute(
                    builder: (_) => const SeatsScreen(tourId: 't1'),
                  ),
                ),
                child: const Text('TAB_CALLER'),
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.pump();

    await tester.tap(find.text('TAB_CALLER'));
    await tester.pumpAndSettle();

    // Landed on the summary face (the default mode).
    expect(find.text('seats.summary_subtitle'), findsOneWidget);

    // Back must pop the nested navigator → return to TAB_CALLER.
    await tester.tap(find.byIcon(Icons.arrow_back_rounded));
    await tester.pumpAndSettle();

    expect(find.text('TAB_CALLER'), findsOneWidget);
    expect(find.text('seats.summary_subtitle'), findsNothing);
  });
}
