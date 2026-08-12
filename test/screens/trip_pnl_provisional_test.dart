import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:occubusbooking/controllers/money_controller.dart';
import 'package:occubusbooking/controllers/tour_controller.dart';
import 'package:occubusbooking/models/bus_details.dart';
import 'package:occubusbooking/models/passenger.dart';
import 'package:occubusbooking/models/seat_assignment.dart';
import 'package:occubusbooking/models/tour.dart';
import 'package:occubusbooking/models/tour_status.dart';
import 'package:occubusbooking/screens/trip_pnl_screen.dart';
import 'package:occubusbooking/services/ledger_money_source.dart';
import 'package:occubusbooking/services/sync_service.dart';

/// EasyLocalization is not initialised in tests, so `tr()` renders the raw key
/// — which is exactly what these assertions read.

Tour _tour({
  TourStatus status = TourStatus.assigning,
  double bus2Rent = 0,
}) =>
    Tour(
      id: 't1',
      title: 'Shravan Sud Bij',
      fromCity: 'Surat',
      toCity: 'Bheda',
      departureDate: DateTime(2026, 8, 13),
      pricePerSeat: 1500,
      status: status,
      buses: [
        Bus(id: 'b1', name: 'shivkamal-1', busPrice: 50000),
        Bus(id: 'b2', name: 'shivkamal-2', busPrice: bus2Rent),
      ],
      passengers: [
        Passenger(
          id: 'p1',
          tourId: 't1',
          name: 'A',
          phone: '999',
          assignedSeats: const [SeatAssignment(busId: 'b1', seatId: 'L1')],
        ),
        Passenger(
          id: 'p2',
          tourId: 't1',
          name: 'B',
          phone: '888',
          assignedSeats: const [SeatAssignment(busId: 'b2', seatId: 'L1')],
        ),
      ],
    );

/// ₹55,000 billed per bus against a ₹50,000-ish rent — the real trip's shape,
/// so the billed net stays positive and the assertions are about the FRAMING
/// of a profit rather than about a loss.
const _billedMinor = 5500000;

Map<String, dynamic> _rollup(String busId, int rentMinor, int collectedMinor) =>
    {
      'tour_id': 't1',
      'bus_id': busId,
      'outstanding_handover_minor': 0,
      'billed_minor': _billedMinor,
      'income_minor': 0,
      'ground_expenses_minor': 0,
      'rent_minor': rentMinor,
      'owner_unpaid_minor': rentMinor,
      'collected_minor': collectedMinor,
      'handed_over_minor': 0,
      'to_collect_minor': _billedMinor - collectedMinor,
      'to_return_minor': 0,
    };

Future<void> _pump(
  WidgetTester tester, {
  required Tour tour,
  int collectedMinor = 0,
}) async {
  // Tall surface so the whole list (hero + handler cards + bus cards) lays out
  // in one pass — off-screen ListView children are never built, and the per-bus
  // rows sit well below the fold on a phone-sized viewport.
  tester.view.physicalSize = const Size(1200, 4000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  Get.put<SyncService>(_EmptySync());
  final tours = _InertTours();
  Get.put<TourController>(tours);
  tours.tours.assignAll([tour]);

  final ledger = LedgerMoneySource();
  ledger.debugFetchBusRows = (_) async => [
        _rollup('b1', 5000000, collectedMinor),
        _rollup('b2', (tour.buses[1].busPrice * 100).round(), 0),
      ];
  ledger.debugFetchRiderRows = (_) async => [];
  Get.put<MoneyController>(MoneyController(ledgerSource: ledger));

  await tester.pumpWidget(
    GetMaterialApp(
      theme: ThemeData(brightness: Brightness.dark),
      home: const TripPnlScreen(tourId: 't1'),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  tearDown(Get.reset);

  testWidgets(
    'headline reads as projected, not profit, before the trip earns anything',
    (tester) async {
      await _pump(tester, tour: _tour(bus2Rent: 48000));

      expect(find.text('trip_pnl.net_projected'), findsOneWidget);
      expect(find.text('trip_pnl.net_profit'), findsNothing);
      // The basis caveat must say WHY, not just relabel the number.
      expect(find.text('trip_pnl.projected_note'), findsOneWidget);
    },
  );

  testWidgets('a completed, collected trip still headlines a real profit',
      (tester) async {
    await _pump(
      tester,
      tour: _tour(status: TourStatus.completed, bus2Rent: 48000),
      collectedMinor: _billedMinor,
    );

    expect(find.text('trip_pnl.net_profit'), findsOneWidget);
    expect(find.text('trip_pnl.net_projected'), findsNothing);
    expect(find.text('trip_pnl.projected_note'), findsNothing);
  });

  testWidgets('warns on the hero when a bus has no rent recorded',
      (tester) async {
    await _pump(tester, tour: _tour()); // bus 2 rent left at 0

    expect(find.text('trip_pnl.rent_missing_one'), findsOneWidget);
  });

  testWidgets('no rent warning once every bus has a rent', (tester) async {
    await _pump(tester, tour: _tour(bus2Rent: 48000));

    expect(find.text('trip_pnl.rent_missing_one'), findsNothing);
  });

  testWidgets("a bus row says its rent is unset rather than showing '₹0'",
      (tester) async {
    await _pump(tester, tour: _tour());

    expect(find.text('trip_pnl.rent_not_set'), findsOneWidget);
  });
}

class _InertTours extends TourController {
  @override
  // ignore: must_call_super
  void onInit() {}
}

class _EmptySync extends SyncService {
  @override
  // ignore: must_call_super
  void onInit() {}

  @override
  Future<({List<Map<String, dynamic>> rows, bool failed, String? error})>
      smartFetch({
    required String table,
    required String cacheKey,
    String? select,
    Map<String, String>? filters,
    String? orderBy,
    int maxAge = 300000,
  }) async =>
          (rows: const <Map<String, dynamic>>[], failed: false, error: null);
}
