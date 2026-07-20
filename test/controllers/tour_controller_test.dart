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
import 'package:occubusbooking/models/tour_status.dart';
import 'package:occubusbooking/models/trip_type.dart';
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
  TourStatus status = TourStatus.collecting,
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
      status: status,
    );

void main() {
  // Some controller guards surface a toast via AppSnackBar, which reads
  // Get.context — that getter touches WidgetsBinding.instance and throws if the
  // binding isn't initialized. With the binding up, there's no navigator so the
  // toast no-ops; the guard's data behavior is what we assert here.
  TestWidgetsFlutterBinding.ensureInitialized();

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

  test('swapSeats bumps a leg-conflicting occupant off the seat, request kept',
      () async {
    final sync = _RecordingSync();
    Get.put<SyncService>(sync);
    final ctrl = TourController();
    // L1 is leg-shared: G (outbound-only) + R (return-only). F (round-trip) sits
    // on L2. Swapping G ↔ F would leave R + F on L1 → the RET leg double-books.
    // The UI guard resolves it by bumping R; here we assert swapSeats honours it.
    final g = Passenger(
      id: 'G',
      tourId: 't1',
      name: 'G',
      phone: '+910000000000',
      tripType: TripType.outboundOnly,
      assignedSeats: [SeatAssignment(busId: 'b1', seatId: 'L1')],
    );
    final r = Passenger(
      id: 'R',
      tourId: 't1',
      name: 'R',
      phone: '+910000000000',
      tripType: TripType.returnOnly,
      requestLines: [RequestLine(seatType: SeatType.singleSofa, qty: 1)],
      assignedSeats: [SeatAssignment(busId: 'b1', seatId: 'L1')],
    );
    final f = Passenger(
      id: 'F',
      tourId: 't1',
      name: 'F',
      phone: '+910000000000',
      tripType: TripType.roundTrip,
      assignedSeats: [SeatAssignment(busId: 'b1', seatId: 'L2')],
    );
    ctrl.tours.assignAll([
      _tourWith([g, r, f], buses: [_bus('b1')]),
    ]);

    await ctrl.swapSeats(
      tourId: 't1',
      busId: 'b1',
      passengerAId: 'G',
      seatAId: 'L1',
      passengerBId: 'F',
      seatBId: 'L2',
      bump: [(passengerId: 'R', busId: 'b1', seatId: 'L1')],
    );

    final tour = ctrl.tours.first;
    Passenger byId(String id) => tour.passengers.firstWhere((p) => p.id == id);
    // R is freed off L1 but keeps its request — back to the unseated pool.
    expect(byId('R').assignedSeats, isEmpty);
    expect(byId('R').requestLines, isNotEmpty);
    // The swap still completes: F lands on L1, G on L2.
    expect(byId('F').assignedSeats.single.seatId, 'L1');
    expect(byId('G').assignedSeats.single.seatId, 'L2');
    // R's freed row is persisted, alongside the atomic G/F swap.
    expect(sync.updates, contains('passengers:R'));
    expect(sync.swaps, [
      {'a': 'G', 'b': 'F'}
    ]);
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

  test('addPassenger on an OPEN tour writes the new passenger row', () async {
    final sync = _RecordingSync();
    Get.put<SyncService>(sync);
    final ctrl = TourController();
    ctrl.tours.assignAll([
      _tourWith([_p('p1')], status: TourStatus.collecting),
    ]);

    await ctrl.addPassenger('t1', _p('p2'));

    expect(sync.inserts, contains('passengers:p2'));
    expect(ctrl.getTour('t1')!.passengers.map((p) => p.id), contains('p2'));
  });

  test('addPassenger on a LOCKED tour is refused — no write, no local add',
      () async {
    final sync = _RecordingSync();
    Get.put<SyncService>(sync);
    final ctrl = TourController();
    ctrl.tours.assignAll([
      _tourWith([_p('p1')], status: TourStatus.locked),
    ]);

    await ctrl.addPassenger('t1', _p('p2'));

    // Bookings are closed once locked: nothing persisted, nothing added
    // optimistically — the guard short-circuits before any write.
    expect(sync.inserts, isEmpty);
    expect(ctrl.getTour('t1')!.passengers.map((p) => p.id), isNot(contains('p2')));
  });

  test('addPassenger on a COMPLETED tour is refused', () async {
    final sync = _RecordingSync();
    Get.put<SyncService>(sync);
    final ctrl = TourController();
    ctrl.tours.assignAll([
      _tourWith([_p('p1')], status: TourStatus.completed),
    ]);

    await ctrl.addPassenger('t1', _p('p2'));

    expect(sync.inserts, isEmpty);
    expect(ctrl.getTour('t1')!.passengers.map((p) => p.id), isNot(contains('p2')));
  });

  // ── Auto-confirm + notify when a seat is placed from the chart ──────────────
  // A seat assigned straight from the chart to a rider who was never confirmed
  // through the Requests screen used to seat them SILENTLY. It must now confirm
  // them (persisted) AND fire the WhatsApp greeting — from every seating path.

  test('assignSeats on an unconfirmed rider auto-confirms + notifies', () async {
    final sync = _RecordingSync();
    Get.put<SyncService>(sync);
    final ctrl = TourController();
    ctrl.tours.assignAll([
      _tourWith([_requesting('p1')], buses: [_bus('b1')]),
    ]);
    final sent = <String>[];
    ctrl.confirmedSender = (tour, p) async {
      sent.add(p.id);
      return true;
    };

    await ctrl.assignSeats(
      't1',
      'p1',
      [SeatAssignment(busId: 'b1', seatId: 'L1')],
    );
    await pumpEventQueue();

    // Implicit confirmation: flag flipped AND the row was persisted.
    expect(ctrl.getTour('t1')!.passengers.first.isConfirmed, isTrue);
    expect(sync.updates, contains('passengers:p1'));
    // The customer was notified exactly once.
    expect(sent, ['p1']);
  });

  test('assignSeats on an already-confirmed rider does NOT re-notify', () async {
    final sync = _RecordingSync();
    Get.put<SyncService>(sync);
    final ctrl = TourController();
    ctrl.tours.assignAll([
      _tourWith(
        [_requesting('p1').copyWith(isConfirmed: true)],
        buses: [_bus('b1')],
      ),
    ]);
    final sent = <String>[];
    ctrl.confirmedSender = (tour, p) async {
      sent.add(p.id);
      return true;
    };

    await ctrl.assignSeats(
      't1',
      'p1',
      [SeatAssignment(busId: 'b1', seatId: 'L1')],
    );
    await pumpEventQueue();

    // Idempotent: the front-door Confirm already messaged them — no second send.
    expect(sent, isEmpty);
    expect(ctrl.getTour('t1')!.passengers.first.isConfirmed, isTrue);
  });

  test('clearing seats (empty assignments) never confirms or notifies',
      () async {
    final sync = _RecordingSync();
    Get.put<SyncService>(sync);
    final ctrl = TourController();
    ctrl.tours.assignAll([
      _tourWith([_requesting('p1')], buses: [_bus('b1')]),
    ]);
    final sent = <String>[];
    ctrl.confirmedSender = (tour, p) async {
      sent.add(p.id);
      return true;
    };

    await ctrl.assignSeats('t1', 'p1', const []);
    await pumpEventQueue();

    expect(ctrl.getTour('t1')!.passengers.first.isConfirmed, isFalse);
    expect(sent, isEmpty);
  });

  test('fillTour auto-confirms + notifies every newly-seated unconfirmed rider',
      () async {
    final sync = _RecordingSync();
    Get.put<SyncService>(sync);
    final ctrl = TourController();
    ctrl.tours.assignAll([
      _tourWith([_requesting('p1'), _requesting('p2')], buses: [_bus('b1')]),
    ]);
    final sent = <String>[];
    ctrl.confirmedSender = (tour, p) async {
      sent.add(p.id);
      return true;
    };

    await ctrl.fillTour('t1');
    await pumpEventQueue();

    final pax = ctrl.getTour('t1')!.passengers;
    final seatedIds =
        pax.where((p) => p.assignedSeats.isNotEmpty).map((p) => p.id).toSet();
    // Auto-fill actually seated riders...
    expect(seatedIds, isNotEmpty);
    // ...and every seated rider was confirmed AND notified.
    for (final p in pax.where((p) => p.assignedSeats.isNotEmpty)) {
      expect(p.isConfirmed, isTrue, reason: '${p.id} should be confirmed');
    }
    expect(sent.toSet(), seatedIds);
  });
}
