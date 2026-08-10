import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:occubusbooking/components/seat_chart_tile.dart';
import 'package:occubusbooking/models/bus_details.dart';
import 'package:occubusbooking/models/collection.dart';
import 'package:occubusbooking/models/handler_manifest.dart';
import 'package:occubusbooking/models/passenger.dart';
import 'package:occubusbooking/models/request_line.dart';
import 'package:occubusbooking/models/seat_assignment.dart';
import 'package:occubusbooking/models/seat_layout.dart';
import 'package:occubusbooking/models/seat_type.dart';
import 'package:occubusbooking/models/trip_type.dart';
import 'package:occubusbooking/screens/handler_bus_chart_screen.dart';

/// Widget tests for the read-only handler bus chart.
///
/// The screen pulls its data from the `CustomerRequestsStore` SINGLETON, which
/// talks to `Supabase.instance.client` directly, and Supabase is NOT initialised
/// under `flutter test`. The first two tests therefore exercise what is
/// deterministic against that dead backend:
///
///   * the read-only header renders (title + back affordance) and carries NO
///     edit/assignment affordances (the handler never edits seats), and
///   * the failed-load path degrades to a friendly empty state instead of
///     throwing — the manifest fetch raises (uninitialised Supabase), the
///     screen catches it and shows the "Couldn't load chart" copy.
///
/// The refresh-loop tests below instead drive the manifest read through
/// `HandlerBusChartScreen.manifestReader`, the @visibleForTesting seam added
/// alongside the loop (the store itself is a private-constructor singleton and
/// cannot be faked).
///
/// The richer per-seat tile look (initials, group/priority rings, the one-way
/// GO/RET badge + cyan tint, leg-shared split tile, Held look, money dots) and
/// the Grid|Attendance view toggle all need a loaded manifest, so they are verified
/// by eye against the agent seat-detail screen, whose own widget test
/// (`seat_detail_screen_test.dart`) locks the shared tile contract.
void main() {
  tearDown(Get.reset);

  testWidgets('renders the read-only "Bus chart" header on first frame', (
    tester,
  ) async {
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

  testWidgets('failed manifest load degrades to a friendly empty state', (
    tester,
  ) async {
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

  // ─── Refresh loop ────────────────────────────────────────────────────
  //
  // The handler used to read a snapshot frozen at screen-open: `_load()` ran
  // once in initState and nowhere else, so every admin edit made mid-trip was
  // invisible until the app was force-quit — the single biggest reason the
  // handler's figures disagreed with the admin's. These lock the refresh loop.
  //
  // They drive the screen through `manifestReader`, the @visibleForTesting seam
  // on the widget. It exists because `CustomerRequestsStore` is a
  // private-constructor singleton wired straight to `Supabase.instance.client`:
  // it cannot be subclassed or swapped, so without the seam a widget test could
  // only ever exercise the FAILURE path (as the two tests above do) and the
  // "preserve last-known figures" guard would be untestable. The handover /
  // leg-state reads need no seam — they are already best-effort and degrade to
  // empty when Supabase is uninitialised.

  /// A one-bus manifest holding a single collection of [collected] rupees, so
  /// the money hero renders a figure the test can assert on. No passengers: the
  /// hero's `outstanding` is then exactly the collected cash, which keeps the
  /// expected string independent of seat-fare math.
  HandlerManifest manifestWith(double collected) => HandlerManifest(
    buses: [Bus(id: 'bus-1', tourId: 'tour-1', name: 'Bus 1')],
    collections: [
      Collection(
        tourId: 'tour-1',
        busId: 'bus-1',
        passengerId: 'p-1',
        seatId: 'A1',
        amountDue: collected,
        amountReceived: collected,
      ),
    ],
  );

  /// The body's pull-to-refresh target — scoped through the [RefreshIndicator]
  /// so it can never match some other scroll view on screen.
  final refreshable = find.descendant(
    of: find.byType(RefreshIndicator),
    matching: find.byType(SingleChildScrollView),
  );

  testWidgets('pull-to-refresh re-reads the manifest', (tester) async {
    var calls = 0;
    await tester.pumpWidget(
      GetMaterialApp(
        theme: ThemeData(brightness: Brightness.dark),
        home: HandlerBusChartScreen(
          requestId: 'req-1',
          // Second read returns a BIGGER figure — exactly the shape of an admin
          // edit landing mid-trip, which the frozen screen could never show.
          manifestReader: (_) async => manifestWith(++calls == 1 ? 1200 : 1800),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(calls, 1);
    // findsWidgets, not findsOneWidget: the same figure legitimately renders
    // twice — once as the money hero's headline, once as the settlement card's
    // outstanding line.
    expect(find.text('₹1,200'), findsWidgets);

    await tester.fling(refreshable, const Offset(0, 320), 1000);
    await tester.pumpAndSettle();

    expect(calls, 2);
    expect(find.text('₹1,800'), findsWidgets);
    expect(find.text('₹1,200'), findsNothing);
  });

  testWidgets('a failed refresh preserves the previously loaded figures', (
    tester,
  ) async {
    var calls = 0;
    await tester.pumpWidget(
      GetMaterialApp(
        theme: ThemeData(brightness: Brightness.dark),
        home: HandlerBusChartScreen(
          requestId: 'req-1',
          manifestReader: (_) async {
            if (++calls == 1) return manifestWith(1200);
            throw StateError('transient network failure');
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('₹1,200'), findsWidgets);

    await tester.fling(refreshable, const Offset(0, 320), 1000);
    await tester.pumpAndSettle();

    expect(calls, 2);
    // The whole point: a transient failure must NOT blank the board. The
    // handler keeps reading the last-known figure instead of a ₹0 cockpit or a
    // full-screen "couldn't load" that throws away good data.
    expect(find.text('₹1,200'), findsWidgets);
    expect(find.text('handler_chart.error_load_title'), findsNothing);
    // The failure IS surfaced — `AppSnackBar.error('handler_chart.error_refresh')`
    // — but that toast renders into the ROOT Overlay via `Get.overlayContext`,
    // which never materialises under `flutter test`, so it is unassertable here
    // (as it is for every other AppSnackBar call site in the app). What this
    // test locks is the destructive half: the board survives.
  });

  testWidgets('the error card retry action re-loads the chart', (tester) async {
    var calls = 0;
    await tester.pumpWidget(
      GetMaterialApp(
        theme: ThemeData(brightness: Brightness.dark),
        home: HandlerBusChartScreen(
          requestId: 'req-1',
          manifestReader: (_) async {
            if (++calls == 1) throw StateError('cold start failure');
            return manifestWith(1200);
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Nothing was ever loaded, so the failure DOES own the body — and now it
    // offers a way out instead of stranding the handler on a dead card.
    expect(find.text('handler_chart.error_load_title'), findsOneWidget);
    expect(find.text('actions.retry'), findsOneWidget);

    await tester.tap(find.text('actions.retry'));
    await tester.pumpAndSettle();

    expect(calls, 2);
    expect(find.text('handler_chart.error_load_title'), findsNothing);
    expect(find.text('₹1,200'), findsWidgets);
  });

  // ─── Duplicate collections ───────────────────────────────────────────
  //
  // The chart resolved a rider's collection by the (passenger, bus, SEAT)
  // triple, which is also the DB's unique index. A rider who paid on one seat
  // and later sat in another therefore missed, was handed a fresh uuid, and the
  // insert did not collide — a SECOND row, and their cash folded twice by every
  // money figure on both the handler's screen and the admin's board. The rule
  // that fixes it lives in `collection_seat_resolver.dart` and is exercised
  // exhaustively in `test/models/collection_seat_resolver_test.dart`; this test
  // locks the WIRING — that the screen's own lookup goes through it.

  testWidgets('a moved rider re-opens their EXISTING collection, not a blank one', (
    tester,
  ) async {
    final bus = Bus(
      id: 'bus-1',
      tourId: 'tour-1',
      name: 'Bus 1',
      pricePerSeat: 1000,
      singleSofaPrice: 1200,
      layout: BusLayout(
        rows: 1,
        cols: SeatGridCols.count,
        grid: const [
          SeatCell(
            row: 0,
            col: SeatGridCols.singleLower,
            seatType: SeatType.singleSofa,
            position: SeatPosition.lower,
            seatId: 'SL1',
          ),
        ],
      ),
    );
    final rider = Passenger(
      id: 'p-1',
      tourId: 'tour-1',
      name: 'Rider',
      phone: '9990000000',
      assignedSeats: const [SeatAssignment(busId: 'bus-1', seatId: 'SL1')],
      requestLines: [
        RequestLine(
          seatType: SeatType.singleSofa,
          qty: 1,
          leg: TripType.roundTrip,
        ),
      ],
      tripType: TripType.roundTrip,
    );
    // ₹900 taken while they were still in ST9 — a seat they have since left, so
    // no seat on this chart names it any more.
    final stranded = Collection(
      tourId: 'tour-1',
      busId: 'bus-1',
      passengerId: 'p-1',
      seatId: 'ST9',
      amountDue: 900,
      amountReceived: 900,
    );

    await tester.pumpWidget(
      GetMaterialApp(
        theme: ThemeData(brightness: Brightness.dark),
        home: HandlerBusChartScreen(
          requestId: 'req-1',
          manifestReader: (_) async => HandlerManifest(
            buses: [bus],
            passengers: [rider],
            collections: [stranded],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Attendance is the default view, so reach the chart the way a handler
    // does — one tap on the Grid pill.
    await tester.tap(find.text('handler_chart.view_grid'));
    await tester.pumpAndSettle();

    final tile = find.byType(SeatChartTile);
    expect(tile, findsOneWidget);
    await tester.ensureVisible(tile);
    await tester.pumpAndSettle();
    await tester.tap(tile);
    await tester.pumpAndSettle();

    // The collect sheet opened on the seat they now hold …
    expect(find.text('handler_chart.collect_title'), findsOneWidget);
    // … pre-filled from the row they ALREADY have on this bus. An empty
    // "received" field is the tell that the screen missed the row and is about
    // to write a second one: saving would then bank ₹900 + whatever is typed
    // here as two rows of real cash.
    expect(find.text('900'), findsOneWidget);
  });
}
