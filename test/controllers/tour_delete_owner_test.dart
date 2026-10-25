import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:occubusbooking/controllers/tour_controller.dart';
import 'package:occubusbooking/models/tour.dart';
import 'package:occubusbooking/models/tour_status.dart';
import 'package:occubusbooking/services/sync_service.dart';

/// Live, 2026-10-25: the owner reported "I can't delete any trip". RLS lets an
/// admin archive only tours whose `owner_id` is their own uid, and a soft
/// delete is an UPDATE without RETURNING — so on another admin's tour Postgres
/// matched 0 rows and reported success. The app removed the trip, then the
/// next refresh brought it back. A second admin account owns four live tours
/// the signed-in admin can see; every delete of those silently did nothing.
class _Sync extends SyncService {
  _Sync(this.uid);

  final String? uid;
  final List<String> deleted = [];

  @override
  // ignore: must_call_super
  void onInit() {}

  @override
  String? get currentUserId => uid;

  @override
  Future<void> smartDelete({
    required String table,
    required String entityId,
  }) async {
    deleted.add('$table/$entityId');
  }
}

Tour _tour(String id, {String? owner}) => Tour(
      id: id,
      ownerId: owner,
      title: 'bij',
      fromCity: 'Surat',
      toCity: 'Ambaji',
      departureDate: DateTime(2026, 7, 2),
      status: TourStatus.completed,
      pricePerSeat: 1500,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _Sync sync;
  late TourController ctrl;

  void boot(String? uid) {
    Get.reset();
    sync = _Sync(uid);
    Get.put<SyncService>(sync);
    ctrl = TourController();
  }

  tearDown(Get.reset);

  test("another admin's tour is refused up front: no write, stays listed",
      () async {
    boot('me');
    ctrl.tours.assignAll([_tour('t1', owner: 'someone-else')]);

    await ctrl.deleteTour('t1');

    expect(sync.deleted, isEmpty,
        reason: 'RLS would match 0 rows and report success — never send it');
    expect(ctrl.getTour('t1'), isNotNull,
        reason: 'the trip must not vanish and then reappear on refresh');
  });

  test('my own tour is deleted as before', () async {
    boot('me');
    ctrl.tours.assignAll([_tour('t1', owner: 'me')]);

    await ctrl.deleteTour('t1');

    expect(sync.deleted, ['tours/t1']);
    expect(ctrl.getTour('t1'), isNull);
  });

  test('a legacy tour with no owner is not blocked by the check', () async {
    boot('me');
    ctrl.tours.assignAll([_tour('t1')]);

    await ctrl.deleteTour('t1');

    expect(sync.deleted, ['tours/t1']);
  });

  test('no signed-in uid (cannot tell) does not block the delete', () async {
    boot(null);
    ctrl.tours.assignAll([_tour('t1', owner: 'someone')]);

    await ctrl.deleteTour('t1');

    expect(sync.deleted, ['tours/t1']);
  });
}
