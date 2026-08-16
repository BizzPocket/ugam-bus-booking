import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:occubusbooking/controllers/tour_controller.dart';
import 'package:occubusbooking/models/bus_details.dart';
import 'package:occubusbooking/models/bus_type.dart';
import 'package:occubusbooking/models/passenger.dart';
import 'package:occubusbooking/models/seat_assignment.dart';
import 'package:occubusbooking/models/seat_layout.dart';
import 'package:occubusbooking/models/seat_type.dart';
import 'package:occubusbooking/models/tour.dart';
import 'package:occubusbooking/models/tour_status.dart';
import 'package:occubusbooking/services/sync_service.dart';

/// Regression suite for the bug that destroyed two live seat charts.
///
/// Cold start deliberately ships buses WITHOUT their `layout` jsonb (~71% of bus
/// bytes on a 2G link), so an in-memory [Bus] routinely holds `layout == null`
/// for a bus that has a perfectly good grid on the server. Every bus write used
/// to send `bus.toMap()` — the WHOLE row — through `smartUpdate`, which
/// overwrites every column it carries. Setting a handler pointer therefore
/// shipped `layout: null` and erased the seat map, leaving `total_seats` and all
/// the passengers' `assigned_seats` behind pointing at seat ids that no longer
/// existed anywhere.
///
/// These tests pin the contract that makes that impossible: bus writes are
/// column-scoped, and `layout` is only ever on the wire when the caller actually
/// built a new one.
class _RecordingSync extends SyncService {
  final List<({String table, String entityId, Map<String, dynamic> fields})>
      patches = [];
  final List<({String table, Map<String, dynamic> data})> fullWrites = [];

  @override
  // ignore: must_call_super
  void onInit() {}

  /// The server confirming what the wipe left behind: the bus row exists, its
  /// `layout` column is NULL. This is what makes `layout == null` mean "really
  /// gone" rather than "not fetched yet".
  @override
  Future<List<Map<String, dynamic>>> fetchBusLayouts(List<String> busIds) async {
    return [for (final id in busIds) {'id': id, 'layout': null}];
  }

  @override
  Future<void> updatePatch({
    required String table,
    required String entityId,
    required Map<String, dynamic> fields,
  }) async {
    patches.add((table: table, entityId: entityId, fields: Map.of(fields)));
  }

  @override
  Future<void> smartUpdate({
    required String table,
    required String entityId,
    required Map<String, dynamic> data,
  }) async {
    fullWrites.add((table: table, data: Map.of(data)));
  }

  @override
  Future<void> smartInsert({
    required String table,
    required String entityId,
    required Map<String, dynamic> data,
    String? cacheKey,
  }) async {
    fullWrites.add((table: table, data: Map.of(data)));
  }

  /// Every bus row this fake was asked to write, whatever the operation.
  Iterable<Map<String, dynamic>> get busWrites => [
        ...patches.where((p) => p.table == 'buses').map((p) => p.fields),
        ...fullWrites.where((w) => w.table == 'buses').map((w) => w.data),
      ];
}

BusLayout _layout() => BusLayout(
      rows: 1,
      cols: SeatGridCols.count,
      grid: const [
        SeatCell(
          row: 0,
          col: 0,
          seatType: SeatType.singleSofa,
          position: SeatPosition.upper,
          seatId: 'SU1',
        ),
        SeatCell(
          row: 0,
          col: 1,
          seatType: SeatType.singleSofa,
          position: SeatPosition.upper,
          seatId: 'SU2',
        ),
      ],
    );

Bus _bus({BusLayout? layout, String? handlerId}) => Bus(
      id: 'b1',
      tourId: 't1',
      name: 'shivkamal-1',
      busType: 'Sleeper',
      totalSeatsLegacy: 37,
      handlerPassengerId: handlerId,
      layout: layout,
    );

Tour _tour({
  BusLayout? layout,
  String? handlerId,
  TourStatus status = TourStatus.busBooked,
}) =>
    Tour(
      id: 't1',
      title: 'Shravan Sud Bij',
      fromCity: 'Ahmedabad',
      toCity: 'Ambaji',
      departureDate: DateTime(2026, 8, 14),
      status: status,
      pricePerSeat: 1500,
      buses: [_bus(layout: layout, handlerId: handlerId)],
      passengers: [
        Passenger(
          id: 'p1',
          tourId: 't1',
          name: 'Jenish',
          phone: '+919876543210',
        ),
      ],
    );

void main() {
  // The refusal paths below reach `AppSnackBar`, which reads
  // `Get.overlayContext` — and that touches `WidgetsBinding.instance`. The
  // snackbar itself no-ops without an overlay (app_snackbar.dart:46), so this
  // buys the binding, not a rendered toast.
  TestWidgetsFlutterBinding.ensureInitialized();

  late _RecordingSync sync;
  late TourController ctrl;

  setUp(() {
    Get.reset();
    sync = _RecordingSync();
    Get.put<SyncService>(sync);
    ctrl = TourController();
  });

  tearDown(Get.reset);

  group('Bus.toPatch — lazily-loaded columns', () {
    test('omits layout entirely when it was not loaded', () {
      final patch = _bus().toPatch(includeLayout: false);
      expect(patch.containsKey('layout'), isFalse,
          reason: 'an absent key leaves the column untouched; a null ERASES it');
      expect(patch['name'], 'shivkamal-1');
      expect(patch['total_seats'], 37);
    });

    test('omits layout even when one IS held in memory', () {
      final patch = _bus(layout: _layout()).toPatch(includeLayout: false);
      expect(patch.containsKey('layout'), isFalse,
          reason: 'the caller decides, not whatever the model happens to hold');
    });

    test('includes layout when the caller built a new one', () {
      final patch = _bus(layout: _layout()).toPatch(includeLayout: true);
      expect(patch['layout'], isNotNull);
    });
  });

  group('handler pointer writes', () {
    test('setBusHandler patches ONLY the handler column', () async {
      ctrl.tours.assignAll([_tour()]);
      await ctrl.setBusHandler('t1', 'b1', 'p1');

      final busPatch =
          sync.patches.firstWhere((p) => p.table == 'buses').fields;
      expect(busPatch.keys, ['handler_passenger_id']);
      expect(busPatch['handler_passenger_id'], 'p1');
    });

    test('removeBusHandler patches ONLY the handler column', () async {
      ctrl.tours.assignAll([_tour(handlerId: 'p1')]);
      await ctrl.removeBusHandler('t1', 'b1');

      final busPatch =
          sync.patches.firstWhere((p) => p.table == 'buses').fields;
      expect(busPatch.keys, ['handler_passenger_id']);
      expect(busPatch['handler_passenger_id'], isNull);
    });

    test('no handler write ever carries a layout key — loaded or not', () async {
      ctrl.tours.assignAll([_tour()]);
      await ctrl.setBusHandler('t1', 'b1', 'p1');
      ctrl.tours.assignAll([_tour(layout: _layout(), handlerId: 'p1')]);
      await ctrl.removeBusHandler('t1', 'b1');

      for (final write in sync.busWrites) {
        expect(write.containsKey('layout'), isFalse,
            reason: 'this is the write that erased the live seat charts');
      }
    });
  });

  group('updateBus', () {
    test('leaves layout untouched when the editor did not rebuild it', () async {
      // The exact live shape: the bus HAS a grid on the server, but this
      // session never fetched it, so the in-memory layout is null.
      ctrl.tours.assignAll([_tour()]);
      await ctrl.updateBus(
        't1',
        _bus().copyWith(driverName: 'Rakesh'),
        layoutChanged: false,
      );

      final patch = sync.patches.firstWhere((p) => p.table == 'buses').fields;
      expect(patch.containsKey('layout'), isFalse);
      expect(patch['driver_name'], 'Rakesh',
          reason: 'the edited columns still have to land');
    });

    test('writes layout when the editor regenerated it', () async {
      ctrl.tours.assignAll([_tour(layout: _layout())]);
      await ctrl.updateBus(
        't1',
        _bus(layout: _layout()),
        layoutChanged: true,
      );

      final patch = sync.patches.firstWhere((p) => p.table == 'buses').fields;
      expect(patch['layout'], isNotNull);
    });
  });

  group('updateBus — the lock freezes the CHART, not the bus record', () {
    // Reported from the field as "the bus details are not editing". The gate
    // fired on `!status.allowsLayoutEdit` alone, so a locked tour refused the
    // WHOLE update — driver, phone, boarding point, departure time, pricing —
    // under a toast that said "layout locked" and explained none of it. Those
    // are the fields that change on departure day, which is precisely when a
    // tour is locked.
    for (final status in [TourStatus.locked, TourStatus.completed]) {
      test('a detail edit lands on a ${status.name} tour', () async {
        ctrl.tours.assignAll([_tour(status: status)]);

        await ctrl.updateBus(
          't1',
          _bus().copyWith(driverName: 'Rakesh', driverPhone: '+919000000001'),
          layoutChanged: false,
        );

        final patch = sync.patches.firstWhere((p) => p.table == 'buses').fields;
        expect(patch['driver_name'], 'Rakesh');
        expect(patch['driver_phone'], '+919000000001');
        expect(patch.containsKey('layout'), isFalse,
            reason: 'a detail edit still must not carry the grid');
      });

      test('a re-layout is still refused on a ${status.name} tour', () async {
        ctrl.tours.assignAll([_tour(layout: _layout(), status: status)]);

        await ctrl.updateBus(
          't1',
          _bus(layout: _layout()),
          layoutChanged: true,
        );

        expect(sync.busWrites, isEmpty,
            reason: 'the notified chart must not silently change shape');
      });
    }

    test('the local cache is not patched by a refused re-layout', () async {
      ctrl.tours.assignAll([_tour(status: TourStatus.locked)]);

      await ctrl.updateBus(
        't1',
        _bus(layout: _layout()).copyWith(driverName: 'Should not stick'),
        layoutChanged: true,
      );

      // The optimistic local write sits INSIDE `_write`, so a gate that returns
      // before it must leave the in-memory bus alone too — otherwise the UI
      // shows an edit the server never took.
      expect(ctrl.getTour('t1')!.buses.first.driverName, isNot('Should not stick'));
    });
  });

  group('recoverBusLayoutFor — repairing an already-wiped bus', () {
    /// The live damage: layout gone, `total_seats` intact, riders still holding
    /// seat ids from the grid that no longer exists.
    Tour wiped(BusLayout original) {
      final ids = original.allSeatIds;
      return Tour(
        id: 't1',
        title: 'Shravan Sud Bij',
        fromCity: 'Ahmedabad',
        toCity: 'Ambaji',
        departureDate: DateTime(2026, 8, 14),
        status: TourStatus.busBooked,
        pricePerSeat: 1500,
        buses: [
          Bus(
            id: 'b1',
            tourId: 't1',
            name: 'shivkamal-1',
            busType: 'Sleeper',
            totalSeatsLegacy: original.totalSeats,
            // layout deliberately absent — this is the wipe
          ),
        ],
        passengers: [
          for (var i = 0; i < ids.length; i++)
            Passenger(
              id: 'p$i',
              tourId: 't1',
              name: 'Rider $i',
              phone: '+91987654${1000 + i}',
              assignedSeats: [SeatAssignment(busId: 'b1', seatId: ids[i])],
            ),
        ],
      );
    }

    test('rebuilds the grid and re-attaches every rider', () async {
      final original = BusLayout.generate(
        busType: BusType.sleeper,
        totalSeats: 37,
        singleSofaCount: 13,
      );
      ctrl.tours.assignAll([wiped(original)]);

      final result = await ctrl.recoverBusLayoutFor('t1', 'b1');

      expect(result.recovered, isTrue, reason: result.reason);
      final rebuilt = ctrl.getTour('t1')!.buses.first.layout!;
      expect(rebuilt.allSeatIds.toSet(), original.allSeatIds.toSet());

      // Every rider's seat id still resolves inside the rebuilt grid, so nobody
      // was moved to repair the bus.
      final seatIds = rebuilt.allSeatIds.toSet();
      for (final p in ctrl.getTour('t1')!.passengers) {
        for (final a in p.assignedSeats) {
          expect(seatIds.contains(a.seatId), isTrue);
        }
      }
    });

    test('writes only the layout column', () async {
      final original = BusLayout.generate(
        busType: BusType.sleeper,
        totalSeats: 37,
        singleSofaCount: 13,
      );
      ctrl.tours.assignAll([wiped(original)]);
      await ctrl.recoverBusLayoutFor('t1', 'b1');

      final patch = sync.patches.firstWhere((p) => p.table == 'buses').fields;
      expect(patch.keys, ['layout']);
    });

    test('refuses to touch a bus that still has its layout', () async {
      ctrl.tours.assignAll([_tour(layout: _layout())]);

      final result = await ctrl.recoverBusLayoutFor('t1', 'b1');

      expect(result.recovered, isFalse);
      expect(result.reason, contains('already has'));
      expect(sync.busWrites, isEmpty,
          reason: 'a live grid must never be overwritten by the repair path');
    });
  });
}
