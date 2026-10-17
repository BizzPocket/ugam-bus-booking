import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:occubusbooking/components/seat_chart_tile.dart';
import 'package:occubusbooking/design/ugam.dart';
import 'package:occubusbooking/models/bus_details.dart';
import 'package:occubusbooking/models/collection.dart';
import 'package:occubusbooking/models/handler_manifest.dart';
import 'package:occubusbooking/models/handler_phase.dart';
import 'package:occubusbooking/models/passenger.dart';
import 'package:occubusbooking/models/payment_claim.dart';
import 'package:occubusbooking/models/request_line.dart';
import 'package:occubusbooking/models/seat_assignment.dart';
import 'package:occubusbooking/models/seat_layout.dart';
import 'package:occubusbooking/models/seat_type.dart';
import 'package:occubusbooking/models/trip_type.dart';
import 'package:occubusbooking/controllers/handler_controller.dart';
import 'package:occubusbooking/screens/handler/handler_shell.dart';

/// Widget tests for the handler shell — the four-tab surface that replaced the
/// single 4,186-line `HandlerBusChartScreen`.
///
/// Data comes from the `CustomerRequestsStore` SINGLETON, which talks to
/// `Supabase.instance.client` directly, and Supabase is NOT initialised under
/// `flutter test`. Tests that need a loaded board therefore drive the manifest
/// through `HandlerShell.manifestReader`, the @visibleForTesting seam — the
/// store is a private-constructor singleton and cannot be faked. The trip-state,
/// handover, leg-state and report reads need no seam: all four are best-effort
/// and degrade to empty when Supabase is dead, which is exactly what this
/// environment reproduces.
///
/// EasyLocalization is not initialised either, so `tr(key)` returns the raw key
/// and assertions are written against keys rather than English copy.
void main() {
  tearDown(Get.reset);

  /// A one-bus manifest holding a single collection of [collected] rupees, so
  /// the money hero renders a figure to assert on. No passengers, so the hero's
  /// `outstanding` is exactly the collected cash — keeping the expected string
  /// independent of seat-fare math.
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

  Widget app({HandlerManifestReader? reader, String? tourStatus}) =>
      GetMaterialApp(
        theme: ThemeData(brightness: Brightness.dark),
        home: HandlerShell(
          requestId: 'req-1',
          manifestReader: reader,
          tourStatus: tourStatus,
        ),
      );

  /// The dock button for a tab, scoped through [UgamDockNav] so it can never
  /// match the same icon used elsewhere (the phase banner reuses several).
  Finder dockTab(IconData icon) => find.descendant(
    of: find.byType(UgamDockNav),
    matching: find.byIcon(icon),
  );

  Future<void> openMoney(WidgetTester tester) async {
    await tester.tap(dockTab(Icons.account_balance_wallet_rounded));
    await tester.pumpAndSettle();
  }

  /// The pull-to-refresh target — the tab body's VERTICAL scroller, scoped
  /// through the [RefreshIndicator]. The axis test matters: the Money tab's
  /// filter pills are themselves a horizontal ListView under the same
  /// indicator, and a bare byType match finds both.
  final refreshable = find.descendant(
    of: find.byType(RefreshIndicator),
    matching: find.byWidgetPredicate(
      (w) => w is ListView && w.scrollDirection == Axis.vertical,
    ),
  );

  testWidgets('renders the read-only header on the first frame', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    await tester.pump();

    expect(find.text('handler_chart.bus_chart'), findsOneWidget);
    // Read-only: no edit/assignment affordance anywhere. Those belong to the
    // agent's seat-detail screen, never the handler's.
    expect(find.text('Edit seats'), findsNothing);
    expect(find.text('Done'), findsNothing);
  });

  testWidgets('failed manifest load degrades to a friendly error state', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    expect(find.text('handler_chart.bus_chart'), findsOneWidget);
    expect(find.text('handler_chart.error_load_title'), findsOneWidget);
  });

  // ─── Refresh loop ────────────────────────────────────────────────────
  //
  // The handler used to read a snapshot frozen at screen-open, so every agent
  // edit made mid-trip was invisible until the app was force-quit. These lock
  // the loop that fixed it, now that it lives in HandlerController.

  testWidgets('pull-to-refresh re-reads the manifest', (tester) async {
    var calls = 0;
    await tester.pumpWidget(
      app(
        // The second read returns a BIGGER figure — the shape of an agent edit
        // landing mid-trip.
        reader: (_) async => manifestWith(++calls == 1 ? 1200 : 1800),
      ),
    );
    await tester.pumpAndSettle();
    expect(calls, 1);

    await openMoney(tester);
    // findsWidgets, not findsOneWidget: the figure legitimately renders more
    // than once — the money hero's headline and the settlement card's line.
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
      app(
        reader: (_) async {
          if (++calls == 1) return manifestWith(1200);
          throw StateError('transient network failure');
        },
      ),
    );
    await tester.pumpAndSettle();
    await openMoney(tester);
    expect(find.text('₹1,200'), findsWidgets);

    await tester.fling(refreshable, const Offset(0, 320), 1000);
    await tester.pumpAndSettle();

    expect(calls, 2);
    // The whole point: a transient failure must NOT blank the board. The
    // handler keeps the last-known figure instead of a ₹0 cockpit or a
    // full-screen "couldn't load" that throws away good data.
    expect(find.text('₹1,200'), findsWidgets);
    expect(find.text('handler_chart.error_load_title'), findsNothing);
  });

  testWidgets('the error card retry action re-loads the board', (tester) async {
    var calls = 0;
    await tester.pumpWidget(
      app(
        reader: (_) async {
          if (++calls == 1) throw StateError('cold start failure');
          return manifestWith(1200);
        },
      ),
    );
    await tester.pumpAndSettle();

    // Nothing was ever loaded, so the failure DOES own the body — and it offers
    // a way out instead of stranding the handler on a dead card.
    expect(find.text('handler_chart.error_load_title'), findsOneWidget);
    expect(find.text('actions.retry'), findsOneWidget);

    await tester.tap(find.text('actions.retry'));
    await tester.pumpAndSettle();

    expect(calls, 2);
    expect(find.text('handler_chart.error_load_title'), findsNothing);
    await openMoney(tester);
    expect(find.text('₹1,200'), findsWidgets);
  });

  // ─── The phase banner ────────────────────────────────────────────────
  //
  // The failure this whole redesign exists to fix: the old screen rendered
  // every feature at equal weight and never said what to do next.

  testWidgets('a fresh bus opens on boarding and offers the departure stamp', (
    tester,
  ) async {
    await tester.pumpWidget(app(reader: (_) async => manifestWith(0)));
    await tester.pumpAndSettle();

    // Nothing is stamped, so the phase is boardingGo …
    expect(find.text('HANDLER_PHASE.BOARDING_GO'), findsOneWidget);
    // … and exactly one milestone is offered — "we've left".
    expect(find.text('handler_phase.milestone_depart_go'), findsOneWidget);
    // The milestones for later phases are NOT on screen. Offering all four at
    // once is precisely what made the old surface unreadable.
    expect(find.text('handler_phase.milestone_arrive_go'), findsNothing);
    expect(find.text('handler_phase.milestone_end_trip'), findsNothing);
  });

  testWidgets('the dock exposes all four tabs', (tester) async {
    await tester.pumpWidget(app(reader: (_) async => manifestWith(0)));
    await tester.pumpAndSettle();

    expect(dockTab(Icons.how_to_reg_rounded), findsOneWidget);
    expect(dockTab(Icons.account_balance_wallet_rounded), findsOneWidget);
    expect(dockTab(Icons.grid_view_rounded), findsOneWidget);
    expect(dockTab(Icons.directions_bus_filled_rounded), findsOneWidget);
  });

  // ─── The agent closing the tour ──────────────────────────────────────
  //
  // Live (2026-09-05): `handler_bus_trip_state` held one row ever — a bus
  // stamped "departed" and nothing after — so its handler saw "On the road ·
  // outbound / We've arrived" three weeks after the agent completed the tour.
  // The shell now takes the tour's status at the door and treats "completed"
  // exactly like the handler's own "Trip finished" stamp.

  /// A one-seat bus with a ₹1,200 single sofa.
  Bus seatedBus() => Bus(
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

  /// A round-trip rider seated on that sofa.
  Passenger seatedRider() => Passenger(
    id: 'p-1',
    tourId: 'tour-1',
    name: 'Rider',
    phone: '9990000000',
    assignedSeats: const [SeatAssignment(busId: 'bus-1', seatId: 'SL1')],
    requestLines: [
      RequestLine(seatType: SeatType.singleSofa, qty: 1, leg: TripType.roundTrip),
    ],
    tripType: TripType.roundTrip,
  );

  testWidgets('a completed tour opens on settling with no stamps at all', (
    tester,
  ) async {
    await tester.pumpWidget(
      app(
        reader: (_) async =>
            HandlerManifest(buses: [seatedBus()], passengers: [seatedRider()]),
        tourStatus: 'completed',
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('HANDLER_PHASE.SETTLING'), findsOneWidget);
    // No milestone is offered: the trip is over, whatever the handler stamped.
    expect(find.text('handler_phase.milestone_depart_go'), findsNothing);
    expect(find.text('handler_phase.milestone_end_trip'), findsNothing);
  });

  testWidgets('settling with fares still owing leads with what is left to collect', (
    tester,
  ) async {
    // Nothing collected from the one rider: ₹1,200 still to collect, ₹0 in
    // hand. The banner must say the former — "₹0 to hand over" over a roster
    // that still reads Owing was the live "Trip closed · All square" bug.
    await tester.pumpWidget(
      app(
        reader: (_) async =>
            HandlerManifest(buses: [seatedBus()], passengers: [seatedRider()]),
        tourStatus: 'completed',
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('handler_phase.detail_to_collect'), findsOneWidget);
  });

  testWidgets('settling with nothing in hand offers no hand-over CTA', (
    tester,
  ) async {
    await tester.pumpWidget(
      app(
        reader: (_) async =>
            HandlerManifest(buses: [seatedBus()], passengers: [seatedRider()]),
        tourStatus: 'completed',
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('handler_phase.action_settle'), findsNothing);
  });

  testWidgets('settling with cash in hand offers the hand-over CTA', (
    tester,
  ) async {
    await tester.pumpWidget(
      app(
        reader: (_) async => HandlerManifest(
          buses: [seatedBus()],
          passengers: [seatedRider()],
          collections: [
            Collection(
              tourId: 'tour-1',
              busId: 'bus-1',
              passengerId: 'p-1',
              seatId: 'SL1',
              amountDue: 1200,
              amountReceived: 1200,
            ),
          ],
        ),
        tourStatus: 'completed',
      ),
    );
    await tester.pumpAndSettle();
    // The action lives on the phase's own tab; elsewhere the banner is a
    // one-line strip that leads there.
    expect(find.text('handler_phase.action_settle'), findsNothing);
    await openMoney(tester);

    expect(find.text('handler_phase.action_settle'), findsOneWidget);
  });

  // Correctness gate: a part-paid bus must not be handed over. The live
  // render offered "Hand over cash ₹26,800" while ₹24,500 was still owed by
  // riders — a handover the next collection would immediately make short.
  testWidgets('settling with cash in hand but fares still owed offers NO hand-over', (
    tester,
  ) async {
    await tester.pumpWidget(
      app(
        reader: (_) async => HandlerManifest(
          buses: [seatedBus()],
          passengers: [seatedRider()],
          collections: [
            Collection(
              tourId: 'tour-1',
              busId: 'bus-1',
              passengerId: 'p-1',
              seatId: 'SL1',
              amountDue: 1200,
              amountReceived: 600,
            ),
          ],
        ),
        tourStatus: 'completed',
      ),
    );
    await tester.pumpAndSettle();
    await openMoney(tester);

    expect(find.text('HANDLER_PHASE.SETTLING'), findsOneWidget);
    expect(find.text('handler_phase.action_settle'), findsNothing);
  });

  group('settleOffered', () {
    test('requires settling, cash in hand, and nothing left to collect', () {
      expect(
        settleOffered(
          phase: HandlerPhase.settling,
          toCollect: 0,
          outstanding: 26800,
        ),
        isTrue,
      );
      // The live bug: ₹24,500 still owed.
      expect(
        settleOffered(
          phase: HandlerPhase.settling,
          toCollect: 24500,
          outstanding: 26800,
        ),
        isFalse,
      );
      // Sub-paisa float dust is "nothing owed", not a block.
      expect(
        settleOffered(
          phase: HandlerPhase.settling,
          toCollect: 0.001,
          outstanding: 26800,
        ),
        isTrue,
      );
      expect(
        settleOffered(phase: HandlerPhase.settling, toCollect: 0, outstanding: 0),
        isFalse,
      );
      expect(
        settleOffered(
          phase: HandlerPhase.enRouteRet,
          toCollect: 0,
          outstanding: 26800,
        ),
        isFalse,
      );
    });
  });

  // ─── UPI claims on the collect list ──────────────────────────────────
  //
  // A rider who sent a UPI advance and is still waiting on the agent's check
  // shows as plain "Owing" on the Money tab, so the handler walks up and asks
  // for the full fare. The row now carries the claim.

  testWidgets('a rider with a pending UPI claim says so on their money row', (
    tester,
  ) async {
    await tester.pumpWidget(
      app(
        reader: (_) async =>
            HandlerManifest(buses: [seatedBus()], passengers: [seatedRider()]),
      ),
    );
    await tester.pumpAndSettle();
    Get.find<HandlerController>(tag: 'handler-req-1').claims.value = [
      PaymentClaim(
        id: 'c-1',
        tourId: 'tour-1',
        passengerId: 'p-1',
        amountRupees: 1200,
        status: PaymentClaimStatus.pending,
        claimedAt: DateTime(2026, 9, 3),
      ),
    ];
    await openMoney(tester);

    expect(find.text('handler_chart.upi_claim_row'), findsOneWidget);
  });

  // ─── Duplicate collections ───────────────────────────────────────────
  //
  // The chart resolved a rider's collection by the (passenger, bus, SEAT)
  // triple, which is also the DB's unique index. A rider who paid on one seat
  // and later sat in another therefore missed, was handed a fresh uuid, and the
  // insert did not collide — a SECOND row, and their cash folded twice by every
  // money figure on both the handler's board and the agent's. The rule that
  // fixes it lives in `collection_seat_resolver.dart`; this locks the WIRING —
  // that the controller's own lookup goes through it.

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
      app(
        reader: (_) async => HandlerManifest(
          buses: [bus],
          passengers: [rider],
          collections: [stranded],
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Reach the chart the way a handler does — one tap on the dock.
    await tester.tap(dockTab(Icons.grid_view_rounded));
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
    // "received" field is the tell that the lookup missed and is about to write
    // a second row: saving would then bank ₹900 plus whatever is typed here as
    // two rows of real cash.
    expect(find.text('900'), findsOneWidget);
  });
}
