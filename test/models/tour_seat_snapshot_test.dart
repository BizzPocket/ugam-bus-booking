import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/tour_seat_snapshot.dart';

/// Unit tests for the [TourSeatSnapshot] DB <-> model serialization and the
/// small helpers around it. These exercise the stable JSON contract the
/// past-tour seat-history view reads: the `leg` wire string, the
/// `snapshot_data` `{ "buses": [...] }` shape, and the defensive parsing of
/// values that Supabase may hand back as either decoded objects or raw JSON
/// strings.
void main() {
  group('SnapshotLeg wire round-trip', () {
    test('outbound.wire / return_.wire map to the DB strings', () {
      expect(SnapshotLeg.outbound.wire, 'outbound');
      expect(SnapshotLeg.return_.wire, 'return');
    });

    test('fromWire is the inverse of wire', () {
      expect(SnapshotLeg.fromWire('outbound'), SnapshotLeg.outbound);
      expect(SnapshotLeg.fromWire('return'), SnapshotLeg.return_);
      // Round-trip through both directions.
      for (final leg in SnapshotLeg.values) {
        expect(SnapshotLeg.fromWire(leg.wire), leg);
      }
    });

    test('fromWire defaults unknown strings to outbound (defensive)', () {
      expect(SnapshotLeg.fromWire('nonsense'), SnapshotLeg.outbound);
      expect(SnapshotLeg.fromWire(''), SnapshotLeg.outbound);
      expect(SnapshotLeg.fromWire('Return'), SnapshotLeg.outbound);
    });
  });

  group('TourSeatSnapshot.toMap / fromMap round-trip', () {
    final snapshot = TourSeatSnapshot(
      tourId: 't1',
      leg: SnapshotLeg.return_,
      buses: const [
        SnapshotBus(
          busId: 'b1',
          seats: [
            SnapshotSeat(seatId: 'DL3', name: 'Ravi Patel', phone: '9876543210'),
            SnapshotSeat(seatId: 'L1', name: 'No Phone Rider'),
          ],
        ),
        SnapshotBus(
          busId: 'b2',
          seats: [
            SnapshotSeat(seatId: 'ST5', name: 'Meera', phone: '1112223333'),
          ],
        ),
      ],
      capturedAt: DateTime.parse('2026-06-19T10:30:00.000Z'),
    );

    test('toMap shape: leg wire, snapshot_data.buses, captured_at ISO', () {
      final map = snapshot.toMap();
      expect(map['tour_id'], 't1');
      expect(map['leg'], 'return');
      expect(map['captured_at'], '2026-06-19T10:30:00.000Z');

      // snapshot_data holds exactly { 'buses': [...] }.
      final data = map['snapshot_data'] as Map<String, dynamic>;
      expect(data.keys, ['buses']);
      final buses = data['buses'] as List;
      expect(buses.length, 2);
      final firstBus = buses.first as Map<String, dynamic>;
      expect(firstBus['busId'], 'b1');
      final firstSeat = (firstBus['seats'] as List).first as Map<String, dynamic>;
      expect(firstSeat['seatId'], 'DL3');
      expect(firstSeat['name'], 'Ravi Patel');
      expect(firstSeat['phone'], '9876543210');
    });

    test('toMap then fromMap reproduces every field (Map snapshot_data)', () {
      final restored = TourSeatSnapshot.fromMap(snapshot.toMap());

      expect(restored.tourId, 't1');
      expect(restored.leg, SnapshotLeg.return_);
      expect(restored.buses.length, 2);

      final b1 = restored.buses[0];
      expect(b1.busId, 'b1');
      expect(b1.seats.length, 2);
      expect(b1.seats[0].seatId, 'DL3');
      expect(b1.seats[0].name, 'Ravi Patel');
      expect(b1.seats[0].phone, '9876543210');
      expect(b1.seats[1].seatId, 'L1');
      expect(b1.seats[1].name, 'No Phone Rider');
      expect(b1.seats[1].phone, isNull);

      final b2 = restored.buses[1];
      expect(b2.busId, 'b2');
      expect(b2.seats.single.seatId, 'ST5');
      expect(b2.seats.single.phone, '1112223333');
    });

    test('fromMap handles snapshot_data arriving as a JSON String', () {
      final map = snapshot.toMap();
      // Simulate a driver handing jsonb back as raw text.
      map['snapshot_data'] = jsonEncode(map['snapshot_data']);
      expect(map['snapshot_data'], isA<String>());

      final restored = TourSeatSnapshot.fromMap(map);
      expect(restored.buses.length, 2);
      expect(restored.buses[0].busId, 'b1');
      expect(restored.buses[0].seats[0].name, 'Ravi Patel');
      expect(restored.buses[0].seats[1].phone, isNull);
      expect(restored.buses[1].seats.single.seatId, 'ST5');
    });
  });

  group('TourSeatSnapshot.fromMap captured_at handling', () {
    Map<String, dynamic> rowWith(dynamic capturedAt) {
      final row = <String, dynamic>{
        'tour_id': 't1',
        'leg': 'outbound',
        'snapshot_data': {'buses': []},
      };
      if (capturedAt != null) row['captured_at'] = capturedAt;
      return row;
    }

    test('parses an ISO string captured_at', () {
      final restored =
          TourSeatSnapshot.fromMap(rowWith('2026-06-19T08:15:00.000Z'));
      expect(
        restored.capturedAt.toUtc(),
        DateTime.parse('2026-06-19T08:15:00.000Z'),
      );
    });

    test('tolerates a missing captured_at (falls back, does not throw)', () {
      final before = DateTime.now();
      final restored = TourSeatSnapshot.fromMap(rowWith(null));
      // No captured_at key at all → defensive default to ~now.
      expect(restored.capturedAt.isAfter(before.subtract(const Duration(minutes: 1))),
          isTrue);
    });
  });

  group('SnapshotSeat phone handling', () {
    test('toMap omits phone when null', () {
      const seat = SnapshotSeat(seatId: 'L1', name: 'Anon');
      final map = seat.toMap();
      expect(map.containsKey('phone'), isFalse);
      expect(map['seatId'], 'L1');
      expect(map['name'], 'Anon');
    });

    test('toMap includes phone when present', () {
      const seat = SnapshotSeat(seatId: 'L1', name: 'Anon', phone: '999');
      expect(seat.toMap()['phone'], '999');
    });

    test('fromMap tolerates a missing phone key', () {
      final seat = SnapshotSeat.fromMap({'seatId': 'L1', 'name': 'Anon'});
      expect(seat.seatId, 'L1');
      expect(seat.name, 'Anon');
      expect(seat.phone, isNull);
    });
  });

  group('SnapshotBus.occupant', () {
    const bus = SnapshotBus(
      busId: 'b1',
      seats: [
        SnapshotSeat(seatId: 'DL3', name: 'Ravi'),
        SnapshotSeat(seatId: 'ST5', name: 'Meera'),
      ],
    );

    test('returns the matching seat', () {
      expect(bus.occupant('DL3')?.name, 'Ravi');
      expect(bus.occupant('ST5')?.name, 'Meera');
    });

    test('returns null for an unoccupied seat', () {
      expect(bus.occupant('L9'), isNull);
    });
  });
}
