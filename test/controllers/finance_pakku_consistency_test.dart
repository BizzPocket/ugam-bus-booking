// Settings → Finance, the Trip P&L and the money board must print the SAME
// profit for the same trip. Finance used to fold `ground + rent` per bus (every
// rupee on top of the rent) while the board applied the pakku-bhadu rule
// (diesel + advances INSIDE the rent), so a pakku bus with diesel paid read as
// a bigger loss on Finance than on the trip's own P&L. Owner's rule
// 2026-10-25: every driver cost is on top of the rent, on every surface.

import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:occubusbooking/controllers/finance_controller.dart';
import 'package:occubusbooking/controllers/money_controller.dart';
import 'package:occubusbooking/controllers/tour_controller.dart';
import 'package:occubusbooking/models/bus_details.dart';
import 'package:occubusbooking/models/bus_type.dart';
import 'package:occubusbooking/models/seat_layout.dart';
import 'package:occubusbooking/models/tour.dart';
import 'package:occubusbooking/models/tour_finance.dart';
import 'package:occubusbooking/models/tour_status.dart';
import 'package:occubusbooking/services/ledger_money_source.dart';
import 'package:occubusbooking/services/sync_service.dart';

const _tourId = 't1';

void main() {
  test('one pakku bus with diesel + driver: Finance == Trip P&L == board',
      () async {
    addTearDown(Get.reset);

    // Rent 40000 (pakku). On the trip: diesel 3200, driver 5000, toll 600.
    // Collected 50000 cash, income 1000.
    //   ground (ledger)  = 3200 + 5000 + 600 = 8800
    //   bus cost         = max(40000, 3200) = 40000   (diesel inside)
    //   on top           = 8800 − 3200 = 5600         (driver + toll)
    //   trip expenses    = 45600     (old Finance fold: 8800 + 40000 = 48800)
    //   net              = 50000 + 1000 − 45600 = 5400
    //   owner still owed = 40000 − 3200 = 36800
    final expenseRows = <Map<String, dynamic>>[
      {
        'id': 'e1', 'tour_id': _tourId, 'bus_id': 'b1',
        'category': 'fuel', 'label': 'Diesel', 'amount': 3200,
      },
      {
        'id': 'e2', 'tour_id': _tourId, 'bus_id': 'b1',
        'category': 'driver', 'label': 'Driver', 'amount': 5000,
      },
      {
        'id': 'e3', 'tour_id': _tourId, 'bus_id': 'b1',
        'category': 'toll', 'label': 'Toll', 'amount': 600,
      },
    ];
    final rollupRow = <String, dynamic>{
      'tour_id': _tourId,
      'bus_id': 'b1',
      'outstanding_handover_minor': 5000000 + 100000 - 880000,
      'billed_minor': 5000000,
      'income_minor': 100000,
      'ground_expenses_minor': 880000,
      'rent_minor': 4000000,
      'owner_unpaid_minor': 4000000,
      'collected_minor': 5000000,
      'handed_over_minor': 0,
      'to_collect_minor': 0,
      'to_return_minor': 0,
    };

    Get.put<SyncService>(_StubSync({'expenses': expenseRows}));
    final tours = _InertTours();
    Get.put<TourController>(tours);
    tours.tours.assignAll([
      Tour(
        id: _tourId,
        title: 'T',
        fromCity: 'A',
        toCity: 'B',
        departureDate: DateTime(2026, 8, 21),
        pricePerSeat: 0,
        status: TourStatus.collecting,
        buses: [
          Bus(
            id: 'b1',
            name: 'b1',
            tourId: _tourId,
            busPrice: 40000,
            layout:
                BusLayout.generate(busType: BusType.seater, totalSeats: 4),
          ),
        ],
      ),
    ]);

    // ── Money board / Trip P&L (MoneyController, ledger path) ──
    final money = MoneyController(
      ledgerSource: LedgerMoneySource()
        ..debugFetchBusRows = ((_) async => [rollupRow])
        ..debugFetchRiderRows = ((_) async => const []),
    );
    await money.loadForTour(_tourId);
    final bus = money.summaryForBus('b1');
    final trip = money.tourSummary();

    // ── Settings → Finance ──
    final finance = FinanceController(
      ledgerSource: LedgerMoneySource()
        ..debugFetchAllBusRows = (() async => [rollupRow])
        ..debugFetchTourRows = (() async => const [])
        // Finance's narrow read returns only the absorbable categories.
        ..debugFetchAbsorbableRows = (() async => [
              for (final r in expenseRows)
                if (const {'fuel', 'driver', 'busOwner'}
                    .contains(r['category']))
                  r,
            ]),
    );
    await finance.load();
    final row = finance
        .financesFor(FinancePeriod.allTime)
        .singleWhere((f) => f.tourId == _tourId);

    expect(bus.expensesTotal, 45600);
    expect(bus.busMalikPayable, 36800);
    expect(trip.totalExpenses, 45600);
    expect(trip.totalNet, 5400);

    expect(row.expenses, 45600, reason: 'Finance must not stack diesel');
    expect(row.cashSoFar, 5400);
    expect(row.cashSoFar, trip.totalNet, reason: 'Finance == Trip P&L / board');
    expect(row.cashSoFar, bus.netCollected);
    expect(row.tripProfit, trip.totalNetBilled);
  });
}

class _InertTours extends TourController {
  @override
  // ignore: must_call_super
  void onInit() {}
}

class _StubSync extends SyncService {
  _StubSync(this.rows);

  final Map<String, List<Map<String, dynamic>>> rows;

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
          (
            rows: rows[table] ?? const <Map<String, dynamic>>[],
            failed: false,
            error: null,
          );

  @override
  Future<void> invalidateCache(String cacheKey) async {}
}
