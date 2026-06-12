import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:occubusbooking/controllers/tour_controller.dart';
import 'package:occubusbooking/models/bus_details.dart';
import 'package:occubusbooking/models/bus_type.dart';
import 'package:occubusbooking/models/passenger.dart';
import 'package:occubusbooking/models/request_line.dart';
import 'package:occubusbooking/models/seat_assignment.dart';
import 'package:occubusbooking/models/seat_layout.dart';
import 'package:occubusbooking/models/seat_type.dart';
import 'package:occubusbooking/models/tour.dart';
import 'package:occubusbooking/services/sync_service.dart';

/// Records every server write so a test can assert HOW MANY rows a controller
/// method touches — without any Supabase/connectivity plugin. [onInit] is
/// overridden so registering it never starts the real connectivity listener.
class _RecordingSync extends SyncService {
  final List<String> updates = <String>[]; // "table:id"
  final List<String> inserts = <String>[];
  final List<Map<String, dynamic>> swaps = <Map<String, dynamic>>[];
  final List<Map<String, dynamic>> applies = <Map<String, dynamic>>[];

  /// When true, the atomic RPCs throw [RpcUnavailableException] to simulate the
  /// migration not being deployed — exercising the legacy fallback path.
  bool rpcUnavailable = false;

  @override
  // ignore: must_call_super
  void onInit() {}

  @override
  Future<void> swapPassengerSeats({
    required String passengerAId,
    required List<Map<String, dynamic>> seatsA,
    required String passengerBId,
    required List<Map<String, dynamic>> seatsB,
  }) async {
    if (rpcUnavailable) throw RpcUnavailableException('swap_passenger_seats');
    swaps.add({'a': passengerAId, 'b': passengerBId});
  }

  @override
  Future<void> applySeatAssignments({
    required String tourId,
    required List<Map<String, dynamic>> assignments,
  }) async {
    if (rpcUnavailable) throw RpcUnavailableException('apply_seat_assignments');
    applies.add({'tourId': tourId, 'assignments': assignments});
  }

  @override
  Future<void> smartUpdate({
    required String table,
    required String entityId,
    required Map<String, dynamic> data,
  }) async {
    updates.add('$table:$entityId');
  }

  @override
  Future<void> smartInsert({
    required String table,
    required String entityId,
    required Map<String, dynamic> data,
    String? cacheKey,
  }) async {
    inserts.add('$table:$entityId');
  }

  @override
  Future<void> invalidateCache(String key) async {}
}

Passenger _p(String id) =>
    Passenger(id: id, tourId: 't1', name: id, phone: '+910000000000');

Passenger _seated(String id, String seatId) => Passenger(
      id: id,
      tourId: 't1',
      name: id,
      phone: '+910000000000',
      assignedSeats: [SeatAssignment(busId: 'b1', seatId: seatId)],
    );

Passenger _requesting(String id) => Passenger(
      id: id,
      tourId: 't1',
      name: id,
      phone: '+910000000000',
      requestLines: [RequestLine(seatType: SeatType.singleSofa, qty: 1)],
    );

Bus _bus(String id) => Bus(
      id: id,
      name: 'Bus 1',
      busType: 'Sleeper',
      layout: BusLayout.generate(busType: BusType.sleeper, totalSeats: 30),
    );

Tour _tourWith(
  List<Passenger> passengers, {
  String? handlerId,
  List<Bus> buses = const [],
}) =>
    Tour(
      id: 't1',
      title: 'Dwarka Yatra',
      fromCity: 'Surat',
      toCity: 'Dwarka',
      departureDate: DateTime(2026, 7, 1),
      pricePerSeat: 1200,
      handlerId: handlerId,
      buses: buses,
      passengers: passengers,
    );

void main() {
  tearDown(Get.reset);

  test('setHandler writes the tour row + only the changed passenger (no prior '
      'handler)', () async {
    final sync = _RecordingSync();
    Get.put<SyncService>(sync);
    final ctrl = TourController();
    ctrl.tours.assignAll([
      _tourWith([_p('p1'), _p('p2'), _p('p3'), _p('p4'), _p('p5')]),
    ]);

    await ctrl.setHandler('t1', 'p3');

    // Exactly one tour-row write (authoritative handlerId)...
    expect(sync.updates.where((u) => u.startsWith('tours:')).length, 1);
    // ...and only the new handler's passenger row — NOT all five.
    final pax = sync.updates.where((u) => u.startsWith('passengers:')).toList();
    expect(pax, ['passengers:p3']);
  });

  test('setHandler re-point writes only the old + new handler rows', () async {
    final sync = _RecordingSync();
    Get.put<SyncService>(sync);
    final ctrl = TourController();
    ctrl.tours.assignAll([
      _tourWith(
        [_p('p1'), _p('p2'), _p('p3'), _p('p4'), _p('p5')],
        handlerId: 'p3',
      )..passengers[2] = _p('p3').copyWith(isHandler: true),
    ]);

    await ctrl.setHandler('t1', 'p5');

    final pax = sync.updates.where((u) => u.startsWith('passengers:')).toList();
    // The replaced handler (p3 → false) and the new one (p5 → true): 2 rows,
    // not the whole manifest.
    expect(pax.toSet(), {'passengers:p3', 'passengers:p5'});
    expect(pax.length, 2);
  });

  test('setHandler on a 60-passenger tour still writes at most 2 passenger rows',
      () async {
    final sync = _RecordingSync();
    Get.put<SyncService>(sync);
    final ctrl = TourController();
    ctrl.tours.assignAll([
      _tourWith(List.generate(60, (i) => _p('p$i'))),
    ]);

    await ctrl.setHandler('t1', 'p42');

    expect(
      sync.updates.where((u) => u.startsWith('passengers:')).length,
      lessThanOrEqualTo(2),
    );
  });

  test('swapSeats goes through the atomic RPC (no per-row writes)', () async {
    final sync = _RecordingSync();
    Get.put<SyncService>(sync);
    final ctrl = TourController();
    ctrl.tours.assignAll([
      _tourWith([_seated('p1', 'L1'), _seated('p2', 'L2')], buses: [_bus('b1')]),
    ]);

    await ctrl.swapSeats(
      tourId: 't1',
      busId: 'b1',
      passengerAId: 'p1',
      seatAId: 'L1',
      passengerBId: 'p2',
      seatBId: 'L2',
    );

    expect(sync.swaps, [
      {'a': 'p1', 'b': 'p2'}
    ]);
    expect(sync.updates.where((u) => u.startsWith('passengers:')), isEmpty);
  });

  test('swapSeats falls back to two writes when the RPC is not deployed',
      () async {
    final sync = _RecordingSync()..rpcUnavailable = true;
    Get.put<SyncService>(sync);
    final ctrl = TourController();
    ctrl.tours.assignAll([
      _tourWith([_seated('p1', 'L1'), _seated('p2', 'L2')], buses: [_bus('b1')]),
    ]);

    await ctrl.swapSeats(
      tourId: 't1',
      busId: 'b1',
      passengerAId: 'p1',
      seatAId: 'L1',
      passengerBId: 'p2',
      seatBId: 'L2',
    );

    expect(sync.swaps, isEmpty);
    expect(
      sync.updates.where((u) => u.startsWith('passengers:')).toSet(),
      {'passengers:p1', 'passengers:p2'},
    );
  });

  test('fillTour applies the whole plan in one atomic RPC call', () async {
    final sync = _RecordingSync();
    Get.put<SyncService>(sync);
    final ctrl = TourController();
    ctrl.tours.assignAll([
      _tourWith([_requesting('p1'), _requesting('p2')], buses: [_bus('b1')]),
    ]);

    await ctrl.fillTour('t1');

    expect(sync.applies.length, 1);
    expect((sync.applies.first['assignments'] as List).isNotEmpty, isTrue);
  });
}
