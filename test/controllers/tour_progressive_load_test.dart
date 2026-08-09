import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:occubusbooking/controllers/auth_controller.dart';
import 'package:occubusbooking/controllers/tour_controller.dart';
import 'package:occubusbooking/models/bus_details.dart';
import 'package:occubusbooking/models/bus_type.dart';
import 'package:occubusbooking/models/passenger.dart';
import 'package:occubusbooking/models/seat_layout.dart';
import 'package:occubusbooking/models/tour.dart';
import 'package:occubusbooking/models/tour_status.dart';
import 'package:occubusbooking/models/trip_type.dart';
import 'package:occubusbooking/services/sync_service.dart';

class _NoInitAuth extends AuthController {
  @override
  // ignore: must_call_super
  void onInit() {}

  @override
  Future<void> get whenRestored => Future.value();
}

/// Progressive load spy: headers first, then relations without layout, then
/// layout-only when asked.
class _ProgressiveSync extends SyncService {
  var tourRowCalls = 0;
  var relationCalls = 0;
  var layoutCalls = 0;
  final layoutRequestedIds = <String>[];

  @override
  // ignore: must_call_super
  void onInit() {}

  @override
  Future<List<Map<String, dynamic>>> fetchTourRows({
    Map<String, String>? filters,
    String? orderBy,
  }) async {
    tourRowCalls++;
    return [
      {
        'id': 't1',
        'title': 'Dwarka',
        'from_city': 'Surat',
        'to_city': 'Dwarka',
        'departure_date': '2026-07-01',
        'price_per_seat': 1200,
        'status': 'assigning',
        'trip_type': TripType.roundTrip.name,
      },
    ];
  }

  @override
  Future<
      ({
        List<Map<String, dynamic>> passengers,
        List<Map<String, dynamic>> buses,
        List<Map<String, dynamic>> groups,
      })> fetchRelationsForTours(List<String> tourIds) async {
    relationCalls++;
    return (
      passengers: [
        {
          'id': 'p1',
          'tour_id': 't1',
          'name': 'Asha',
          'phone': '+919876543210',
        },
      ],
      buses: [
        {
          'id': 'b1',
          'tour_id': 't1',
          'name': 'Bus 1',
          'bus_type': 'Sleeper',
          'total_seats': 30,
          // Deliberately NO layout — cold start projection.
        },
      ],
      groups: const <Map<String, dynamic>>[],
    );
  }

  @override
  Future<List<Map<String, dynamic>>> fetchBusLayouts(
    List<String> busIds,
  ) async {
    layoutCalls++;
    layoutRequestedIds.addAll(busIds);
    final layout = BusLayout.generate(
      busType: BusType.sleeper,
      totalSeats: 30,
    );
    return [
      for (final id in busIds)
        {
          'id': id,
          'layout': layout.toMap(),
        },
    ];
  }
}

void main() {
  setUp(() {
    Get.reset();
  });

  tearDown(Get.reset);

  test('cold start paints headers before layout jsonb is fetched', () async {
    final sync = _ProgressiveSync();
    Get.put<SyncService>(sync);
    Get.put<AuthController>(_NoInitAuth());
    final ctrl = TourController();

    await ctrl.refreshTours();
    await pumpEventQueue();

    expect(sync.tourRowCalls, 1);
    expect(sync.relationCalls, 1);
    expect(ctrl.tours, hasLength(1));
    expect(ctrl.tours.first.passengers, hasLength(1));
    expect(ctrl.tours.first.buses, hasLength(1));
    expect(ctrl.hasError.value, isFalse);

    // Layouts must arrive ONLY via fetchBusLayouts — never embedded in the
    // Phase-2 relations payload. Background prefetch may already have run by
    // the time we assert; either way the dedicated layout API is what paid.
    await ctrl.ensureTourReadyForSeating('t1');
    expect(sync.layoutCalls, greaterThanOrEqualTo(1));
    expect(sync.layoutRequestedIds, contains('b1'));
    expect(ctrl.getTour('t1')!.buses.first.layout, isNotNull);
  });

  test('ensureTourReadyForSeating is a no-op when local layouts exist',
      () async {
    final sync = _ProgressiveSync();
    Get.put<SyncService>(sync);
    Get.put<AuthController>(_NoInitAuth());
    final ctrl = TourController();
    final layout = BusLayout.generate(
      busType: BusType.sleeper,
      totalSeats: 30,
    );
    ctrl.tours.assignAll([
      Tour(
        id: 't1',
        title: 'Dwarka',
        fromCity: 'Surat',
        toCity: 'Dwarka',
        departureDate: DateTime(2026, 7, 1),
        pricePerSeat: 1200,
        status: TourStatus.assigning,
        passengers: [
          Passenger(
            id: 'p1',
            tourId: 't1',
            name: 'Asha',
            phone: '+919876543210',
          ),
        ],
        buses: [
          Bus(
            id: 'b1',
            name: 'Bus 1',
            busType: 'Sleeper',
            layout: layout,
          ),
        ],
      ),
    ]);

    await ctrl.ensureTourReadyForSeating('t1');
    expect(sync.relationCalls, 0);
    expect(sync.layoutCalls, 0);
  });
}
