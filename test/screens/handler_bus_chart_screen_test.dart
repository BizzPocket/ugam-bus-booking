import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:occubusbooking/screens/handler_bus_chart_screen.dart';

/// Widget tests for the read-only handler bus chart.
///
/// The screen pulls its data from the `CustomerRequestsStore` SINGLETON, which
/// talks to `Supabase.instance.client` directly — there's no seam to inject a
/// fake manifest here, and Supabase is NOT initialised under `flutter test`.
/// So these tests exercise what is deterministic WITHOUT a live backend:
///
///   * the read-only header renders (title + back affordance) and carries NO
///     edit/assignment affordances (the handler never edits seats), and
///   * the failed-load path degrades to a friendly empty state instead of
///     throwing — the manifest fetch raises (uninitialised Supabase), the
///     screen catches it and shows the "Couldn't load chart" copy.
///
/// The richer per-seat tile look (initials, group/priority rings, Held look,
/// money dots) is verified by eye against the agent seat-detail screen, whose
/// own widget test (`seat_detail_screen_test.dart`) locks that tile contract.
void main() {
  tearDown(Get.reset);

  testWidgets('renders the read-only "Bus chart" header on first frame',
      (tester) async {
    await tester.pumpWidget(
      GetMaterialApp(
        theme: ThemeData(brightness: Brightness.dark),
        home: const HandlerBusChartScreen(requestId: 'req-1'),
      ),
    );
    // First frame: still loading (the manifest future has not completed).
    await tester.pump();

    expect(find.text('Bus chart'), findsOneWidget);
    // Read-only: there is no "Edit seats" / "Done" affordance anywhere (those
    // belong to the agent seat-detail screen, not the handler chart).
    expect(find.text('Edit seats'), findsNothing);
    expect(find.text('Done'), findsNothing);
  });

  testWidgets('failed manifest load degrades to a friendly empty state',
      (tester) async {
    await tester.pumpWidget(
      GetMaterialApp(
        theme: ThemeData(brightness: Brightness.dark),
        home: const HandlerBusChartScreen(requestId: 'req-1'),
      ),
    );
    // Let the manifest fetch fail (Supabase is uninitialised under test) and
    // the catch-block error state settle.
    await tester.pumpAndSettle();

    // The header survives, and the body shows the load-failure copy rather
    // than crashing.
    expect(find.text('Bus chart'), findsOneWidget);
    expect(find.text("Couldn't load chart"), findsOneWidget);
  });
}
