import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/booking_mode.dart';
import 'package:occubusbooking/models/bus_details.dart';
import 'package:occubusbooking/models/bus_type.dart';
import 'package:occubusbooking/models/passenger.dart';
import 'package:occubusbooking/models/passenger_group.dart';
import 'package:occubusbooking/models/request_line.dart';
import 'package:occubusbooking/models/seat_assignment.dart';
import 'package:occubusbooking/models/seat_layout.dart';
import 'package:occubusbooking/models/seat_type.dart';
import 'package:occubusbooking/models/tour.dart';
import 'package:occubusbooking/models/tour_status.dart';
import 'package:occubusbooking/models/trip_type.dart';
import 'package:occubusbooking/services/tour_cache_store.dart';

/// A tour that exercises every field the cache has to survive: the columns
/// `Tour.toMap()` deliberately omits (booking mode, advance/UPI, bus id, the
/// timestamps), a bus WITH a grid, a bus WITHOUT one, price bands, and a
/// passenger carrying per-seat legs and a locked berth.
Tour _richTour({String id = 't1'}) {
  final layout = BusLayout.generate(busType: BusType.sleeper, totalSeats: 30);
  return Tour(
    id: id,
    title: 'Dwarka Darshan',
    fromCity: 'Surat',
    toCity: 'Dwarka',
    departureDate: DateTime(2026, 7, 1, 21, 30),
    departureTime: '21:30',
    returnDate: DateTime(2026, 7, 4, 6, 0),
    returnTime: '06:00',
    pricePerSeat: 1200,
    description: 'Three nights',
    status: TourStatus.assigning,
    ownerId: 'a1',
    busId: 'b1',
    handlerId: 'p1',
    createdBy: 'a1',
    isPublic: true,
    bookingMode: BookingMode.chart,
    advancePerBerthPaise: 50000,
    collectVpa: 'agent@upi',
    collectPayeeName: 'Ugam Tours',
    broadcastMessage: 'Seats open',
    broadcastImageUrl: 'https://example.test/hero.jpg',
    createdAt: DateTime(2026, 6, 1, 10),
    updatedAt: DateTime(2026, 6, 20, 11),
    buses: [
      Bus(
        id: 'b1',
        tourId: id,
        name: 'Bus 1',
        busNumber: 'GJ05HU7162',
        busType: 'Sleeper',
        totalSeatsLegacy: 30,
        pricePerSeat: 1200,
        busPrice: 42000,
        boardingPoint: 'Adajan',
        departureTime: '21:00',
        doubleSofaPrice: 2600,
        rearRows: 1,
        rearPrice: 900,
        priceBands: const [
          PriceBand(label: 'Front', fromRow: 0, toRow: 1, price: 1400),
        ],
        layout: layout,
        createdAt: DateTime(2026, 6, 1),
        updatedAt: DateTime(2026, 6, 2),
      ),
      // No grid, and the SERVER is the one that said so — the ambiguity the
      // known-null set exists to resolve.
      Bus(
        id: 'b2',
        tourId: id,
        name: 'Bus 2',
        busType: 'Seater',
        totalSeatsLegacy: 40,
        createdAt: DateTime(2026, 6, 1),
        updatedAt: DateTime(2026, 6, 2),
      ),
    ],
    passengers: [
      Passenger(
        id: 'p1',
        tourId: id,
        name: 'Asha Patel',
        phone: '+919876543210',
        tripType: TripType.roundTrip,
        groupId: 'g1',
        journeyDone: false,
        pickupLocationId: 'pl1',
        pickupLocationName: 'Adajan',
        requestLines: const [
          RequestLine(
            seatType: SeatType.doubleSofa,
            position: SeatPosition.lower,
            qty: 2,
            leg: TripType.roundTrip,
          ),
          RequestLine(
            seatType: SeatType.seater,
            qty: 1,
            leg: TripType.outboundOnly,
          ),
        ],
        assignedSeats: const [
          SeatAssignment(busId: 'b1', seatId: 'DL1', locked: true),
          SeatAssignment(
            busId: 'b1',
            seatId: 'DL1',
            leg: TripType.returnOnly,
          ),
        ],
        createdAt: DateTime(2026, 6, 5),
      ),
    ],
    groups: [
      PassengerGroup(
        id: 'g1',
        tourId: id,
        label: 'Patel & Shah',
        colorIndex: 2,
        createdAt: DateTime(2026, 6, 5),
      ),
    ],
  );
}

void main() {
  late Directory tmp;
  late TourCacheStore store;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('tour_cache_test');
    store = TourCacheStore.forDirectory(tmp);
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<TourGraphSnapshot?> roundTrip(
    Tour tour, {
    Set<String> knownNull = const {},
    String scope = 'tours_admin_a1',
  }) async {
    await store.write(TourGraphSnapshot(
      scopeKey: scope,
      savedAt: DateTime(2026, 6, 20, 12),
      tours: [tour],
      layoutKnownNullBusIds: knownNull,
    ));
    return store.read(scope);
  }

  test('round-trips the whole tour graph, including the seat grids', () async {
    final original = _richTour();
    final snap = await roundTrip(original, knownNull: {'b2'});
    expect(snap, isNotNull);

    final t = snap!.tours.single;
    expect(t.id, original.id);
    expect(t.title, original.title);
    expect(t.status, TourStatus.assigning);
    expect(t.ownerId, 'a1');
    expect(t.busId, 'b1');
    expect(t.handlerId, 'p1');
    expect(t.createdBy, 'a1');
    expect(t.description, 'Three nights');
    expect(t.departureTime, '21:30');
    expect(t.returnTime, '06:00');
    expect(t.departureDate, original.departureDate);
    expect(t.returnDate, original.returnDate);
    expect(t.createdAt, original.createdAt);
    expect(t.updatedAt, original.updatedAt);
    expect(t.broadcastMessage, 'Seats open');
    expect(t.broadcastImageUrl, 'https://example.test/hero.jpg');

    // The four fields `Tour.toMap()` drops. Round-tripping through it alone
    // would silently demote a chart-mode tour to request mode and blank its
    // UPI payee on the next cold start.
    expect(t.bookingMode, BookingMode.chart);
    expect(t.advancePerBerthPaise, 50000);
    expect(t.collectVpa, 'agent@upi');
    expect(t.collectPayeeName, 'Ugam Tours');
  });

  test('a cached bus keeps its grid cell-for-cell', () async {
    final original = _richTour();
    final snap = await roundTrip(original, knownNull: {'b2'});
    final cached = snap!.tours.single.buses.firstWhere((b) => b.id == 'b1');
    final source = original.buses.firstWhere((b) => b.id == 'b1');

    expect(cached.layout, isNotNull);
    expect(cached.layout!.rows, source.layout!.rows);
    expect(cached.layout!.totalSeats, source.layout!.totalSeats);
    expect(cached.allSeatIds, source.allSeatIds);
    expect(cached.seatCounts, source.seatCounts);
    for (var i = 0; i < source.layout!.grid.length; i++) {
      final a = source.layout!.grid[i];
      final b = cached.layout!.grid[i];
      expect(b.row, a.row);
      expect(b.col, a.col);
      expect(b.seatId, a.seatId);
      expect(b.seatType, a.seatType);
      expect(b.position, a.position);
      expect(b.reserved, a.reserved);
      expect(b.forward, a.forward);
    }

    // Pricing inputs ride along — a chart read offline still quotes the right
    // fare, and `amountDueForSeat` is what the money surfaces read.
    expect(cached.priceBands, source.priceBands);
    expect(cached.rearRows, 1);
    expect(cached.rearPrice, 900);
    expect(cached.doubleSofaPrice, 2600);
    expect(cached.busPrice, 42000);
    expect(cached.boardingPoint, 'Adajan');
    expect(cached.departureTime, '21:00');
    expect(cached.busNumber, 'GJ05HU7162');
  });

  test('the known-null bus set survives, and does NOT invent a grid', () async {
    final snap = await roundTrip(_richTour(), knownNull: {'b2'});
    expect(snap!.layoutKnownNullBusIds, {'b2'});
    final b2 = snap.tours.single.buses.firstWhere((b) => b.id == 'b2');
    // Still null — "the server says this bus has no grid" must round-trip as
    // BOTH facts: no layout, and a positive answer that there is none.
    expect(b2.layout, isNull);
    expect(b2.totalSeatsLegacy, 40);
  });

  test('passengers keep their request lines, seats, legs and lock', () async {
    final snap = await roundTrip(_richTour());
    final p = snap!.tours.single.passengers.single;
    expect(p.id, 'p1');
    expect(p.groupId, 'g1');
    expect(p.pickupLocationName, 'Adajan');
    expect(p.requestLines, hasLength(2));
    expect(p.requestLines.first.seatType, SeatType.doubleSofa);
    expect(p.requestLines.first.position, SeatPosition.lower);
    expect(p.requestLines.first.qty, 2);
    expect(p.requestLines.last.leg, TripType.outboundOnly);
    expect(p.assignedSeats, hasLength(2));
    expect(p.assignedSeats.first.locked, isTrue);
    // Per-seat leg is the canonical source for tint + money + capacity, so a
    // cache that loses it silently re-prices a one-way berth as round-trip.
    expect(p.assignedSeats.last.leg, TripType.returnOnly);
    expect(snap.tours.single.groups.single.label, 'Patel & Shah');
    expect(snap.tours.single.groups.single.colorIndex, 2);
  });

  test('a file written for another scope is refused, not served', () async {
    await roundTrip(_richTour(), scope: 'tours_admin_a1');
    // Same file, asked for under a different admin's key.
    final file = File('${tmp.path}/tour_graph/tours_admin_a1.json');
    final other = File('${tmp.path}/tour_graph/tours_admin_a2.json');
    file.copySync(other.path);

    expect(await store.read('tours_admin_a2'), isNull);
    // …and the offending file is gone, so it cannot be re-offered.
    expect(other.existsSync(), isFalse);
  });

  test('a corrupt file reads as no cache and is deleted', () async {
    await roundTrip(_richTour());
    final file = File('${tmp.path}/tour_graph/tours_admin_a1.json');
    file.writeAsStringSync('{"schema":1,"scope":"tours_admin_a1","tou');

    expect(await store.read('tours_admin_a1'), isNull);
    expect(file.existsSync(), isFalse);
  });

  test('a file from another schema version is discarded', () async {
    await roundTrip(_richTour());
    final file = File('${tmp.path}/tour_graph/tours_admin_a1.json');
    final map = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    map['schema'] = TourCacheStore.schemaVersion + 1;
    file.writeAsStringSync(jsonEncode(map));

    expect(await store.read('tours_admin_a1'), isNull);
  });

  test('clearAll drops every scope, not just one', () async {
    await roundTrip(_richTour(id: 't1'), scope: 'tours_admin_a1');
    await roundTrip(_richTour(id: 't2'), scope: 'tours_admin_a2');
    expect(await store.read('tours_admin_a1'), isNotNull);
    expect(await store.read('tours_admin_a2'), isNotNull);

    await store.clearAll();

    expect(await store.read('tours_admin_a1'), isNull);
    expect(await store.read('tours_admin_a2'), isNull);
    // A write after the wipe must still work — clearAll removes the directory.
    await roundTrip(_richTour(), scope: 'tours_admin_a1');
    expect(await store.read('tours_admin_a1'), isNotNull);
  });

  test('with no cache directory available the store stays dormant', () async {
    final dormant = TourCacheStore(directory: () async => null);
    await dormant.write(TourGraphSnapshot(
      scopeKey: 'tours_admin_a1',
      savedAt: DateTime(2026, 6, 20),
      tours: [_richTour()],
    ));
    expect(await dormant.read('tours_admin_a1'), isNull);
    await dormant.clearAll(); // must not throw
  });
}
