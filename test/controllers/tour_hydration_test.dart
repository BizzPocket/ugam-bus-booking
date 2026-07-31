import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:occubusbooking/controllers/tour_controller.dart';
import 'package:occubusbooking/models/tour.dart';
import 'package:occubusbooking/models/tour_status.dart';
import 'package:occubusbooking/services/sync_service.dart';

/// Behavioural tests for on-demand roster hydration — the change that makes
/// cold start viable on 2G.
///
/// Cold start fetches rosters for RUNNING tours only. Measured through a
/// bandwidth-throttled socket with the real gzipped payloads:
///   every tour hydrated → 107,677 B → 43.1s on GPRS, 10.0s on EDGE
///   running tours only  →  10,471 B →  4.0s on GPRS,  1.0s on EDGE
/// against a 12s per-read budget. The EDGE case before scoping lands at ~12.0s
/// once handshake is added — a coin flip, which is exactly why the app felt
/// unreliable rather than cleanly broken.
///
/// The risk that buys is an ARCHIVED tour arriving with an empty roster. These
/// tests pin the behaviour that prevents it.
class _FakeSync extends SyncService {
  _FakeSync({this.failTimes = 0});

  int calls = 0;
  int failTimes;
  final List<List<String>> requested = [];

  /// Gate to hold a request open, so a race can be constructed deterministically.
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
    calls++;
    requested.add(List.of(tourIds));
    if (gate != null) await gate!.future;
    if (failTimes > 0) {
      failTimes--;
      throw Exception('network down');
    }
    return (
      passengers: [
        {
          'id': 'p1',
          'tour_id': tourIds.first,
          'name': 'Ramesh',
          'phone': '+919876543210',
        },
        {
          'id': 'p2',
          'tour_id': tourIds.first,
          'name': 'Cancelled Rider',
          'phone': '+919876543211',
          'cancelled_at': '2026-07-01T00:00:00Z',
        },
      ],
      buses: <Map<String, dynamic>>[],
      groups: <Map<String, dynamic>>[],
    );
  }
}

Tour _tour(String id, TourStatus status) => Tour(
      id: id,
      title: 'Tour $id',
      fromCity: 'Ahmedabad',
      toCity: 'Ambaji',
      departureDate: DateTime(2026, 8, 10),
      status: status,
      pricePerSeat: 1500,
    );

void main() {
  late _FakeSync sync;
  late TourController ctrl;

  setUp(() {
    Get.reset();
    sync = _FakeSync();
    Get.put<SyncService>(sync);
    ctrl = TourController();
    ctrl.tours.assignAll([
      _tour('archived', TourStatus.completed),
      _tour('running', TourStatus.locked),
    ]);
  });

  tearDown(Get.reset);

  test('an un-hydrated archived tour reports NOT hydrated', () {
    expect(ctrl.isTourHydrated('archived'), isFalse);
  });

  test('opening an archived tour fetches exactly that tour, once', () async {
    await ctrl.ensureTourHydrated('archived');

    expect(sync.calls, 1);
    expect(sync.requested.single, ['archived']);
    expect(ctrl.isTourHydrated('archived'), isTrue);
    expect(ctrl.getTour('archived')!.passengers, hasLength(1));
    expect(ctrl.getTour('archived')!.passengers.single.name, 'Ramesh');
  });

  test('a customer-cancelled passenger never enters the hydrated roster',
      () async {
    // Must mirror the cold-start read, which drops cancelled rows. If these
    // two paths disagree, an archived tour shows a different roster than a
    // running one — and every capacity/money figure derived from it is wrong.
    await ctrl.ensureTourHydrated('archived');
    final names =
        ctrl.getTour('archived')!.passengers.map((p) => p.name).toList();
    expect(names, isNot(contains('Cancelled Rider')));
  });

  test('re-opening an already hydrated tour issues NO second request',
      () async {
    await ctrl.ensureTourHydrated('archived');
    await ctrl.ensureTourHydrated('archived');
    await ctrl.ensureTourHydrated('archived');
    expect(sync.calls, 1, reason: 'each re-open costs a 2G round trip');
  });

  test('concurrent opens share ONE in-flight request', () async {
    sync.gate = Completer<void>();

    final a = ctrl.ensureTourHydrated('archived');
    final b = ctrl.ensureTourHydrated('archived');
    final c = ctrl.ensureTourHydrated('archived');

    sync.gate!.complete();
    await Future.wait([a, b, c]);

    expect(sync.calls, 1,
        reason: 'three widgets opening at once must not race three requests '
            'down a 2G link');
    expect(ctrl.isTourHydrated('archived'), isTrue);
  });

  test('a FAILED hydration does not mark the tour hydrated — it retries',
      () async {
    final failing = _FakeSync(failTimes: 1);
    Get.reset();
    Get.put<SyncService>(failing);
    final c2 = TourController();
    c2.tours.assignAll([_tour('archived', TourStatus.completed)]);

    await expectLater(c2.ensureTourHydrated('archived'), throwsException);
    expect(c2.isTourHydrated('archived'), isFalse,
        reason: 'marking it hydrated after a failure would show an empty '
            'roster forever, with no way to recover');

    // Second open succeeds and fills the roster.
    await c2.ensureTourHydrated('archived');
    expect(c2.isTourHydrated('archived'), isTrue);
    expect(c2.getTour('archived')!.passengers, hasLength(1));
  });

  test('hydrating an unknown tour id is a no-op, not a crash', () async {
    await ctrl.ensureTourHydrated('does-not-exist');
    expect(sync.calls, 0);
  });

  test('empty tour id is a no-op', () async {
    await ctrl.ensureTourHydrated('');
    expect(sync.calls, 0);
  });
}
