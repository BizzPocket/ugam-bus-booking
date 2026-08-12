import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:occubusbooking/controllers/money_controller.dart';
import 'package:occubusbooking/design/components/ugam_caveat.dart';
import 'package:occubusbooking/controllers/tour_controller.dart';
import 'package:occubusbooking/models/bus_details.dart';
import 'package:occubusbooking/models/bus_type.dart';
import 'package:occubusbooking/models/passenger.dart';
import 'package:occubusbooking/models/seat_assignment.dart';
import 'package:occubusbooking/models/seat_layout.dart';
import 'package:occubusbooking/models/tour.dart';
import 'package:occubusbooking/models/tour_status.dart';
import 'package:occubusbooking/screens/tour_money_board_screen.dart';
import 'package:occubusbooking/services/ledger_money_source.dart';
import 'package:occubusbooking/services/sync_service.dart';

/// `tr()` renders raw keys here (EasyLocalization is not initialised), which is
/// what these assertions read.

const _billedMinor = 5500000; // ₹55,000 per bus

Bus _bus(String id, String name, double rent) => Bus(
      id: id,
      name: name,
      busType: 'Sleeper',
      busPrice: rent,
      layout: BusLayout.generate(busType: BusType.sleeper, totalSeats: 30),
    );

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
        _bus('b1', 'shivkamal-1', 50000),
        _bus('b2', 'shivkamal-2', bus2Rent),
      ],
      passengers: [
        Passenger(
          id: 'p1',
          tourId: 't1',
          name: 'A',
          phone: '999',
          assignedSeats: const [SeatAssignment(busId: 'b1', seatId: 'L1')],
        ),
      ],
    );

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
      home: const TourMoneyBoardScreen(tourId: 't1'),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  tearDown(Get.reset);

  testWidgets('entry card says projected, not "trip is in profit"',
      (tester) async {
    await _pump(tester, tour: _tour(bus2Rent: 48000));

    expect(find.text('tour_money_board.trip_projected_profit'), findsOneWidget);
    expect(find.text('tour_money_board.trip_in_profit'), findsNothing);
  });

  testWidgets('entry card keeps "trip is in profit" once the trip is done',
      (tester) async {
    await _pump(
      tester,
      tour: _tour(status: TourStatus.completed, bus2Rent: 48000),
      collectedMinor: _billedMinor,
    );

    expect(find.text('tour_money_board.trip_in_profit'), findsOneWidget);
    expect(find.text('tour_money_board.trip_projected_profit'), findsNothing);
  });

  testWidgets('entry card warns when a bus has no rent recorded',
      (tester) async {
    await _pump(tester, tour: _tour()); // bus 2 rent left at 0

    expect(find.text('trip_pnl.rent_missing_one'), findsOneWidget);
  });

  testWidgets('the caveat is a contained strip, not loose coloured prose',
      (tester) async {
    await _pump(tester, tour: _tour());

    expect(find.byType(UgamCaveat), findsOneWidget);
  });

  // Three stacked meta lines under the figure buried the one that matters.
  // When the number is contested, what sits INSIDE the P&L screen matters less
  // than the fact the number is wrong — the chevron already promises detail.
  testWidgets('the "per bus & per handler" line gives way to a caveat',
      (tester) async {
    await _pump(tester, tour: _tour());

    expect(find.text('trip_pnl.entry_sub'), findsNothing);
  });

  testWidgets('the "per bus & per handler" line stays when nothing is wrong',
      (tester) async {
    await _pump(tester, tour: _tour(bus2Rent: 48000));

    expect(find.text('trip_pnl.entry_sub'), findsOneWidget);
  });

  // The capsule reports OUTSTANDING HANDOVER, which is legitimately ₹0 here
  // (nothing collected, and the only cost is rent the admin settles). Saying
  // "all settled" beside two buses still owing their full fares reads as
  // "nothing left to do" — the wording has to name what is settled.
  testWidgets('totals capsule scopes its settled label to the handover',
      (tester) async {
    await _pump(tester, tour: _tour(bus2Rent: 48000));

    expect(find.text('tour_money_board.handover_settled'), findsOneWidget);
    expect(find.text('tour_money_board.all_settled'), findsNothing);
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
