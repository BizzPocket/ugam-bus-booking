import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/passenger.dart';
import 'package:occubusbooking/models/request_line.dart';
import 'package:occubusbooking/models/seat_assignment.dart';
import 'package:occubusbooking/models/seat_layout.dart';
import 'package:occubusbooking/models/seat_type.dart';
import 'package:occubusbooking/models/trip_type.dart';
import 'package:occubusbooking/utils/aisle_order.dart';
import 'package:occubusbooking/utils/boarding_stops.dart';

/// Stop-by-stop boarding is what replaces the flat attendance list. The
/// "which stop are we at" answer is derived rather than stored, so it is
/// pinned down here before any widget depends on it.
void main() {
  Passenger rider(String name, {String? pickupId, String? pickupName}) =>
      Passenger(
        id: name,
        tourId: 'tour-1',
        name: name,
        phone: '900000000$name',
        pickupLocationId: pickupId,
        pickupLocationName: pickupName,
      );

  // Adajan is serial 1, Varachha 2, Kamrej 3 — the admin's route order, which
  // is deliberately NOT alphabetical so the ranking is actually exercised.
  int? rank(String? id, String name) =>
      const {'adajan': 1, 'varachha': 2, 'kamrej': 3}[id];

  final riders = [
    rider('1', pickupId: 'kamrej', pickupName: 'Kamrej'),
    rider('2', pickupId: 'adajan', pickupName: 'Adajan'),
    rider('3', pickupId: 'varachha', pickupName: 'Varachha'),
    rider('4', pickupId: 'adajan', pickupName: 'Adajan'),
  ];

  group('buildBoardingProgress', () {
    test('orders stops by the admin route order, not the alphabet', () {
      final p = buildBoardingProgress(
        riders,
        isPresent: (_) => false,
        rankOf: rank,
      );
      expect(p.stops.map((s) => s.locationName).toList(), [
        'Adajan',
        'Varachha',
        'Kamrej',
      ]);
    });

    test('the current stop is the first one not fully boarded', () {
      // Both Adajan riders aboard, nobody else.
      final p = buildBoardingProgress(
        riders,
        isPresent: (r) => r.id == '2' || r.id == '4',
        rankOf: rank,
      );
      expect(p.stops.first.isComplete, isTrue);
      expect(p.currentIndex, 1);
      expect(p.current!.locationName, 'Varachha');
    });

    test('counts roll up across stops', () {
      final p = buildBoardingProgress(
        riders,
        isPresent: (r) => r.id == '2',
        rankOf: rank,
      );
      expect(p.total, 4);
      expect(p.boarded, 1);
      expect(p.pending, 3);
      expect(p.stopsComplete, 0);
      expect(p.isComplete, isFalse);
    });

    test('everyone aboard leaves no current stop', () {
      final p = buildBoardingProgress(
        riders,
        isPresent: (_) => true,
        rankOf: rank,
      );
      expect(p.currentIndex, isNull);
      expect(p.current, isNull);
      expect(p.isComplete, isTrue);
      expect(p.stopsComplete, 3);
    });

    // Forgiving on purpose: a rider who walks up the route to meet the bus
    // must not drag the handler back to a stop they have finished with.
    test('boarding out of order does not move the current stop backwards', () {
      // The Kamrej rider (last stop) boards early; Adajan is still pending.
      final p = buildBoardingProgress(
        riders,
        isPresent: (r) => r.id == '1',
        rankOf: rank,
      );
      expect(p.current!.locationName, 'Adajan');
      expect(p.stops.last.boarded, 1);
    });

    test('riders with no pickup point fall into a last, unnamed stop', () {
      final p = buildBoardingProgress(
        [...riders, rider('5')],
        isPresent: (_) => false,
        rankOf: rank,
      );
      expect(p.stops.last.isUnassigned, isTrue);
      expect(p.stops.last.total, 1);
    });

    test('per-stop pending is what the handler reads before leaving', () {
      final p = buildBoardingProgress(
        riders,
        isPresent: (r) => r.id == '2',
        rankOf: rank,
      );
      final adajan = p.stops.first;
      expect(adajan.total, 2);
      expect(adajan.boarded, 1);
      expect(adajan.pending, 1);
      expect(adajan.isComplete, isFalse);
    });

    test('an empty roster is complete-free rather than crashing', () {
      final p = buildBoardingProgress(const [], isPresent: (_) => true);
      expect(p.stops, isEmpty);
      expect(p.currentIndex, isNull);
      expect(p.total, 0);
      // total == 0 must not read as "everyone is aboard".
      expect(p.isComplete, isFalse);
    });

    test('riders within a stop follow bus seat order, not name order', () {
      const busId = 'bus-1';
      final layout = BusLayout(
        rows: 3,
        cols: SeatGridCols.count,
        grid: [
          for (var r = 0; r < 3; r++) ...[
            SeatCell(
              row: r,
              col: SeatGridCols.singleLower,
              seatType: SeatType.singleSofa,
              position: SeatPosition.lower,
              seatId: 'SL$r',
            ),
            SeatCell(
              row: r,
              col: SeatGridCols.singleUpper,
              seatType: SeatType.singleSofa,
              position: SeatPosition.upper,
              seatId: 'SU$r',
            ),
          ],
        ],
      );
      Passenger seated(String id, String seatId, String pickup) => Passenger(
        id: id,
        tourId: 'tour-1',
        name: id,
        phone: '9000000000',
        pickupLocationId: 'adajan',
        pickupLocationName: pickup,
        assignedSeats: [SeatAssignment(busId: busId, seatId: seatId)],
        requestLines: [
          RequestLine(
            seatType: SeatType.singleSofa,
            qty: 1,
            leg: TripType.roundTrip,
          ),
        ],
        tripType: TripType.roundTrip,
      );
      // Names are A→Z but seats are SU2, SL0, SU1 — aisle order is SL0, SU0, …
      final roster = [
        seated('z', 'SU2', 'Adajan'),
        seated('a', 'SL0', 'Adajan'),
        seated('m', 'SU1', 'Adajan'),
      ];
      final p = buildBoardingProgress(
        roster,
        isPresent: (_) => false,
        rankOf: rank,
        seatSortBusId: busId,
        seatSortLayout: layout,
      );
      expect(p.stops.single.riders.map((r) => r.id).toList(), ['a', 'm', 'z']);
    });

    test('booking group members stay adjacent when their seats are not', () {
      const busId = 'bus-1';
      final layout = BusLayout(
        rows: 4,
        cols: SeatGridCols.count,
        grid: [
          for (var r = 0; r < 4; r++)
            SeatCell(
              row: r,
              col: SeatGridCols.singleLower,
              seatType: SeatType.singleSofa,
              position: SeatPosition.lower,
              seatId: 'SL$r',
            ),
        ],
      );
      const group = 'fam';
      Passenger rider(String id, String seat) => Passenger(
        id: id,
        tourId: 'tour-1',
        name: id,
        phone: '9000000000',
        groupId: group,
        pickupLocationId: 'adajan',
        pickupLocationName: 'Adajan',
        assignedSeats: [SeatAssignment(busId: busId, seatId: seat)],
        requestLines: [
          RequestLine(
            seatType: SeatType.singleSofa,
            qty: 1,
            leg: TripType.roundTrip,
          ),
        ],
        tripType: TripType.roundTrip,
      );
      final roster = [
        rider('early', 'SL0'),
        rider('late', 'SL3'),
        Passenger(
          id: 'solo',
          tourId: 'tour-1',
          name: 'solo',
          phone: '9000000000',
          pickupLocationId: 'adajan',
          pickupLocationName: 'Adajan',
          assignedSeats: [SeatAssignment(busId: busId, seatId: 'SL1')],
          requestLines: [
            RequestLine(
              seatType: SeatType.singleSofa,
              qty: 1,
              leg: TripType.roundTrip,
            ),
          ],
          tripType: TripType.roundTrip,
        ),
      ];
      final p = buildBoardingProgress(
        roster,
        isPresent: (_) => false,
        rankOf: rank,
        seatSortBusId: busId,
        seatSortLayout: layout,
      );
      final ids = p.stops.single.riders.map((r) => r.id).toList();
      expect(ids.indexOf('early'), lessThan(ids.indexOf('late')));
      expect(ids.indexOf('early') + 1, ids.indexOf('late'));
    });

    test('seatIdsOnBus lists every berth in walk order', () {
      const busId = 'bus-1';
      final layout = BusLayout(
        rows: 2,
        cols: SeatGridCols.count,
        grid: [
          SeatCell(
            row: 0,
            col: SeatGridCols.singleLower,
            seatType: SeatType.singleSofa,
            position: SeatPosition.lower,
            seatId: 'SL0',
          ),
          SeatCell(
            row: 1,
            col: SeatGridCols.singleLower,
            seatType: SeatType.singleSofa,
            position: SeatPosition.lower,
            seatId: 'SL1',
          ),
        ],
      );
      final walk = AisleWalk.of(layout);
      final p = Passenger(
        id: 'p1',
        tourId: 't1',
        name: 'Pat',
        phone: '9',
        assignedSeats: [
          SeatAssignment(busId: busId, seatId: 'SL1'),
          SeatAssignment(busId: busId, seatId: 'SL0'),
        ],
      );
      expect(seatIdsOnBus(p, busId, walk: walk), ['SL0', 'SL1']);
    });
  });
}
