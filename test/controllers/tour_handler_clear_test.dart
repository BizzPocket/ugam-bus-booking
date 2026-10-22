import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:occubusbooking/controllers/tour_controller.dart';
import 'package:occubusbooking/models/bus_details.dart';
import 'package:occubusbooking/models/passenger.dart';
import 'package:occubusbooking/models/tour.dart';
import 'package:occubusbooking/models/tour_status.dart';
import 'package:occubusbooking/services/sync_service.dart';

/// `Tour.copyWith(handlerId: null)` used to KEEP the old handler (`??` can't
/// null a field), and `Tour.toMap()` omits a null `handler_id`, so removing the
/// last bus handler left `tours.handler_id` pointing at them both locally and
/// on the server. The admin removed a handler and the tour still "had" one.
class _RecordingSync extends SyncService {
  final List<({String table, Map<String, dynamic> fields})> patches = [];
  final List<({String table, Map<String, dynamic> data})> fullWrites = [];

  @override
  // ignore: must_call_super
  void onInit() {}

  @override
  Future<void> updatePatch({
    required String table,
    required String entityId,
    required Map<String, dynamic> fields,
  }) async {
    patches.add((table: table, fields: Map.of(fields)));
  }

  @override
  Future<void> smartUpdate({
    required String table,
    required String entityId,
    required Map<String, dynamic> data,
  }) async {
    fullWrites.add((table: table, data: Map.of(data)));
  }
}

Bus _bus(String id, {String? handler}) => Bus(
      id: id,
      tourId: 't1',
      name: 'bus-$id',
      busType: 'Sleeper',
      totalSeatsLegacy: 37,
      handlerPassengerId: handler,
    );

Tour _tour({required List<Bus> buses, String? handlerId}) => Tour(
      id: 't1',
      title: 'Ambaji',
      fromCity: 'Ahmedabad',
      toCity: 'Ambaji',
      departureDate: DateTime(2026, 8, 14),
      status: TourStatus.busBooked,
      pricePerSeat: 1500,
      handlerId: handlerId,
      buses: buses,
      passengers: [
        Passenger(
          id: 'p1',
          tourId: 't1',
          name: 'Jenish',
          phone: '+919876543210',
          isHandler: true,
        ),
        Passenger(
          id: 'p2',
          tourId: 't1',
          name: 'Kalpesh',
          phone: '+919876543211',
          isHandler: true,
        ),
      ],
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Tour.copyWith handler pointer', () {
    test('clearHandlerId actually clears it', () {
      final t = _tour(buses: const [], handlerId: 'p1');
      expect(t.copyWith(clearHandlerId: true).handlerId, isNull);
    });

    test('handlerId: null alone still keeps the old value (the trap)', () {
      final t = _tour(buses: const [], handlerId: 'p1');
      expect(t.copyWith(handlerId: null).handlerId, 'p1');
    });
  });

  group('removing a handler', () {
    late _RecordingSync sync;
    late TourController ctrl;

    setUp(() {
      Get.reset();
      sync = _RecordingSync();
      Get.put<SyncService>(sync);
      ctrl = TourController();
    });

    tearDown(Get.reset);

    test('removing the LAST bus handler clears tours.handler_id', () async {
      ctrl.tours.assignAll([
        _tour(buses: [_bus('b1', handler: 'p1')], handlerId: 'p1'),
      ]);

      await ctrl.removeBusHandler('t1', 'b1');

      expect(ctrl.getTour('t1')!.handlerId, isNull,
          reason: 'the removed handler must be gone locally');
      final tourPatch = sync.patches.firstWhere((p) => p.table == 'tours');
      expect(tourPatch.fields.containsKey('handler_id'), isTrue);
      expect(tourPatch.fields['handler_id'], isNull,
          reason: 'an explicit null is the only write that clears the column');
    });

    test('removing one of two bus handlers repoints at the other', () async {
      ctrl.tours.assignAll([
        _tour(
          buses: [_bus('b1', handler: 'p1'), _bus('b2', handler: 'p2')],
          handlerId: 'p1',
        ),
      ]);

      await ctrl.removeBusHandler('t1', 'b1');

      expect(ctrl.getTour('t1')!.handlerId, 'p2');
      final tourPatch = sync.patches.firstWhere((p) => p.table == 'tours');
      expect(tourPatch.fields['handler_id'], 'p2');
    });

    test('removeHandler clears the pointer and the passenger flag', () async {
      ctrl.tours.assignAll([
        _tour(buses: [_bus('b1')], handlerId: 'p1'),
      ]);

      await ctrl.removeHandler('t1');

      final t = ctrl.getTour('t1')!;
      expect(t.handlerId, isNull);
      expect(t.passengers.where((p) => p.isHandler), isEmpty);
      final tourPatch = sync.patches.firstWhere((p) => p.table == 'tours');
      expect(tourPatch.fields, {'handler_id': null});
      final flipped = sync.fullWrites
          .where((w) => w.table == 'passengers')
          .map((w) => w.data['id'])
          .toSet();
      expect(flipped, {'p1', 'p2'});
    });
  });
}
