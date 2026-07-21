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
/// The richer per-seat tile look (initials, group/priority rings, the one-way
/// GO/RET badge + cyan tint, leg-shared split tile, Held look, money dots) and
/// the Grid|Attendance view toggle all need a loaded manifest, so they are verified
/// by eye against the agent seat-detail screen, whose own widget test
/// (`seat_detail_screen_test.dart`) locks the shared tile contract.
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

    // EasyLocalization is NOT initialised under `flutter test`, so `tr(key)`
    // returns the raw key. The screen titles its app bar with
    // `tr('handler_chart.bus_chart')` (English copy "Bus chart"); under test
    // that surfaces as the raw key. Asserting the key still proves the
    // read-only header rendered on the first (loading) frame.
    expect(find.text('handler_chart.bus_chart'), findsOneWidget);
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
    // than crashing. Under test, `tr()` yields raw keys: the app-bar title is
    // `handler_chart.bus_chart` ("Bus chart") and the empty-state title is
    // `handler_chart.error_load_title` ("Couldn't load chart").
    expect(find.text('handler_chart.bus_chart'), findsOneWidget);
    expect(find.text('handler_chart.error_load_title'), findsOneWidget);
  });
}
