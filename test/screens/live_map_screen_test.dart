import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/bus_details.dart';
import 'package:occubusbooking/models/bus_position.dart';
import 'package:occubusbooking/screens/live_map_screen.dart';

BusPosition pos(String busId, {DateTime? at, double? speedKmh}) =>
    BusPosition.fromMap({
      'bus_id': busId,
      'tour_id': 'tour-1',
      'lat': 23.0,
      'lng': 72.0,
      'speed_kmh': speedKmh,
      'tracking_state': 'live',
      'recorded_at': (at ?? DateTime.now().toUtc()).toIso8601String(),
      'received_at': DateTime.now().toUtc().toIso8601String(),
    });

void main() {
  group('agoLabel', () {
    test('reads "now" under a minute', () {
      expect(agoLabel(DateTime.now().toUtc()), 'now');
    });

    test('reads minutes under an hour', () {
      expect(
        agoLabel(DateTime.now().toUtc().subtract(const Duration(minutes: 14))),
        '14m',
      );
    });

    test('rolls over to hours', () {
      expect(
        agoLabel(DateTime.now().toUtc().subtract(const Duration(minutes: 90))),
        '1h',
      );
    });
  });

  group('LiveMapScreen', () {
    testWidgets('shows the empty state when no bus has reported', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: LiveMapScreen(
            tourId: 't1',
            buses: const [],
            initialPositions: const [],
          ),
        ),
      );
      await tester.pump();

      expect(find.text(tr('tracking.map_empty_title')), findsOneWidget);
    });

    testWidgets('does not show the empty state once a bus reports', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: LiveMapScreen(
            tourId: 't1',
            buses: [Bus(id: 'b1', name: 'Bus 1')],
            initialPositions: [pos('b1')],
          ),
        ),
      );
      await tester.pump();

      expect(find.text(tr('tracking.map_empty_title')), findsNothing);
    });
  });
}
