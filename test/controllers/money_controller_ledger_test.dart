import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:occubusbooking/controllers/money_controller.dart';
import 'package:occubusbooking/controllers/tour_controller.dart';
import 'package:occubusbooking/models/bus_details.dart';
import 'package:occubusbooking/models/passenger.dart';
import 'package:occubusbooking/models/seat_assignment.dart';
import 'package:occubusbooking/models/tour.dart';
import 'package:occubusbooking/models/tour_status.dart';
import 'package:occubusbooking/services/ledger_money_source.dart';
import 'package:occubusbooking/services/sync_service.dart';

void main() {
  test('summaryForBus prefers ledger rollup when ledger load succeeds', () async {
    addTearDown(Get.reset);

    final sync = _EmptySync();
    Get.put<SyncService>(sync);

    final tours = _InertTours();
    Get.put<TourController>(tours);
    tours.tours.assignAll([
      Tour(
        id: 't1',
        title: 'Goa',
        fromCity: 'Surat',
        toCity: 'Goa',
        departureDate: DateTime(2026, 8, 1),
        pricePerSeat: 1000,
        status: TourStatus.locked,
        buses: [
          Bus(id: 'b1', name: 'Bus 1', busPrice: 500),
        ],
        passengers: [
          Passenger(
            id: 'p1',
            tourId: 't1',
            name: 'A',
            phone: '999',
            assignedSeats: const [
              SeatAssignment(busId: 'b1', seatId: 'L1'),
            ],
          ),
        ],
      ),
    ]);

    final ledger = LedgerMoneySource();
    ledger.debugFetchBusRows = (_) async => [
          {
            'tour_id': 't1',
            'bus_id': 'b1',
            'outstanding_handover_minor': 150000,
            'billed_minor': 200000,
            'income_minor': 0,
            'ground_expenses_minor': 0,
            'rent_minor': 50000,
            'owner_unpaid_minor': 50000,
            'collected_minor': 200000,
            'handed_over_minor': 0,
            'to_collect_minor': 0,
            'to_return_minor': 0,
          },
        ];
    ledger.debugFetchRiderRows = (_) async => [
          {'tour_id': 't1', 'passenger_id': 'p1', 'owes_minor': 0},
        ];

    final money = MoneyController(ledgerSource: ledger);
    await money.loadForTour('t1');

    expect(money.loadFailed.value, isFalse);
    final s = money.summaryForBus('b1');
    expect(s.collected, 2000);
    expect(s.busRent, 500);
    expect(s.revenueBilled, 2000);
    expect(s.outstandingHandover, closeTo(2000, 0.01));
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
