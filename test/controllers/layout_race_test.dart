import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:occubusbooking/controllers/auth_controller.dart';
import 'package:occubusbooking/controllers/tour_controller.dart';
import 'package:occubusbooking/models/bus_details.dart';
import 'package:occubusbooking/models/bus_type.dart';
import 'package:occubusbooking/models/passenger.dart';
import 'package:occubusbooking/models/seat_assignment.dart';
import 'package:occubusbooking/models/seat_layout.dart';
import 'package:occubusbooking/models/tour.dart';
import 'package:occubusbooking/models/tour_status.dart';
import 'package:occubusbooking/models/trip_type.dart';
import 'package:occubusbooking/services/sync_service.dart';

/// Regression suite for the intermittent seat chart.
///
/// The symptom from the field: the same bus, in the same session, sometimes
/// rendered its 37 riders, sometimes sat on a loading skeleton, and sometimes
/// declared "no seat plan yet". Nothing about the bus changed between those
/// three outcomes — what changed was WHICH of two sources of truth the UI was
/// reading when it made the call:
///
///   1. the layout-fetched marks, which [TourController.layoutsLoadedFor]
///      answers from ALONE, and which every chart surface uses to choose
///      between "still loading" and the hard, final "no seat plan";
///   2. `bus.layout`, the grid actually held on the [Bus].
///
/// Those two drifted apart three different ways: a bus the layout response
/// simply omitted was latched as fetched anyway, a grid that landed during the
/// relations round-trip was overwritten by a pre-`await` snapshot, and nothing
/// ever checked that the mark and the grid agreed.
///
/// Every assertion below goes through the PUBLIC surface — `layoutsLoadedFor`,
/// the buses actually held in `tours`, and the id lists the sync layer was
/// ASKED for. That is deliberate: the marks are private, and what the user
/// experiences is exactly these three things.
class _NoInitAuth extends AuthController {
  @override
  // ignore: must_call_super
  void onInit() {}

  @override
  Future<void> get whenRestored => Future.value();
}

/// A sync fake with the two knobs the bug lives between: what the server holds
/// per bus, and what the response actually carries.
class _LayoutSync extends SyncService {
  /// The grid the server holds per bus id. A key present with a NULL value is
  /// the server positively answering "this bus has no grid" — the wipe state
  /// `recoverBusLayoutFor` repairs. A key that is absent means the row is not
  /// returned at all, which is a different thing entirely.
  final Map<String, BusLayout?> layoutOnServer = {};

  /// Ids to drop from the layout response even though they were requested — a
  /// short page, an RLS-filtered row, an id racing a concurrent insert. The
  /// response comes back a row short and says nothing about that bus.
  Set<String> omitFromResponse = {};

  /// Bus / passenger rows Phase 2 hands back. Bus rows never carry `layout`:
  /// cold start deliberately omits the jsonb (~71% of the bus payload).
  List<Map<String, dynamic>> busRows = [];
  List<Map<String, dynamic>> passengerRows = [];

  /// Every id list [fetchBusLayouts] was asked for, in order. This is how a
  /// test sees "was it re-requested?" without touching a private set.
  final List<List<String>> layoutRequests = [];

  /// Per bus: did the LAST answer the server gave say "no grid"? The only
  /// excuse a null layout has for reporting itself as loaded.
  final Map<String, bool> lastAnswerWasNull = {};

  /// Runs inside [fetchRelationsForTours] before it returns — the exact window
  /// in which the background layout prefetch writes grids into `tours` while a
  /// foreground refresh is suspended on this very request.
  Future<void> Function()? duringRelations;

  final List<({String entityId, Map<String, dynamic> fields})> patches = [];

  @override
  // ignore: must_call_super
  void onInit() {}

  @override
  Future<List<Map<String, dynamic>>> fetchTourRows({
    Map<String, String>? filters,
    String? orderBy,
  }) async {
    return [
      {
        'id': 't1',
        'title': 'Dwarka',
        'from_city': 'Surat',
        'to_city': 'Dwarka',
        'departure_date': '2026-09-01',
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
    await duringRelations?.call();
    return (
      passengers: passengerRows,
      buses: busRows,
      groups: const <Map<String, dynamic>>[],
    );
  }

  @override
  Future<List<Map<String, dynamic>>> fetchBusLayouts(List<String> busIds) async {
    layoutRequests.add(List.of(busIds));
    final rows = <Map<String, dynamic>>[];
    for (final id in busIds) {
      // Asked for, but the payload does not carry it: the server said NOTHING
      // about this bus, which is not the same as saying it has no grid.
      if (omitFromResponse.contains(id) || !layoutOnServer.containsKey(id)) {
        continue;
      }
      final layout = layoutOnServer[id];
      lastAnswerWasNull[id] = layout == null;
      rows.add({'id': id, 'layout': layout?.toMap()});
    }
    return rows;
  }

  @override
  Future<void> updatePatch({
    required String table,
    required String entityId,
    required Map<String, dynamic> fields,
  }) async {
    patches.add((entityId: entityId, fields: Map.of(fields)));
  }
}

BusLayout _grid({int totalSeats = 30}) => BusLayout.generate(
      busType: BusType.sleeper,
      totalSeats: totalSeats,
    );

Bus _bus(String id, {BusLayout? layout, int totalSeats = 30}) => Bus(
      id: id,
      tourId: 't1',
      name: id,
      busType: 'Sleeper',
      totalSeatsLegacy: totalSeats,
      layout: layout,
    );

/// The cold-start projection of the same bus: every column except the grid.
Map<String, dynamic> _busRow(String id, {int totalSeats = 30}) => {
      'id': id,
      'tour_id': 't1',
      'name': id,
      'bus_type': 'Sleeper',
      'total_seats': totalSeats,
    };

Tour _tour({
  required List<Bus> buses,
  List<Passenger> passengers = const [],
}) =>
    Tour(
      id: 't1',
      title: 'Dwarka',
      fromCity: 'Surat',
      toCity: 'Dwarka',
      departureDate: DateTime(2026, 9, 1),
      status: TourStatus.assigning,
      pricePerSeat: 1200,
      buses: buses,
      passengers: passengers,
    );

/// THE invariant, stated once and checked everywhere.
///
/// `layoutsLoadedFor` is what every chart surface reads to choose between a
/// skeleton and a hard "no seat plan". A true flag standing next to a bus that
/// holds no grid is therefore a wrong, permanent answer — the 37-rider bus that
/// claimed to have no seat plan — UNLESS the server is the one that said the
/// grid is gone, which is the only case where "no seat plan" is the truth.
void _expectFlagAgreesWithGrids(TourController ctrl, _LayoutSync sync) {
  if (!ctrl.layoutsLoadedFor('t1')) return;
  for (final b in ctrl.getTour('t1')?.buses ?? const <Bus>[]) {
    if (b.layout != null) continue;
    expect(
      sync.lastAnswerWasNull[b.id],
      isTrue,
      reason: 'layoutsLoadedFor reports every grid resolved, but ${b.id} holds '
          'none and the server never answered that it had none — that renders '
          '"no seat plan" for a bus whose grid was simply never fetched',
    );
  }
}

void main() {
  // refreshTours' failure paths and _write both reach AppSnackBar, which reads
  // Get.overlayContext and therefore WidgetsBinding.instance.
  TestWidgetsFlutterBinding.ensureInitialized();

  late _LayoutSync sync;
  late TourController ctrl;

  setUp(() {
    Get.reset();
    sync = _LayoutSync();
    Get.put<SyncService>(sync);
    Get.put<AuthController>(_NoInitAuth());
    ctrl = TourController();
  });

  tearDown(Get.reset);

  group('a layout response that omits a bus', () {
    test('does not latch the omitted bus, and re-requests it later', () async {
      ctrl.tours.assignAll([
        _tour(buses: [_bus('b1'), _bus('b2')])
      ]);
      sync.layoutOnServer.addAll({'b1': _grid(), 'b2': _grid()});
      // Both grids exist server-side; the RESPONSE just doesn't carry b2's row.
      sync.omitFromResponse = {'b2'};

      await ctrl.ensureBusLayoutsForTour('t1');

      expect(sync.layoutRequests, [
        ['b1', 'b2']
      ]);
      expect(ctrl.getTour('t1')!.buses.first.layout, isNotNull);
      expect(ctrl.getTour('t1')!.buses.last.layout, isNull);
      expect(
        ctrl.layoutsLoadedFor('t1'),
        isFalse,
        reason: 'a bus the response never mentioned has NOT been resolved; '
            'claiming otherwise is what froze the chart on "no seat plan"',
      );
      _expectFlagAgreesWithGrids(ctrl, sync);

      // The next attempt — a chart open, a refresh, anything — must ask again.
      sync.omitFromResponse = {};
      await ctrl.ensureBusLayoutsForTour('t1');

      expect(
        sync.layoutRequests.last,
        ['b2'],
        reason: 'exactly the one bus still missing, and it must be asked for; '
            'the latch made `need` empty forever and the grid never returned',
      );
      expect(ctrl.getTour('t1')!.buses.last.layout, isNotNull);
      expect(ctrl.layoutsLoadedFor('t1'), isTrue);
      _expectFlagAgreesWithGrids(ctrl, sync);
    });

    test('a bus omitted twice is asked for twice, never written off', () async {
      ctrl.tours.assignAll([
        _tour(buses: [_bus('b1')])
      ]);
      sync.layoutOnServer['b1'] = _grid();
      sync.omitFromResponse = {'b1'};

      await ctrl.ensureBusLayoutsForTour('t1');
      await ctrl.ensureBusLayoutsForTour('t1');

      expect(sync.layoutRequests, hasLength(2));
      expect(
        ctrl.layoutsLoadedFor('t1'),
        isFalse,
        reason: 'the honest answer while a grid is missing and unexplained is '
            '"still loading", which is a skeleton the next fetch can resolve',
      );
      _expectFlagAgreesWithGrids(ctrl, sync);
    });
  });

  group('a server that answers layout: null', () {
    test('latches, stops asking, and reports loaded', () async {
      ctrl.tours.assignAll([
        _tour(buses: [_bus('b1')])
      ]);
      // The wipe: the row exists, the column is NULL. "No seat plan" is now the
      // TRUE answer, and re-asking would burn a request on every refresh.
      sync.layoutOnServer['b1'] = null;
      sync.busRows = [_busRow('b1')];

      await ctrl.ensureBusLayoutsForTour('t1');

      expect(sync.layoutRequests, [
        ['b1']
      ]);
      expect(ctrl.getTour('t1')!.buses.single.layout, isNull);
      expect(
        ctrl.layoutsLoadedFor('t1'),
        isTrue,
        reason: 'the UI must be free to say "seat plan lost" — a forever '
            'skeleton hides the damage instead of offering the repair',
      );
      _expectFlagAgreesWithGrids(ctrl, sync);

      await ctrl.ensureBusLayoutsForTour('t1');
      expect(sync.layoutRequests, hasLength(1));

      // And it survives a whole refresh cycle: the merge must not mistake a
      // known-empty bus for one whose grid we merely failed to hold, or every
      // refresh re-asks for a grid that does not exist.
      await ctrl.refreshTours();
      await pumpEventQueue();

      expect(sync.layoutRequests, hasLength(1));
      expect(ctrl.layoutsLoadedFor('t1'), isTrue);
      _expectFlagAgreesWithGrids(ctrl, sync);
    });
  });

  group('the race: a grid that lands during the relations fetch', () {
    test('survives the Phase-2 merge', () async {
      // The tour is already on screen, its grid not yet paid for.
      ctrl.tours.assignAll([
        _tour(buses: [_bus('b1')])
      ]);
      sync.busRows = [_busRow('b1')];
      // If anything re-asks, all the server has is "no grid" — so the chart can
      // only survive here by KEEPING what the prefetch already put in memory.
      sync.layoutOnServer['b1'] = null;

      final grid = _grid();
      sync.duringRelations = () async {
        // Exactly what _prefetchLayoutsForHydratedTours does: writes the grid
        // straight into the live `tours` list while the refresh is suspended on
        // fetchRelationsForTours. Re-attaching layouts from the snapshot taken
        // BEFORE that await put this null back and kept the id latched, which
        // is the intermittent "no seat plan" on a bus that rendered a moment
        // earlier — a race, not a fetch failure.
        final idx = ctrl.tours.indexWhere((t) => t.id == 't1');
        ctrl.tours[idx] = ctrl.tours[idx].copyWith(
          buses: [ctrl.tours[idx].buses.single.copyWith(layout: grid)],
        );
      };

      await ctrl.refreshTours();
      await pumpEventQueue();

      expect(
        ctrl.getTour('t1')!.buses.single.layout,
        isNotNull,
        reason: 'the grid landed before the merge ran; the merge threw it away',
      );
      expect(
        sync.layoutRequests,
        isEmpty,
        reason: 'the grid was in hand the whole time — a request here means the '
            'merge dropped it, and this server has nothing to give back',
      );
      expect(ctrl.layoutsLoadedFor('t1'), isTrue);
      _expectFlagAgreesWithGrids(ctrl, sync);
    });

    test('and so does a second bus whose grid landed in the same window',
        () async {
      ctrl.tours.assignAll([
        _tour(buses: [_bus('b1'), _bus('b2')])
      ]);
      sync.busRows = [_busRow('b1'), _busRow('b2')];
      sync.layoutOnServer.addAll({'b1': null, 'b2': null});

      final grid = _grid();
      sync.duringRelations = () async {
        final idx = ctrl.tours.indexWhere((t) => t.id == 't1');
        ctrl.tours[idx] = ctrl.tours[idx].copyWith(
          buses: [
            for (final b in ctrl.tours[idx].buses) b.copyWith(layout: grid),
          ],
        );
      };

      await ctrl.refreshTours();
      await pumpEventQueue();

      expect(
        ctrl.getTour('t1')!.buses.map((b) => b.layout),
        everyElement(isNotNull),
      );
      expect(sync.layoutRequests, isEmpty);
      _expectFlagAgreesWithGrids(ctrl, sync);
    });
  });

  group('the flag and the grids never disagree', () {
    test('across an omitted row, a refresh, and a genuine wipe', () async {
      ctrl.tours.assignAll([
        _tour(buses: [_bus('b1'), _bus('b2')])
      ]);
      sync.busRows = [_busRow('b1'), _busRow('b2')];
      sync.layoutOnServer.addAll({'b1': _grid(), 'b2': _grid()});
      sync.omitFromResponse = {'b2'};

      await ctrl.ensureBusLayoutsForTour('t1');
      _expectFlagAgreesWithGrids(ctrl, sync);
      expect(ctrl.layoutsLoadedFor('t1'), isFalse);

      // A full refresh must not turn the unresolved bus into a resolved one.
      await ctrl.refreshTours();
      await pumpEventQueue();
      _expectFlagAgreesWithGrids(ctrl, sync);
      expect(ctrl.layoutsLoadedFor('t1'), isFalse);
      expect(
        ctrl.getTour('t1')!.buses.first.layout,
        isNotNull,
        reason: 'the grid we already paid for must survive every refresh',
      );

      // Now b2's grid is genuinely gone server-side. Only NOW may the flag go
      // true next to a null layout.
      sync.omitFromResponse = {};
      sync.layoutOnServer['b2'] = null;
      await ctrl.ensureBusLayoutsForTour('t1');

      expect(ctrl.layoutsLoadedFor('t1'), isTrue);
      expect(ctrl.getTour('t1')!.buses.last.layout, isNull);
      _expectFlagAgreesWithGrids(ctrl, sync);
    });
  });

  group('a bus that disappears from the server', () {
    test('leaves no mark behind, so its grid is re-fetched if it returns',
        () async {
      sync.busRows = [_busRow('b1')];
      sync.layoutOnServer['b1'] = _grid();

      await ctrl.refreshTours();
      await pumpEventQueue();
      expect(ctrl.getTour('t1')!.buses.single.layout, isNotNull);
      expect(sync.layoutRequests, hasLength(1));

      // Deleted server-side.
      sync.busRows = [];
      await ctrl.refreshTours();
      await pumpEventQueue();
      expect(ctrl.getTour('t1')!.buses, isEmpty);
      expect(sync.layoutRequests, hasLength(1));

      // Re-added later (same id). A leaked mark would leave it grid-less and
      // never re-request it.
      sync.busRows = [_busRow('b1')];
      await ctrl.refreshTours();
      await pumpEventQueue();

      expect(sync.layoutRequests, hasLength(2));
      expect(sync.layoutRequests.last, ['b1']);
      expect(ctrl.getTour('t1')!.buses.single.layout, isNotNull);
      _expectFlagAgreesWithGrids(ctrl, sync);
    });
  });

  group('recoverBusLayoutFor', () {
    /// The wiped bus, with its riders still holding seat ids from the grid that
    /// no longer exists — the evidence the repair rebuilds from.
    ({Tour tour, List<Passenger> riders}) wiped() {
      final original = BusLayout.generate(
        busType: BusType.sleeper,
        totalSeats: 37,
        singleSofaCount: 13,
      );
      final ids = original.allSeatIds;
      final riders = [
        for (var i = 0; i < ids.length; i++)
          Passenger(
            id: 'p$i',
            tourId: 't1',
            name: 'Rider $i',
            phone: '+91987654${1000 + i}',
            assignedSeats: [SeatAssignment(busId: 'b1', seatId: ids[i])],
          ),
      ];
      return (
        tour: _tour(
          buses: [_bus('b1', totalSeats: 37)],
          passengers: riders,
        ),
        riders: riders,
      );
    }

    test('a repaired bus stops being treated as known-empty', () async {
      final fixture = wiped();
      ctrl.tours.assignAll([fixture.tour]);
      sync.busRows = [_busRow('b1', totalSeats: 37)];
      sync.passengerRows = [for (final p in fixture.riders) p.toMap()];
      sync.layoutOnServer['b1'] = null;

      await ctrl.ensureBusLayoutsForTour('t1');
      expect(ctrl.layoutsLoadedFor('t1'), isTrue);
      expect(ctrl.getTour('t1')!.buses.single.layout, isNull);
      _expectFlagAgreesWithGrids(ctrl, sync);

      final result = await ctrl.recoverBusLayoutFor('t1', 'b1');
      expect(result.recovered, isTrue, reason: result.reason);
      // The repair wrote the grid, so the server holds one now.
      sync.layoutOnServer['b1'] = result.layout;

      // What every chart surface does on open — and where "known empty" has to
      // be dropped, because it is no longer true.
      await ctrl.ensureBusLayoutsForTour('t1');
      final asked = sync.layoutRequests.length;

      // Now the in-memory grid is lost the way a merge can lose it: the bus
      // rows never carry the jsonb and this time nothing re-attaches it.
      sync.duringRelations = () async {
        final idx = ctrl.tours.indexWhere((t) => t.id == 't1');
        ctrl.tours[idx] = ctrl.tours[idx].copyWith(
          buses: [_bus('b1', totalSeats: 37)],
        );
      };
      await ctrl.refreshTours();
      await pumpEventQueue();

      expect(
        sync.layoutRequests.skip(asked).expand((ids) => ids),
        contains('b1'),
        reason: 'a repaired bus must be re-asked, not written off as empty on '
            'the strength of an answer the repair made obsolete',
      );
      expect(ctrl.getTour('t1')!.buses.single.layout, isNotNull);
      expect(ctrl.layoutsLoadedFor('t1'), isTrue);
      _expectFlagAgreesWithGrids(ctrl, sync);
    });

    test('repairs the bus the wipe left behind, moving nobody', () async {
      final fixture = wiped();
      ctrl.tours.assignAll([fixture.tour]);
      sync.layoutOnServer['b1'] = null;

      final result = await ctrl.recoverBusLayoutFor('t1', 'b1');

      expect(result.recovered, isTrue, reason: result.reason);
      final rebuilt = ctrl.getTour('t1')!.buses.single.layout!;
      final seatIds = rebuilt.allSeatIds.toSet();
      for (final p in ctrl.getTour('t1')!.passengers) {
        for (final a in p.assignedSeats) {
          expect(seatIds.contains(a.seatId), isTrue);
        }
      }
      expect(sync.patches.single.fields.keys, ['layout']);
    });
  });
}
