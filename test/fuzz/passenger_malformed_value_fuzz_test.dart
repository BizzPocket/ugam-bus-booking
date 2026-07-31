import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/passenger.dart';

import 'row_generators.dart';

/// MALFORMED-VALUE FUZZ — one bad row must never blank the whole roster.
///
/// `_fetchToursWithRelations` parses the passengers array in a single pass. A
/// `fromMap` that THROWS on one unexpected value takes down the entire tour
/// load with it: the catch in `smartFetch` turns the whole read into
/// `failed: true`, and the admin sees "couldn't load tours" — not "one
/// passenger looked odd". A single malformed row must degrade to a single
/// degraded passenger, never to an empty screen.
///
/// These rows are NOT modelled on what the app writes today. They are what a
/// column can end up holding after a migration backfill, a hand-edit in the
/// Supabase table editor, an older client version, or a type change — i.e.
/// precisely the cases no fixture-based test thinks to cover.
void main() {
  const seeds = [3, 11, 77, 404, 2048, 90210];

  group('Passenger.fromMap tolerates hostile values in any single column', () {
    test('no single corrupted column can throw', () {
      final failures = <String>[];

      for (final seed in seeds) {
        final gen = RowGen(seed);
        for (var i = 0; i < 60; i++) {
          final full = gen.passengerRow();
          for (final key in full.keys.toList()) {
            final poisoned = Map<String, dynamic>.from(full);
            poisoned[key] = gen.hostileValue();
            try {
              Passenger.fromMap(poisoned);
            } catch (e) {
              failures.add(
                'seed=$seed key="$key" value=${poisoned[key]} '
                '(${poisoned[key].runtimeType}) -> $e',
              );
            }
          }
        }
      }

      expect(
        failures,
        isEmpty,
        reason: 'A malformed value threw instead of degrading. Each of these '
            'would blank the entire tour list, not just one passenger:\n'
            '${failures.take(15).join('\n')}\n'
            '(${failures.length} total)',
      );
    });

    test('every column corrupted at once still parses', () {
      for (final seed in seeds) {
        final gen = RowGen(seed);
        for (var i = 0; i < 40; i++) {
          final row = gen.passengerRow();
          for (final key in row.keys.toList()) {
            row[key] = gen.hostileValue();
          }
          expect(
            () => Passenger.fromMap(row),
            returnsNormally,
            reason: 'seed=$seed iter=$i row=$row',
          );
        }
      }
    });
  });

  group('nested JSONB is the highest-risk surface', () {
    test('assigned_seats holding arbitrary junk never throws', () {
      for (final seed in seeds) {
        final gen = RowGen(seed);
        for (var i = 0; i < 60; i++) {
          final row = gen.passengerRow();
          row['assigned_seats'] = gen.pick<Object?>([
            null,
            'not a list',
            42,
            <dynamic>[],
            [null],
            ['a string, not a map'],
            [
              {'busId': 'b1'} // seatId missing
            ],
            [
              {'seatId': 'A1'} // busId missing
            ],
            [
              {'busId': 1, 'seatId': 2} // wrong types
            ],
            [
              {'busId': 'b1', 'seatId': 'A1', 'leg': 999}
            ],
            [
              {'busId': 'b1', 'seatId': 'A1', 'locked': 'yes'}
            ],
            {'not': 'a list'},
          ]);
          expect(
            () => Passenger.fromMap(row),
            returnsNormally,
            reason: 'seed=$seed assigned_seats=${row['assigned_seats']}',
          );
        }
      }
    });

    test('request_lines holding arbitrary junk never throws', () {
      for (final seed in seeds) {
        final gen = RowGen(seed);
        for (var i = 0; i < 60; i++) {
          final row = gen.passengerRow();
          row['request_lines'] = gen.pick<Object?>([
            null,
            'not a list',
            0,
            <dynamic>[],
            [null],
            ['string line'],
            [
              {'qty': 2} // seatType missing
            ],
            [
              {'seatType': 'unknownType', 'qty': 1}
            ],
            [
              {'seatType': 'seater', 'qty': 'two'}
            ],
            [
              {'seatType': 'seater', 'qty': -5}
            ],
            [
              {'seatType': 'seater', 'qty': 1, 'position': 'sideways'}
            ],
            {'not': 'a list'},
          ]);
          expect(
            () => Passenger.fromMap(row),
            returnsNormally,
            reason: 'seed=$seed request_lines=${row['request_lines']}',
          );
        }
      }
    });
  });
}
