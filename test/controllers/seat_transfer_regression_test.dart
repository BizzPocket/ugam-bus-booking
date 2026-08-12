import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:occubusbooking/controllers/money_controller.dart';
import 'package:occubusbooking/controllers/tour_controller.dart';
import 'package:occubusbooking/models/bus_details.dart';
import 'package:occubusbooking/models/collection.dart';
import 'package:occubusbooking/models/passenger.dart';
import 'package:occubusbooking/models/request_line.dart';
import 'package:occubusbooking/models/seat_assignment.dart';
import 'package:occubusbooking/models/seat_layout.dart';
import 'package:occubusbooking/models/seat_type.dart';
import 'package:occubusbooking/models/tour.dart';
import 'package:occubusbooking/models/trip_type.dart';
import 'package:occubusbooking/services/sync_service.dart';

/// Two correctness defects on the seat-TRANSFER path, both of which the app
/// used to hide from the operator.
///
///  1. Moving a GROUPED rider to another bus is rerouted into the whole-group
///     cascade, whose `false` return value was DISCARDED. A destination that
///     could not hold the party reported "moved", the relocate banner was put
///     away, and nothing had moved. On a locked tour the operator then does not
///     re-notify the family, and they arrive at the wrong bus on the morning.
///     The same reroute also fired for a ONE-PERSON group, quietly throwing
///     away the exact seat the operator tapped.
///
///  2. `moveSeat` carries a paid rider's money to the destination bus.
///     `assignSeats` / `unassignSeats` did not — so the equally natural
///     two-tap transfer (free the seat on bus 1, place them on bus 2) billed
///     the FULL destination fare and stranded the cash on bus 1.
class _RecordingSync extends SyncService {
  final List<String> updates = <String>[];
  final List<Map<String, dynamic>> applies = <Map<String, dynamic>>[];

  /// Rows the on-demand `collections` read hands back.
  List<Map<String, dynamic>> collectionRows = const [];

  /// Every `collections` row payload written back to the server.
  final List<Map<String, dynamic>> collectionWrites = <Map<String, dynamic>>[];

  /// Simulates offline / a failed read on the collections fetch.
  bool collectionsFetchFails = false;

  /// True once the on-demand collections read was actually attempted.
  bool collectionsFetched = false;

  @override
  // ignore: must_call_super
  void onInit() {}

  @override
  Future<({List<Map<String, dynamic>> rows, bool failed, String? error})>
  smartFetch({
    required String table,
    required String cacheKey,
    String? select,
    Map<String, String>? filters,
    String? orderBy,
    int maxAge = 300000,
  }) async {
    if (table != 'collections') {
      return (rows: const <Map<String, dynamic>>[], failed: false, error: null);
    }
    collectionsFetched = true;
    if (collectionsFetchFails) {
      return (
        rows: const <Map<String, dynamic>>[],
        failed: true,
        error: 'offline',
      );
    }
    return (rows: collectionRows, failed: false, error: null);
  }

  @override
  Future<void> applySeatAssignments({
    required String tourId,
    required List<Map<String, dynamic>> assignments,
  }) async {
    applies.add({'tourId': tourId, 'assignments': assignments});
  }

  @override
  Future<void> smartUpdate({
    required String table,
    required String entityId,
    required Map<String, dynamic> data,
  }) async {
    updates.add('$table:$entityId');
    if (table == 'collections') collectionWrites.add(data);
  }

  @override
  Future<void> smartInsert({
    required String table,
    required String entityId,
    required Map<String, dynamic> data,
    String? cacheKey,
  }) async {}

  @override
  Future<void> invalidateCache(String key) async {}
}

/// A bus whose row 0 is the cheap band and row 1 the dear one — the shape the
/// price actually takes between two buses in practice. Three seater cells.
Bus _bus({
  required String id,
  required String name,
  required double row0,
  required double row1,
}) => Bus(
  id: id,
  name: name,
  pricePerSeat: row0,
  priceBands: [
    PriceBand(label: 'Front', fromRow: 0, toRow: 0, price: row0),
    PriceBand(label: 'Rear', fromRow: 1, toRow: 1, price: row1),
  ],
  layout: BusLayout(
    rows: 2,
    cols: 4,
    grid: [
      SeatCell(row: 0, col: 0, seatType: SeatType.seater, seatId: '${id}_A'),
      SeatCell(row: 1, col: 0, seatType: SeatType.seater, seatId: '${id}_B'),
      SeatCell(row: 1, col: 1, seatType: SeatType.seater, seatId: '${id}_C'),
    ],
  ),
);

/// A plain seater bus with [seats] cells, all in one row.
Bus _seaterBus(String id, String name, {required int seats}) => Bus(
  id: id,
  name: name,
  pricePerSeat: 100,
  layout: BusLayout(
    rows: 1,
    cols: seats,
    grid: [
      for (var i = 0; i < seats; i++)
        SeatCell(row: 0, col: i, seatType: SeatType.seater, seatId: '${id}_$i'),
    ],
  ),
);

Passenger _rider(
  String id, {
  required List<SeatAssignment> seats,
  String? groupId,
  int seaters = 1,
}) => Passenger(
  id: id,
  tourId: 't1',
  name: id,
  phone: '+910000000000',
  groupId: groupId,
  assignedSeats: seats,
  tripType: TripType.roundTrip,
  requestLines: [
    RequestLine(seatType: SeatType.seater, qty: seaters, leg: TripType.roundTrip),
  ],
);

Tour _tour({required List<Bus> buses, required List<Passenger> passengers}) =>
    Tour(
      id: 't1',
      title: 'Dwarka Yatra',
      fromCity: 'Surat',
      toCity: 'Dwarka',
      departureDate: DateTime(2026, 7, 1),
      pricePerSeat: 1500,
      buses: buses,
      passengers: passengers,
    );

/// Silences the WhatsApp confirmation greeting a fresh seat placement fires.
TourController _controller(Tour tour) {
  final ctrl = TourController();
  ctrl.tours.assignAll([tour]);
  ctrl.confirmedSender = (t, p) async => true;
  return ctrl;
}

void main() {
  // Controller guards toast through AppSnackBar, which reads Get.context —
  // that getter touches WidgetsBinding.instance and throws without a binding.
  // With the binding up and no navigator the toast no-ops, which is fine: the
  // DATA behaviour is what is asserted here.
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(Get.reset);

  // ── Defect 1: a failed cross-bus family move must not report success ──────

  group('cross-bus move of a grouped rider', () {
    test('reports failure and leaves the family put when the destination '
        'cannot fit them', () async {
      final sync = _RecordingSync();
      Get.put<SyncService>(sync);

      // Four people on one booking group, all seated on the roomy bus 1. Bus 2
      // has exactly two seats, so the party of four cannot possibly land there.
      final bus1 = _seaterBus('b1', 'Bus 1', seats: 8);
      final bus2 = _seaterBus('b2', 'Bus 2', seats: 2);
      final family = [
        for (var i = 0; i < 4; i++)
          _rider(
            'g$i',
            groupId: 'fam',
            seats: [SeatAssignment(busId: 'b1', seatId: 'b1_$i')],
          ),
      ];
      final ctrl = _controller(_tour(buses: [bus1, bus2], passengers: family));

      final outcome = await ctrl.moveSeat(
        tourId: 't1',
        passengerId: 'g0',
        busId: 'b1',
        fromSeatId: 'b1_0',
        toSeatId: 'b2_0',
        toBusId: 'b2',
      );

      // The move DID NOT happen, and the caller is told so — this is the bit
      // that used to be swallowed, leaving the UI free to say "moved".
      expect(outcome, SeatMoveOutcome.failed);

      // Every member is still on bus 1, on the seat they started from.
      final after = ctrl.getTour('t1')!.passengers;
      for (var i = 0; i < 4; i++) {
        final p = after.firstWhere((x) => x.id == 'g$i');
        expect(p.assignedSeats.map((a) => a.busId), everyElement('b1'));
        expect(p.assignedSeats.single.seatId, 'b1_$i');
      }
      // Nothing was persisted either — no half-applied move to clean up.
      expect(sync.updates, isEmpty);
      expect(sync.applies, isEmpty);
    });

    test('reports groupReseated (not a plain move) when the party does fit, '
        'because the tapped seat is not the seat used', () async {
      Get.put<SyncService>(_RecordingSync());

      final bus1 = _seaterBus('b1', 'Bus 1', seats: 8);
      final bus2 = _seaterBus('b2', 'Bus 2', seats: 8);
      final family = [
        for (var i = 0; i < 3; i++)
          _rider(
            'g$i',
            groupId: 'fam',
            seats: [SeatAssignment(busId: 'b1', seatId: 'b1_$i')],
          ),
      ];
      final ctrl = _controller(_tour(buses: [bus1, bus2], passengers: family));

      final outcome = await ctrl.moveSeat(
        tourId: 't1',
        passengerId: 'g0',
        busId: 'b1',
        fromSeatId: 'b1_0',
        toSeatId: 'b2_7',
        toBusId: 'b2',
      );

      // A real move — but the engine chose the berths, so the caller must say
      // "the group moved together" rather than "moved to seat b2_7".
      expect(outcome, SeatMoveOutcome.groupReseated);
      final after = ctrl.getTour('t1')!.passengers;
      for (final p in after) {
        expect(p.assignedSeats.map((a) => a.busId), everyElement('b2'));
      }
    });

    test('a ONE-person group is not a group: the tapped seat is honoured',
        () async {
      Get.put<SyncService>(_RecordingSync());

      final bus1 = _seaterBus('b1', 'Bus 1', seats: 8);
      final bus2 = _seaterBus('b2', 'Bus 2', seats: 8);
      // Carries a groupId, but nobody else on the tour shares it — the party
      // shrank to a single rider and the booking kept its group stamp.
      final solo = _rider(
        'solo',
        groupId: 'fam',
        seats: const [SeatAssignment(busId: 'b1', seatId: 'b1_0')],
      );
      final ctrl = _controller(_tour(buses: [bus1, bus2], passengers: [solo]));

      final outcome = await ctrl.moveSeat(
        tourId: 't1',
        passengerId: 'solo',
        busId: 'b1',
        fromSeatId: 'b1_0',
        toSeatId: 'b2_5',
        toBusId: 'b2',
      );

      expect(outcome, SeatMoveOutcome.moved);
      final p = ctrl.getTour('t1')!.passengers.single;
      expect(p.assignedSeats.single.busId, 'b2');
      expect(
        p.assignedSeats.single.seatId,
        'b2_5',
        reason: 'the engine cascade must not overrule the operator here',
      );
    });
  });

  // ── Defect 2: the two-step transfer must reconcile the money ──────────────

  group('free-then-place transfer across buses', () {
    // bus1 bands: row0 ₹1,300 / row1 ₹1,500. bus2: row0 ₹2,000 / row1 ₹2,200.
    Bus bus1() => _bus(id: 'bus1', name: 'Bus 1', row0: 1300, row1: 1500);
    Bus bus2() => _bus(id: 'bus2', name: 'Bus 2', row0: 2000, row1: 2200);

    /// The rider paid ₹1,500 in bus 1's rear band before the transfer.
    Map<String, dynamic> paidRow() => Collection(
      id: 'c1',
      tourId: 't1',
      busId: 'bus1',
      passengerId: 'p1',
      seatId: 'bus1_B',
      amountDue: 1500,
      amountReceived: 1500,
    ).toMap();

    test('bills only the difference, not the full destination fare', () async {
      final sync = _RecordingSync()..collectionRows = [paidRow()];
      Get.put<SyncService>(sync);
      Get.put<MoneyController>(MoneyController());

      final ctrl = _controller(
        _tour(
          buses: [bus1(), bus2()],
          passengers: [
            _rider(
              'p1',
              seats: const [SeatAssignment(busId: 'bus1', seatId: 'bus1_B')],
            ),
          ],
        ),
      );

      // The two taps an operator actually makes: free the seat on bus 1…
      await ctrl.unassignSeats('t1', 'p1');
      // …then place them on bus 2.
      await ctrl.assignSeats('t1', 'p1', const [
        SeatAssignment(busId: 'bus2', seatId: 'bus2_A'),
      ]);

      expect(
        sync.collectionsFetched,
        isTrue,
        reason: 'the placement has to look for money left behind on bus 1',
      );
      expect(sync.collectionWrites, hasLength(1));
      final row = sync.collectionWrites.single;
      expect(row['bus_id'], 'bus2', reason: 'the cash follows the rider');
      expect(row['seat_id'], 'bus2_A');
      expect(
        row['amount_due'],
        2000,
        reason: 're-priced at the destination bus band',
      );
      expect(
        row['amount_received'],
        1500,
        reason: 'cash already taken is never rewritten',
      );
      // The whole point: ₹500 left to collect, not ₹2,000 all over again while
      // ₹1,500 sits stranded on a bus the rider is no longer on.
      expect(
        (row['amount_due'] as num) - (row['amount_received'] as num),
        500,
      );
    });

    test('a first-ever placement does not pay for a collections read',
        () async {
      final sync = _RecordingSync()..collectionRows = [paidRow()];
      Get.put<SyncService>(sync);
      Get.put<MoneyController>(MoneyController());

      final ctrl = _controller(
        _tour(
          buses: [bus1(), bus2()],
          passengers: [_rider('p1', seats: const [])],
        ),
      );

      await ctrl.assignSeats('t1', 'p1', const [
        SeatAssignment(busId: 'bus2', seatId: 'bus2_A'),
      ]);

      // A rider who has never held a seat can have stranded nothing, so the
      // reconcile must not spend a round trip on every fresh placement.
      expect(sync.collectionsFetched, isFalse);
      expect(sync.collectionWrites, isEmpty);
    });

    test('says so instead of silently skipping when the money read fails',
        () async {
      final sync = _RecordingSync()
        ..collectionRows = [paidRow()]
        ..collectionsFetchFails = true;
      Get.put<SyncService>(sync);
      final money = Get.put<MoneyController>(MoneyController());

      final tour = _tour(
        buses: [bus1(), bus2()],
        passengers: [
          _rider(
            'p1',
            seats: const [SeatAssignment(busId: 'bus2', seatId: 'bus2_A')],
          ),
        ],
      );

      final deltas = await money.reconcileAfterSeatMove(
        tour: tour,
        passengerIds: const ['p1'],
        crossedBus: true,
      );

      // Offline is not "nothing to do": no row may be rewritten from a read we
      // never got, and the operator is warned rather than left believing the
      // fare on screen is the re-priced one.
      expect(deltas, isEmpty);
      expect(sync.collectionsFetched, isTrue);
      expect(sync.collectionWrites, isEmpty);
    });
  });
}
