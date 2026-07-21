import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:occubusbooking/controllers/money_controller.dart';
import 'package:occubusbooking/services/sync_service.dart';

void main() {
  test('outstandingHandoverFor reads the per-tour snapshot cache', () {
    final c = MoneyController();
    // No snapshot yet → null (distinct from 0 "settled").
    expect(c.outstandingHandoverFor('t9'), isNull);
    c.settlementByTour['t9'] = 4200.0;
    expect(c.outstandingHandoverFor('t9'), 4200.0);
  });

  test(
    'switching the loaded tour snapshots the OUTGOING tour so it keeps its '
    'settlement alert after navigating away',
    () async {
      addTearDown(Get.reset);
      // Tour A: one passenger fully collected (₹500), nothing handed over
      // yet → a genuine ₹500 outstanding handover.
      final sync = _ScriptedSync({
        'collections_tA': [
          {
            'id': 'c1',
            'tour_id': 'tA',
            'bus_id': 'b1',
            'passenger_id': 'p1',
            'seat_id': 's1',
            'amount_due': 500.0,
            'amount_received': 500.0,
            'amount_refunded': 0.0,
          },
        ],
      });
      Get.put<SyncService>(sync);
      final money = MoneyController();

      await money.loadForTour('tA');
      expect(money.loadedTourId, 'tA');
      expect(money.outstandingHandoverFor('tA'), 500.0);
      // Still the loaded tour — read live, no snapshot needed yet.
      expect(money.settlementByTour.containsKey('tA'), isFalse);

      // Simulate the dashboard hero moving on to another tour.
      await money.loadForTour('tB');

      expect(money.loadedTourId, 'tB');
      // A is no longer loaded, but its outstanding handover must have been
      // captured into the snapshot cache at the moment of the switch —
      // otherwise it silently reads as "unknown" until an unrelated event
      // re-runs the settlement pass (the AL-3 gap this closes).
      expect(money.settlementByTour['tA'], 500.0);
      expect(money.outstandingHandoverFor('tA'), 500.0);
    },
  );
}

/// SyncService whose reads are scripted by cache key (each money table's key
/// already encodes the tour id, e.g. `collections_tA`) so a test can hand
/// back specific rows for one tour while every other table/tour reads empty.
/// [onInit] is a no-op so it never starts the real connectivity listener.
class _ScriptedSync extends SyncService {
  _ScriptedSync(this._rowsByCacheKey);

  final Map<String, List<Map<String, dynamic>>> _rowsByCacheKey;

  @override
  // ignore: must_call_super
  void onInit() {}

  @override
  Future<({List<Map<String, dynamic>> rows, bool failed})> smartFetch({
    required String table,
    required String cacheKey,
    String? select,
    Map<String, String>? filters,
    String? orderBy,
    int maxAge = 300000,
  }) async {
    return (rows: _rowsByCacheKey[cacheKey] ?? const [], failed: false);
  }

  @override
  Future<void> invalidateCache(String key) async {}
}
