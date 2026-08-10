import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/bus_position.dart';
import 'package:occubusbooking/services/bus_positions_repository.dart';

BusPosition pos(String busId, {DateTime? at, double lat = 23.0}) =>
    BusPosition.fromMap({
      'bus_id': busId,
      'tour_id': 'tour-1',
      'lat': lat,
      'lng': 72.0,
      'tracking_state': 'live',
      'recorded_at': (at ?? DateTime.now().toUtc()).toIso8601String(),
      'received_at': DateTime.now().toUtc().toIso8601String(),
    });

void main() {
  group('mergePositions', () {
    test('adds a bus not yet on the map', () {
      final merged = BusPositionsRepository.mergePositions([], pos('b1'));
      expect(merged.length, 1);
      expect(merged.single.busId, 'b1');
    });

    test('replaces the existing row for the same bus', () {
      final older = pos('b1', lat: 23.0);
      final newer = pos('b1', lat: 24.0);
      final merged = BusPositionsRepository.mergePositions([older], newer);
      expect(merged.length, 1, reason: 'one dot per bus, never two');
      expect(merged.single.lat, 24.0);
    });

    test('leaves other buses untouched', () {
      final merged = BusPositionsRepository.mergePositions([
        pos('b1'),
        pos('b2'),
      ], pos('b2', lat: 25.0));
      expect(merged.length, 2);
      expect(merged.firstWhere((p) => p.busId == 'b1').lat, 23.0);
      expect(merged.firstWhere((p) => p.busId == 'b2').lat, 25.0);
    });

    test('never rewinds to an older fix', () {
      final now = DateTime.now().toUtc();
      final current = pos('b1', at: now, lat: 24.0);
      final stale = pos(
        'b1',
        at: now.subtract(const Duration(minutes: 5)),
        lat: 23.0,
      );

      final merged = BusPositionsRepository.mergePositions([current], stale);
      expect(
        merged.single.lat,
        24.0,
        reason: 'an out-of-order offline flush must not move the dot back',
      );
    });

    test('accepts a fix with the same timestamp — state may have changed', () {
      final t = DateTime.now().toUtc();
      final merged = BusPositionsRepository.mergePositions([
        pos('b1', at: t, lat: 23.0),
      ], pos('b1', at: t, lat: 24.0));
      expect(merged.single.lat, 24.0);
    });

    test('preserves ordering of the existing list', () {
      final merged = BusPositionsRepository.mergePositions([
        pos('b1'),
        pos('b2'),
        pos('b3'),
      ], pos('b2', lat: 25.0));
      expect(merged.map((p) => p.busId).toList(), ['b1', 'b2', 'b3']);
    });
  });
}
