import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/bus_position.dart';

void main() {
  group('LocationFix', () {
    test('toJson uses exactly the keys handler_push_locations reads', () {
      final fix = LocationFix(
        lat: 23.0225,
        lng: 72.5714,
        accuracyM: 12.5,
        speedKmh: 54.0,
        headingDeg: 180.0,
        leg: 'go',
        recordedAt: DateTime.utc(2026, 8, 10, 12, 0, 0),
      );

      expect(fix.toJson().keys.toSet(), {
        'lat',
        'lng',
        'accuracy_m',
        'speed_kmh',
        'heading_deg',
        'leg',
        'recorded_at',
        'tracking_state',
      });
    });

    test('recorded_at serialises as UTC ISO-8601', () {
      final fix = LocationFix(
        lat: 1,
        lng: 1,
        recordedAt: DateTime.utc(2026, 8, 10, 12, 0, 0),
      );
      expect(fix.toJson()['recorded_at'], '2026-08-10T12:00:00.000Z');
    });

    test('a local DateTime is converted to UTC, not written as local', () {
      final local = DateTime(2026, 8, 10, 17, 30);
      final fix = LocationFix(lat: 1, lng: 1, recordedAt: local);
      expect(fix.toJson()['recorded_at'], local.toUtc().toIso8601String());
      expect((fix.toJson()['recorded_at'] as String).endsWith('Z'), isTrue);
    });

    test('defaults tracking_state to live', () {
      final fix = LocationFix(lat: 1, lng: 1, recordedAt: DateTime.utc(2026));
      expect(fix.toJson()['tracking_state'], 'live');
    });

    test('round-trips through fromJson for the disk buffer', () {
      final fix = LocationFix(
        lat: 23.0225,
        lng: 72.5714,
        accuracyM: 12.5,
        speedKmh: 54.0,
        headingDeg: 180.0,
        leg: 'ret',
        recordedAt: DateTime.utc(2026, 8, 10, 12, 0, 0),
        trackingState: 'paused',
      );
      final back = LocationFix.fromJson(fix.toJson());

      expect(back.lat, fix.lat);
      expect(back.lng, fix.lng);
      expect(back.accuracyM, fix.accuracyM);
      expect(back.speedKmh, fix.speedKmh);
      expect(back.headingDeg, fix.headingDeg);
      expect(back.leg, 'ret');
      expect(back.trackingState, 'paused');
      expect(back.recordedAt.toUtc(), fix.recordedAt.toUtc());
    });
  });

  group('BusPosition', () {
    BusPosition make({DateTime? recordedAt, double? speedKmh}) =>
        BusPosition.fromMap({
          'bus_id': 'bus-1',
          'tour_id': 'tour-1',
          'lat': 23.0,
          'lng': 72.0,
          'speed_kmh': speedKmh,
          'tracking_state': 'live',
          'recorded_at':
              (recordedAt ?? DateTime.now().toUtc()).toIso8601String(),
          'received_at': DateTime.now().toUtc().toIso8601String(),
        });

    test('parses a bus_live_positions row', () {
      final p = make();
      expect(p.busId, 'bus-1');
      expect(p.tourId, 'tour-1');
      expect(p.lat, 23.0);
      expect(p.lng, 72.0);
      expect(p.trackingState, 'live');
    });

    test('is not stale just after recording', () {
      expect(make().isStale, isFalse);
    });

    test('is stale past six minutes — three missed uploads', () {
      final old = DateTime.now().toUtc().subtract(const Duration(minutes: 7));
      expect(make(recordedAt: old).isStale, isTrue);
    });

    test('five minutes old is not yet stale', () {
      final recent =
          DateTime.now().toUtc().subtract(const Duration(minutes: 5));
      expect(make(recordedAt: recent).isStale, isFalse);
    });

    test('isMoving is false when parked and true on the highway', () {
      expect(make(speedKmh: 0).isMoving, isFalse);
      expect(make(speedKmh: 3).isMoving, isFalse);
      expect(make(speedKmh: 54).isMoving, isTrue);
    });

    test('tolerates null optional columns', () {
      final p = BusPosition.fromMap({
        'bus_id': 'b',
        'tour_id': 't',
        'lat': 1.0,
        'lng': 2.0,
        'tracking_state': 'live',
        'recorded_at': DateTime.now().toUtc().toIso8601String(),
        'received_at': DateTime.now().toUtc().toIso8601String(),
      });
      expect(p.accuracyM, isNull);
      expect(p.speedKmh, isNull);
      expect(p.headingDeg, isNull);
      expect(p.leg, isNull);
      expect(p.isMoving, isFalse);
    });
  });
}
