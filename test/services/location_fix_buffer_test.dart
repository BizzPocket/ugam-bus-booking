import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/bus_position.dart';
import 'package:occubusbooking/services/location_fix_buffer.dart';
import 'package:shared_preferences/shared_preferences.dart';

LocationFix fixAt(int minute) => LocationFix(
      lat: 23.0 + minute / 1000,
      lng: 72.0,
      recordedAt: DateTime.utc(2026, 8, 10, 12, minute),
    );

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('LocationFixBuffer', () {
    test('starts empty', () {
      expect(LocationFixBuffer(busId: 'b1').length, 0);
    });

    test('add appends in order', () async {
      final b = LocationFixBuffer(busId: 'b1');
      await b.add(fixAt(1));
      await b.add(fixAt(2));
      expect(b.length, 2);
      expect(b.fixes.first.recordedAt, fixAt(1).recordedAt);
    });

    test('drops the OLDEST on overflow, keeping the newest', () async {
      final b = LocationFixBuffer(busId: 'b1', maxFixes: 3);
      for (var i = 1; i <= 5; i++) {
        await b.add(fixAt(i));
      }
      expect(b.length, 3);
      expect(b.fixes.first.recordedAt, fixAt(3).recordedAt);
      expect(b.fixes.last.recordedAt, fixAt(5).recordedAt);
    });

    test('take peeks the oldest n without removing them', () async {
      final b = LocationFixBuffer(busId: 'b1');
      for (var i = 1; i <= 5; i++) {
        await b.add(fixAt(i));
      }
      final batch = b.take(2);
      expect(batch.length, 2);
      expect(batch.first.recordedAt, fixAt(1).recordedAt);
      expect(b.length, 5, reason: 'take must not mutate');
    });

    test('take clamps to what is available', () async {
      final b = LocationFixBuffer(busId: 'b1');
      await b.add(fixAt(1));
      expect(b.take(500).length, 1);
    });

    test('drop removes the oldest n', () async {
      final b = LocationFixBuffer(busId: 'b1');
      for (var i = 1; i <= 5; i++) {
        await b.add(fixAt(i));
      }
      await b.drop(2);
      expect(b.length, 3);
      expect(b.fixes.first.recordedAt, fixAt(3).recordedAt);
    });

    test('drop past the end empties rather than throwing', () async {
      final b = LocationFixBuffer(busId: 'b1');
      await b.add(fixAt(1));
      await b.drop(99);
      expect(b.length, 0);
    });

    test('survives process death — rehydrate restores fixes', () async {
      final first = LocationFixBuffer(busId: 'b1');
      await first.add(fixAt(1));
      await first.add(fixAt(2));

      final second = LocationFixBuffer(busId: 'b1');
      await second.rehydrate();
      expect(second.length, 2);
      expect(second.fixes.first.recordedAt, fixAt(1).recordedAt);
    });

    test('buffers are scoped per bus', () async {
      final a = LocationFixBuffer(busId: 'bus-a');
      await a.add(fixAt(1));

      final b = LocationFixBuffer(busId: 'bus-b');
      await b.rehydrate();
      expect(b.length, 0);
    });

    test('clear wipes memory and disk', () async {
      final b = LocationFixBuffer(busId: 'b1');
      await b.add(fixAt(1));
      await b.clear();

      final reloaded = LocationFixBuffer(busId: 'b1');
      await reloaded.rehydrate();
      expect(reloaded.length, 0);
    });

    test('a corrupt disk entry is skipped while its neighbours survive',
        () async {
      SharedPreferences.setMockInitialValues({
        'loc_buffer_b1': <String>[
          '{not json',
          jsonEncode(fixAt(1).toJson()),
          '[]',
          jsonEncode(fixAt(2).toJson()),
        ],
      });
      final b = LocationFixBuffer(busId: 'b1');
      await b.rehydrate();

      expect(b.length, 2,
          reason: 'one bad row must not cost the whole trail');
      expect(b.fixes.first.recordedAt, fixAt(1).recordedAt);
      expect(b.fixes.last.recordedAt, fixAt(2).recordedAt);
    });

    test('rehydrate trims an over-long stored buffer to the cap', () async {
      SharedPreferences.setMockInitialValues({
        'loc_buffer_b1': [
          for (var i = 1; i <= 10; i++) jsonEncode(fixAt(i).toJson()),
        ],
      });
      final b = LocationFixBuffer(busId: 'b1', maxFixes: 4);
      await b.rehydrate();

      expect(b.length, 4);
      expect(b.fixes.first.recordedAt, fixAt(7).recordedAt,
          reason: 'keeps the newest 4');
    });
  });
}
