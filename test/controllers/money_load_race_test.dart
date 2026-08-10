import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:occubusbooking/controllers/money_controller.dart';
import 'package:occubusbooking/services/sync_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(Get.reset);

  test('stale loadForTour for tour A does not overwrite a newer load for B',
      () async {
    final sync = _GatedTourSync();
    Get.put<SyncService>(sync);
    final money = MoneyController();

    final first = money.loadForTour('tA');
    await pumpEventQueue();
    // Second load starts while first is gated.
    final second = money.loadForTour('tB');
    await pumpEventQueue();

    sync.release('tA');
    await first;
    // B still in flight — board must not hold A's rows after A completes late.
    expect(money.loadedTourId, 'tB');
    expect(
      money.collections.where((c) => c.tourId == 'tA'),
      isEmpty,
      reason: 'stale A must not commit after B became the loaded tour',
    );

    sync.release('tB');
    await second;
    expect(money.loadedTourId, 'tB');
  });

  test('concurrent loadForTour for the same tour coalesces to one fetch',
      () async {
    final sync = _CountingSync();
    Get.put<SyncService>(sync);
    final money = MoneyController();

    await Future.wait([
      money.loadForTour('t1'),
      money.loadForTour('t1'),
      money.loadForTour('t1'),
    ]);

    expect(sync.collectionFetches, 1);
  });
}

class _CountingSync extends SyncService {
  var collectionFetches = 0;

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
  }) async {
    if (table == 'collections') collectionFetches++;
    await Future<void>.delayed(Duration.zero);
    return (rows: const <Map<String, dynamic>>[], failed: false, error: null);
  }

  @override
  Future<void> invalidateCache(String key) async {}
}

/// Per-tour gate: first smartFetch for each tour waits until [release].
class _GatedTourSync extends SyncService {
  final _gates = <String, Completer<void>>{};

  void release(String tourId) {
    final g = _gates.putIfAbsent(tourId, Completer<void>.new);
    if (!g.isCompleted) g.complete();
  }

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
  }) async {
    final tourId = filters?['tour_id'] ?? 'unknown';
    final gate = _gates.putIfAbsent(tourId, Completer<void>.new);
    await gate.future;
    if (table != 'collections') {
      return (rows: const <Map<String, dynamic>>[], failed: false, error: null);
    }
    return (
      rows: [
        {
          'id': 'c-$tourId',
          'tour_id': tourId,
          'bus_id': 'b1',
          'passenger_id': 'p1',
          'seat_id': 's1',
          'amount_due': 100.0,
          'amount_received': 100.0,
          'amount_refunded': 0.0,
        },
      ],
      failed: false,
      error: null,
    );
  }

  @override
  Future<void> invalidateCache(String key) async {}
}
