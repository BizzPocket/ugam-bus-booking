import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:occubusbooking/controllers/auth_controller.dart';
import 'package:occubusbooking/controllers/tour_controller.dart';
import 'package:occubusbooking/services/sync_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Anonymous viewer with no `onInit` and both restore gates open: no cache
/// scope, no owner filter — the smallest auth the load pipeline accepts.
class _Anon extends AuthController {
  @override
  // ignore: must_call_super
  void onInit() {}

  @override
  Future<void> get whenRestored => Future.value();

  @override
  Future<void> get whenPrefsRestored => Future.value();
}

/// Counts tour-header reads and can hold one open, so "a reconnect while a
/// load is still on the wire" can be built deterministically.
class _CountingSync extends SyncService {
  int headerCalls = 0;
  Completer<void>? gate;

  @override
  // ignore: must_call_super
  void onInit() {}

  @override
  Future<List<Map<String, dynamic>>> fetchTourRows({
    Map<String, String>? filters,
    String? orderBy,
  }) async {
    headerCalls++;
    final g = gate;
    if (g != null) await g.future;
    return [
      {
        'id': 't1',
        'title': 'Ambaji',
        'from_city': 'Surat',
        'to_city': 'Ambaji',
        'departure_date': '2027-07-01',
        'price_per_seat': 1200,
        'status': 'assigning',
      },
    ];
  }

  @override
  Future<
      ({
        List<Map<String, dynamic>> passengers,
        List<Map<String, dynamic>> buses,
        List<Map<String, dynamic>> groups,
      })> fetchRelationsForTours(List<String> tourIds) async => (
        passengers: const <Map<String, dynamic>>[],
        buses: const <Map<String, dynamic>>[],
        groups: const <Map<String, dynamic>>[],
      );
}

/// A signal flapping on a moving bus fires an online edge (or a realtime
/// rejoin) every second or two. Each one used to start a fresh load that
/// SUPERSEDED the one in flight, so on a bad enough link no load ever landed.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final originalDelay = tourReconnectRefreshDelay;
  late _CountingSync sync;
  late TourController ctrl;

  setUp(() {
    Get.reset();
    SharedPreferences.setMockInitialValues({});
    tourReconnectRefreshDelay = const Duration(milliseconds: 20);
    sync = _CountingSync();
    Get.put<SyncService>(sync);
    Get.put<AuthController>(_Anon());
    ctrl = TourController();
  });

  tearDown(() {
    tourReconnectRefreshDelay = originalDelay;
    Get.reset();
  });

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 80));

  test('a burst of reconnect edges triggers exactly ONE refetch', () async {
    for (var i = 0; i < 5; i++) {
      ctrl.scheduleReconnectRefresh();
    }
    await settle();

    expect(sync.headerCalls, 1);
    expect(ctrl.tours, hasLength(1));
  });

  test('reconnects during an in-flight load queue ONE follow-up, never '
      'supersede it', () async {
    sync.gate = Completer<void>();
    ctrl.scheduleReconnectRefresh();
    await settle();
    expect(sync.headerCalls, 1, reason: 'first load is on the wire');

    // Three more flaps while it is still loading.
    for (var i = 0; i < 3; i++) {
      ctrl.scheduleReconnectRefresh();
      await settle();
    }
    expect(sync.headerCalls, 1,
        reason: 'a flap must not restart the load that is about to land');

    final gate = sync.gate!;
    sync.gate = null;
    gate.complete();
    await settle();

    expect(sync.headerCalls, 2,
        reason: 'changes made during the first load are picked up once');
    expect(ctrl.tours, hasLength(1));
    expect(ctrl.hasError.value, isFalse);
  });
}
