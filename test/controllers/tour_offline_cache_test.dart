import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:occubusbooking/controllers/auth_controller.dart';
import 'package:occubusbooking/controllers/tour_controller.dart';
import 'package:occubusbooking/models/admin.dart';
import 'package:occubusbooking/models/bus_details.dart';
import 'package:occubusbooking/models/bus_type.dart';
import 'package:occubusbooking/models/passenger.dart';
import 'package:occubusbooking/models/profile.dart';
import 'package:occubusbooking/models/seat_layout.dart';
import 'package:occubusbooking/models/tour.dart';
import 'package:occubusbooking/models/tour_status.dart';
import 'package:occubusbooking/services/admin_auth_service.dart';
import 'package:occubusbooking/services/sync_service.dart';
import 'package:occubusbooking/services/tour_cache_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Admin session with no `onInit` (no prefs read, no network admin lookup) and
/// both restore gates already open.
class _SignedInAdmin extends AuthController {
  @override
  // ignore: must_call_super
  void onInit() {}

  @override
  Future<void> get whenRestored => Future.value();

  @override
  Future<void> get whenPrefsRestored => Future.value();
}

/// An anonymous / customer viewer: logged in flag down, so there is no cache
/// scope at all.
class _AnonAuth extends _SignedInAdmin {}

/// An admin session restored from PREFS whose `findByPhone` lookup never landed,
/// so `currentAdmin` is null.
///
/// This is not a corner case, it is the ordinary slow-link cold start: the admin
/// lookup has a 12 s timeout and the far lighter tour query can outlive it. In
/// that state `TourController._tourFilters` is null, so the tour fetch runs
/// UNFILTERED and returns every PUBLIC tour instead of this admin's — which is
/// why the disk cache may still be READ under the persisted id but must never be
/// WRITTEN under it.
class _AdminLookupTimedOut extends _SignedInAdmin {
  @override
  String? get cacheScopeAdminId => 'a1';
}

/// Reports the session state at the exact instant the cache tree is wiped.
class _ProbeStore extends TourCacheStore {
  _ProbeStore(Directory dir) : super(directory: (() async => dir));

  void Function()? onWipe;

  @override
  Future<void> clearAll() async {
    onWipe?.call();
    return super.clearAll();
  }
}

class _NoOpAdminAuth extends AdminAuthService {
  _NoOpAdminAuth() : super.internal();
  @override
  Future<void> signOut() async {}
}

/// Every read fails — the offline case, and the "the fetch genuinely broke"
/// case, which must look identical to the user: saved data, clearly labelled.
class _DeadSync extends SyncService {
  @override
  // ignore: must_call_super
  void onInit() {}

  @override
  Future<List<Map<String, dynamic>>> fetchTourRows({
    Map<String, String>? filters,
    String? orderBy,
  }) async =>
      throw const SocketException('no route to host');
}

/// One tour, one bus with a grid, one passenger.
class _LiveSync extends SyncService {
  var layoutCalls = 0;

  @override
  // ignore: must_call_super
  void onInit() {}

  @override
  Future<List<Map<String, dynamic>>> fetchTourRows({
    Map<String, String>? filters,
    String? orderBy,
  }) async =>
      [
        {
          'id': 't1',
          'title': 'Dwarka',
          'from_city': 'Surat',
          'to_city': 'Dwarka',
          'departure_date': '2027-07-01',
          'price_per_seat': 1200,
          'status': 'assigning',
        },
      ];

  @override
  Future<
      ({
        List<Map<String, dynamic>> passengers,
        List<Map<String, dynamic>> buses,
        List<Map<String, dynamic>> groups,
      })> fetchRelationsForTours(List<String> tourIds) async => (
        passengers: [
          {'id': 'p1', 'tour_id': 't1', 'name': 'Asha', 'phone': '+91987'},
        ],
        buses: [
          {
            'id': 'b1',
            'tour_id': 't1',
            'name': 'Bus 1',
            'bus_type': 'Sleeper',
            'total_seats': 30,
          },
          {
            'id': 'b2',
            'tour_id': 't1',
            'name': 'Bus 2',
            'bus_type': 'Sleeper',
            'total_seats': 30,
          },
        ],
        groups: const <Map<String, dynamic>>[],
      );

  @override
  Future<List<Map<String, dynamic>>> fetchBusLayouts(
    List<String> busIds,
  ) async {
    layoutCalls++;
    final layout = BusLayout.generate(
      busType: BusType.sleeper,
      totalSeats: 30,
    );
    return [
      for (final id in busIds)
        // b2 has no grid on the server — the "known null" answer.
        {'id': id, 'layout': id == 'b2' ? null : layout.toMap()},
    ];
  }
}

Tour _seedTour() => Tour(
      id: 't1',
      title: 'Dwarka',
      fromCity: 'Surat',
      toCity: 'Dwarka',
      departureDate: DateTime(2027, 7, 1),
      pricePerSeat: 1200,
      status: TourStatus.assigning,
      passengers: [
        Passenger(id: 'p1', tourId: 't1', name: 'Asha', phone: '+91987'),
      ],
      buses: [
        Bus(
          id: 'b1',
          tourId: 't1',
          name: 'Bus 1',
          busType: 'Sleeper',
          layout: BusLayout.generate(
            busType: BusType.sleeper,
            totalSeats: 30,
          ),
        ),
        Bus(id: 'b2', tourId: 't1', name: 'Bus 2', busType: 'Sleeper'),
      ],
    );

void main() {
  // The failure paths call `AppSnackBar.warning`, which reaches
  // `Get.overlayContext` → `WidgetsBinding.instance`. Without a binding that
  // throws before the assertions run, which would hide the very behaviour
  // under test.
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late TourCacheStore store;
  final realInstance = TourCacheStore.instance;

  setUp(() {
    Get.reset();
    SharedPreferences.setMockInitialValues({});
    tmp = Directory.systemTemp.createTempSync('tour_offline_cache_test');
    store = TourCacheStore.forDirectory(tmp);
    TourCacheStore.instance = store;
  });

  tearDown(() {
    Get.reset();
    TourCacheStore.instance = realInstance;
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  AuthController putAdmin() {
    final auth = _SignedInAdmin()
      ..isLoggedIn.value = true
      ..userRole.value = UserRole.admin
      ..currentAdmin.value = Admin(id: 'a1', phone: '9876543210', name: 'Zee');
    Get.put<AuthController>(auth);
    return auth;
  }

  Future<void> seedCache({
    DateTime? savedAt,
    Set<String> knownNull = const {'b2'},
  }) =>
      store.write(TourGraphSnapshot(
        scopeKey: 'tours_admin_a1',
        savedAt: savedAt ?? DateTime.now().subtract(const Duration(hours: 2)),
        tours: [_seedTour()],
        layoutKnownNullBusIds: knownNull,
      ));

  test('cold start paints the cached graph, layouts and all', () async {
    Get.put<SyncService>(_DeadSync());
    putAdmin();
    await seedCache();

    final ctrl = TourController()..diskCache = store;
    await ctrl.hydrateFromDiskCache();

    expect(ctrl.tours, hasLength(1));
    expect(ctrl.tours.first.passengers, hasLength(1));
    expect(ctrl.tours.first.buses, hasLength(2));
    // The whole point: the seat grid is readable with no network.
    expect(ctrl.getTour('t1')!.buses.first.layout, isNotNull);
    expect(ctrl.getTour('t1')!.buses.first.layout!.totalSeats, 30);
    expect(ctrl.isTourHydrated('t1'), isTrue);
  });

  test('a cached cold start does NOT claim a grid is still loading', () async {
    Get.put<SyncService>(_DeadSync());
    putAdmin();
    await seedCache(knownNull: {'b2'});

    final ctrl = TourController()..diskCache = store;
    await ctrl.hydrateFromDiskCache();

    // b1 holds a grid, b2 is the server's positive "there is none". Both are
    // resolved, so the chart shows the real answer instead of a skeleton that
    // can never finish.
    expect(ctrl.layoutsLoadedFor('t1'), isTrue);
    expect(ctrl.getTour('t1')!.buses.last.layout, isNull);
  });

  test('a bus with no grid and no server answer stays UNRESOLVED', () async {
    Get.put<SyncService>(_DeadSync());
    putAdmin();
    // Same graph, but nothing was ever confirmed null. b2's null then means
    // "we do not hold it", which must read as loading and be re-fetched.
    await seedCache(knownNull: const {});

    final ctrl = TourController()..diskCache = store;
    await ctrl.hydrateFromDiskCache();

    expect(ctrl.layoutsLoadedFor('t1'), isFalse);
  });

  test('cached data is labelled cached, with its age', () async {
    Get.put<SyncService>(_DeadSync());
    putAdmin();
    final savedAt = DateTime.now().subtract(const Duration(hours: 3));
    await seedCache(savedAt: savedAt);

    final ctrl = TourController()..diskCache = store;
    await ctrl.hydrateFromDiskCache();

    expect(ctrl.isShowingCachedData.value, isTrue);
    expect(ctrl.dataAsOf.value, isNotNull);
    expect(
      ctrl.dataAsOf.value!.difference(savedAt).abs(),
      lessThan(const Duration(seconds: 1)),
    );
  });

  test('a failed fetch reads as cached-and-stale, never fresh or empty',
      () async {
    Get.put<SyncService>(_DeadSync());
    putAdmin();
    await seedCache();

    final ctrl = TourController()..diskCache = store;
    await ctrl.hydrateFromDiskCache();
    await ctrl.refreshTours();
    await pumpEventQueue();

    // Not empty — the deleted cache's other defect was masking a failed fetch
    // as an empty result.
    expect(ctrl.tours, hasLength(1));
    // Not the hard error screen either: there IS something to read.
    expect(ctrl.hasError.value, isFalse);
    // And emphatically not presented as live.
    expect(ctrl.isShowingCachedData.value, isTrue);
  });

  test('a failed fetch with NO cache still surfaces the error', () async {
    Get.put<SyncService>(_DeadSync());
    putAdmin();

    final ctrl = TourController()..diskCache = store;
    await ctrl.hydrateFromDiskCache();
    await ctrl.refreshTours();
    await pumpEventQueue();

    expect(ctrl.tours, isEmpty);
    expect(ctrl.hasError.value, isTrue);
    // Nothing on screen ⇒ nothing to label as saved.
    expect(ctrl.isShowingCachedData.value, isFalse);
  });

  test('a successful fetch takes the cached label down and saves', () async {
    final sync = _LiveSync();
    Get.put<SyncService>(sync);
    putAdmin();
    await seedCache();

    final ctrl = TourController()..diskCache = store;
    await ctrl.hydrateFromDiskCache();
    expect(ctrl.isShowingCachedData.value, isTrue);

    await ctrl.refreshTours();
    await pumpEventQueue();

    expect(ctrl.isShowingCachedData.value, isFalse);
    expect(ctrl.dataAsOf.value, isNotNull);

    await ctrl.ensureTourReadyForSeating('t1');
    await ctrl.saveToDiskCache();

    final saved = await store.read('tours_admin_a1');
    expect(saved, isNotNull);
    expect(saved!.tours, hasLength(1));
    final b1 = saved.tours.single.buses.firstWhere((b) => b.id == 'b1');
    expect(b1.layout, isNotNull);
    // The server answered `layout: null` for b2 during this session, and that
    // answer is what a later cold start needs to avoid a stuck skeleton.
    expect(saved.layoutKnownNullBusIds, contains('b2'));
  });

  test('hydration never paints over data that is already there', () async {
    Get.put<SyncService>(_DeadSync());
    putAdmin();
    await seedCache();

    final ctrl = TourController()..diskCache = store;
    ctrl.tours.assignAll([
      Tour(
        id: 't-live',
        title: 'Live',
        fromCity: 'Surat',
        toCity: 'Somnath',
        departureDate: DateTime(2026, 8, 1),
        pricePerSeat: 900,
      ),
    ]);

    await ctrl.hydrateFromDiskCache();

    expect(ctrl.tours.single.id, 't-live');
    expect(ctrl.isShowingCachedData.value, isFalse);
  });

  test('an anonymous viewer is neither read from nor written to disk',
      () async {
    Get.put<SyncService>(_DeadSync());
    Get.put<AuthController>(_AnonAuth());
    await seedCache();

    final ctrl = TourController()..diskCache = store;
    await ctrl.hydrateFromDiskCache();
    expect(ctrl.tours, isEmpty);
    expect(ctrl.isShowingCachedData.value, isFalse);

    ctrl.tours.assignAll([_seedTour()]);
    await ctrl.saveToDiskCache();
    // The admin's file is untouched — an anon session has no scope of its own
    // and must never write into someone else's.
    final still = await store.read('tours_admin_a1');
    expect(still!.tours.single.id, 't1');
  });

  test('logout wipes the cache off disk', () async {
    Get.put<SyncService>(_DeadSync());
    final auth = putAdmin()..adminAuth = _NoOpAdminAuth();
    await seedCache();
    expect(await store.read('tours_admin_a1'), isNotNull);

    await auth.clearSessionLocally();

    expect(await store.read('tours_admin_a1'), isNull);
    expect(
      Directory('${tmp.path}/tour_graph').existsSync(),
      isFalse,
      reason: 'the whole cache tree goes, not one admin\'s file',
    );

    // And a cold start after logout finds nothing to paint.
    final ctrl = TourController()..diskCache = store;
    await ctrl.hydrateFromDiskCache();
    expect(ctrl.tours, isEmpty);
  });

  test('logout drops the cache scope BEFORE it wipes the disk', () async {
    // The save is debounced ~1.2 s and resolves its scope from AuthController
    // after an await, so it can fire at any moment — including while logout is
    // inside the recursive directory delete. If the session still yields a scope
    // there, that save queues its write BEHIND the wipe and re-creates the
    // ex-admin's roster on disk moments after it was removed: the exact "stale
    // tours survive logout" defect the previous offline layer was deleted for.
    //
    // The wipe cannot defend against that on its own — the fix is that there is
    // no scope left to resolve by the time it runs. This asserts that ordering
    // at the only place it is observable.
    final probe = _ProbeStore(tmp);
    TourCacheStore.instance = probe;
    Get.put<SyncService>(_DeadSync());
    final auth = putAdmin()..adminAuth = _NoOpAdminAuth();

    final ctrl = TourController()..diskCache = probe;
    ctrl.tours.assignAll([_seedTour()]);

    String? scopeDuringWipe = 'not-run';
    Future<void>? lateSave;
    probe.onWipe = () {
      scopeDuringWipe = auth.cacheScopeAdminId;
      // …and the save that would have used it, fired at the worst moment.
      lateSave = ctrl.saveToDiskCache();
    };

    await auth.clearSessionLocally();
    await lateSave;

    expect(
      scopeDuringWipe,
      isNull,
      reason: 'the session must already be gone when the wipe runs, or a save '
          'racing it can still address — and re-create — the cache file',
    );
    expect(await probe.read('tours_admin_a1'), isNull);
    expect(Directory('${tmp.path}/tour_graph').existsSync(), isFalse);
  });

  test('a session whose admin lookup never landed cannot overwrite the cache',
      () async {
    Get.put<SyncService>(_DeadSync());
    Get.put<AuthController>(_AdminLookupTimedOut()
      ..isLoggedIn.value = true
      ..userRole.value = UserRole.admin);
    await seedCache();

    final ctrl = TourController()..diskCache = store;

    // READING is still allowed: this admin's own older graph, labelled saved.
    await ctrl.hydrateFromDiskCache();
    expect(ctrl.tours.single.id, 't1');
    expect(ctrl.isShowingCachedData.value, isTrue);

    // Now what an unfiltered fetch returns in this state — public tours that
    // belong to somebody else entirely.
    ctrl.tours.assignAll([
      Tour(
        id: 't-public',
        title: 'Someone else\'s tour',
        fromCity: 'Rajkot',
        toCity: 'Diu',
        departureDate: DateTime(2027, 8, 1),
        pricePerSeat: 800,
      ),
    ]);
    await ctrl.saveToDiskCache();

    final onDisk = await store.read('tours_admin_a1');
    expect(
      onDisk!.tours.single.id,
      't1',
      reason: 'a load that ran UNFILTERED because the admin lookup timed out '
          'must not replace the admin roster on disk with the public list',
    );
  });
}
