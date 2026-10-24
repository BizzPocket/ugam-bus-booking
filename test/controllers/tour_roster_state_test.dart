import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:occubusbooking/controllers/tour_controller.dart';
import 'package:occubusbooking/models/tour.dart';
import 'package:occubusbooking/models/tour_status.dart';
import 'package:occubusbooking/services/sync_service.dart';

/// The 2G reality behind these: an archived tour is opened, its roster read
/// times out, and the screen has to tell "no buses" from "couldn't load".
class _FakeSync extends SyncService {
  _FakeSync({this.failRelations = 0, this.failSnapshots = 0});

  int failRelations;
  int failSnapshots;
  int relationCalls = 0;
  int snapshotCalls = 0;
  Completer<void>? gate;

  @override
  // ignore: must_call_super
  void onInit() {}

  @override
  Future<
      ({
        List<Map<String, dynamic>> passengers,
        List<Map<String, dynamic>> buses,
        List<Map<String, dynamic>> groups,
      })> fetchRelationsForTours(List<String> tourIds) async {
    relationCalls++;
    if (gate != null) await gate!.future;
    if (failRelations > 0) {
      failRelations--;
      throw TimeoutException('2G read timed out');
    }
    return (
      passengers: <Map<String, dynamic>>[],
      buses: <Map<String, dynamic>>[],
      groups: <Map<String, dynamic>>[],
    );
  }

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
    snapshotCalls++;
    if (failSnapshots > 0) {
      failSnapshots--;
      return (
        rows: const <Map<String, dynamic>>[],
        failed: true,
        error: 'timeout',
      );
    }
    return (rows: const <Map<String, dynamic>>[], failed: false, error: null);
  }
}

Tour _archived() => Tour(
      id: 'archived',
      title: 'Ambaji Yatra',
      fromCity: 'Ahmedabad',
      toCity: 'Ambaji',
      departureDate: DateTime(2026, 8, 10),
      status: TourStatus.completed,
      pricePerSeat: 1500,
    );

void main() {
  tearDown(Get.reset);

  TourController controllerWith(_FakeSync sync) {
    Get.reset();
    Get.put<SyncService>(sync);
    final ctrl = TourController();
    ctrl.tours.assignAll([_archived()]);
    return ctrl;
  }

  test('an archived tour whose roster is still on its way is LOADING, not empty',
      () async {
    final sync = _FakeSync()..gate = Completer<void>();
    final ctrl = controllerWith(sync);

    final pending = ctrl.ensureTourHydrated('archived');
    expect(ctrl.rosterStateOf('archived'), TourRosterState.loading);

    sync.gate!.complete();
    await pending;
    // Genuinely empty once the server has answered.
    expect(ctrl.rosterStateOf('archived'), TourRosterState.ready);
  });

  test('a failed roster read is FAILED (retry), and a retry recovers it',
      () async {
    final sync = _FakeSync(failRelations: 1);
    final ctrl = controllerWith(sync);

    await expectLater(ctrl.ensureTourHydrated('archived'), throwsA(anything));
    expect(ctrl.rosterStateOf('archived'), TourRosterState.failed,
        reason: 'a failed read must not read as "no buses · Add bus"');

    // The retry surface never throws, and lands on the real answer.
    await ctrl.retryTourHydration('archived');
    expect(sync.relationCalls, 2);
    expect(ctrl.rosterStateOf('archived'), TourRosterState.ready);
  });

  test('a retry in flight shows the skeleton again, not the stale failure',
      () async {
    final sync = _FakeSync(failRelations: 1);
    final ctrl = controllerWith(sync);
    await expectLater(ctrl.ensureTourHydrated('archived'), throwsA(anything));

    sync.gate = Completer<void>();
    final retry = ctrl.retryTourHydration('archived');
    expect(ctrl.rosterStateOf('archived'), TourRosterState.loading);
    sync.gate!.complete();
    await retry;
    expect(ctrl.rosterStateOf('archived'), TourRosterState.ready);
  });

  test('a failed seat-snapshot read is NOT cached — the next open reads again',
      () async {
    final sync = _FakeSync(failSnapshots: 1);
    final ctrl = controllerWith(sync);

    final first = await ctrl.loadSeatSnapshotsResult('archived');
    expect(first.failed, isTrue);
    expect(first.snapshots, isEmpty);

    final second = await ctrl.loadSeatSnapshotsResult('archived');
    expect(sync.snapshotCalls, 2,
        reason: 'the failure used to be cached as "no snapshots" for the life '
            'of the app, so the history screen never asked again');
    expect(second.failed, isFalse);

    // A SUCCESSFUL read is cached as before.
    await ctrl.loadSeatSnapshotsResult('archived');
    expect(sync.snapshotCalls, 2);
  });
}
