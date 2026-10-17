import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:occubusbooking/controllers/tour_controller.dart';
import 'package:occubusbooking/models/booking_mode.dart';
import 'package:occubusbooking/models/bus_details.dart';
import 'package:occubusbooking/models/passenger.dart';
import 'package:occubusbooking/models/passenger_group.dart';
import 'package:occubusbooking/models/tour.dart';
import 'package:occubusbooking/models/tour_status.dart';
import 'package:occubusbooking/services/sync_service.dart';

/// Swallows every write; [onInit] is overridden so no connectivity listener
/// starts. Captures the last tours payload so the persisted row is checkable.
class _NoopSync extends SyncService {
  Map<String, dynamic>? lastTourWrite;

  @override
  // ignore: must_call_super
  void onInit() {}

  @override
  Future<void> smartUpdate({
    required String table,
    required String entityId,
    required Map<String, dynamic> data,
  }) async {
    if (table == 'tours') lastTourWrite = data;
  }

  @override
  Future<void> updatePatch({
    required String table,
    required String entityId,
    required Map<String, dynamic> fields,
  }) async {}

  @override
  Future<void> invalidateCache(String key) async {}
}

Tour _richTour({List<Bus> buses = const [], List<Passenger> pax = const []}) =>
    Tour(
      id: 't1',
      title: 'Dwarka Yatra',
      fromCity: 'Surat',
      toCity: 'Dwarka',
      departureDate: DateTime(2026, 7, 1),
      departureTime: '06:00',
      returnDate: DateTime(2026, 7, 4),
      returnTime: '20:00',
      description: 'old',
      pricePerSeat: 1200,
      status: TourStatus.collecting,
      ownerId: 'owner-1',
      busId: 'b-legacy',
      bookingMode: BookingMode.chart,
      advancePerBerthPaise: 50000,
      collectVpa: 'ugam@upi',
      collectPayeeName: 'Ugam Tours',
      broadcastMessage: 'Jai Shri Krishna',
      broadcastImageUrl: 'https://x/y.png',
      groups: [PassengerGroup(id: 'g1', tourId: 't1', label: 'Family')],
      buses: buses,
      passengers: pax,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(Get.reset);

  test('editTour keeps the money/payment fields it does not edit', () async {
    final sync = _NoopSync();
    Get.put<SyncService>(sync);
    final ctrl = TourController();
    ctrl.tours.assignAll([_richTour()]);

    await ctrl.editTour(
      tourId: 't1',
      title: 'Dwarka Yatra 2',
      fromCity: 'Surat',
      toCity: 'Dwarka',
      departureDate: DateTime(2026, 7, 2),
      pricePerSeat: 1500,
      // departureTime / returnDate / returnTime / description omitted = cleared.
    );

    final t = ctrl.getTour('t1')!;
    expect(t.title, 'Dwarka Yatra 2');
    expect(t.pricePerSeat, 1500);
    expect(t.ownerId, 'owner-1');
    expect(t.busId, 'b-legacy');
    expect(t.bookingMode, BookingMode.chart);
    expect(t.advancePerBerthPaise, 50000);
    expect(t.collectVpa, 'ugam@upi');
    expect(t.collectPayeeName, 'Ugam Tours');
    expect(t.broadcastMessage, 'Jai Shri Krishna');
    expect(t.broadcastImageUrl, 'https://x/y.png');
    expect(t.groups.map((g) => g.id), ['g1']);
    // The edit form can still CLEAR its own optional fields.
    expect(t.departureTime, isNull);
    expect(t.returnDate, isNull);
    expect(t.returnTime, isNull);
    expect(t.description, isNull);
    // ...and the persisted row carries the advance, not a dropped null.
    expect(sync.lastTourWrite, isNotNull);
    expect(sync.lastTourWrite, equals(t.toMap()));
  });

  test('removeBusHandler keeps the bus pakku-bhadu rentIncludesFuel flag',
      () async {
    Get.put<SyncService>(_NoopSync());
    final ctrl = TourController();
    final bus = Bus(
      id: 'b1',
      name: 'Bus 1',
      busType: 'Sleeper',
      busPrice: 40000,
      rentIncludesFuel: false,
      handlerPassengerId: 'h1',
    );
    final handler = Passenger(
      id: 'h1',
      tourId: 't1',
      name: 'H',
      phone: '+910000000000',
      isHandler: true,
    );
    ctrl.tours.assignAll([_richTour(buses: [bus], pax: [handler])]);

    await ctrl.removeBusHandler('t1', 'b1');

    final b = ctrl.getTour('t1')!.buses.single;
    expect(b.handlerPassengerId, isNull);
    expect(b.rentIncludesFuel, isFalse);
    expect(b.busPrice, 40000);
  });
}
