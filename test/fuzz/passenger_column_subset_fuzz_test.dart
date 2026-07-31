import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/passenger.dart';

import 'row_generators.dart';

/// COLUMN-SUBSET FUZZ — the guard for narrowing `select *`.
///
/// The cold-start read currently pulls every column of every passenger of
/// every tour (measured: 1.27 MB for 25 tours × 50 passengers), which is what
/// makes the app unusable below ~1 Mbps. Any fix narrows what is fetched.
///
/// Narrowing a select is exactly the change that silently NULLs a field
/// nobody remembered was load-bearing — the failure is invisible in code
/// review and only shows up as missing data on a customer's screen.
///
/// These tests answer two questions mechanically, for randomly generated rows:
///   1. Does `fromMap` survive ANY subset of columns without throwing?
///   2. WHICH columns actually change the parsed result when removed?
///
/// (2) is the real deliverable: it is a machine-checked list of what a
/// projection MUST include. Add a column to `Passenger.fromMap` and forget the
/// projection, and this test fails.
void main() {
  // Fixed seeds → reproducible. A failure prints its seed; re-run with it to
  // replay the exact row that broke.
  const seeds = [1, 7, 42, 99, 256, 1024, 31337, 65535];

  String encode(Passenger p) => jsonEncode(p.toMap());

  group('Passenger.fromMap survives arbitrary column subsets', () {
    test('dropping any single column never throws', () {
      for (final seed in seeds) {
        final gen = RowGen(seed);
        for (var i = 0; i < 40; i++) {
          final full = gen.passengerRow();
          for (final key in full.keys.toList()) {
            final partial = Map<String, dynamic>.from(full)..remove(key);
            expect(
              () => Passenger.fromMap(partial),
              returnsNormally,
              reason: 'seed=$seed iter=$i dropping "$key" threw',
            );
          }
        }
      }
    });

    test('dropping RANDOM subsets of columns never throws', () {
      for (final seed in seeds) {
        final gen = RowGen(seed);
        for (var i = 0; i < 200; i++) {
          final full = gen.passengerRow();
          final partial = Map<String, dynamic>.from(full);
          for (final key in full.keys.toList()) {
            if (gen.boolean()) partial.remove(key);
          }
          expect(
            () => Passenger.fromMap(partial),
            returnsNormally,
            reason: 'seed=$seed iter=$i subset=${partial.keys.toList()} threw',
          );
        }
      }
    });

    test('the empty row parses — a fully-projected-away passenger is inert',
        () {
      expect(() => Passenger.fromMap(const {}), returnsNormally);
      final p = Passenger.fromMap(const {});
      expect(p.id, isEmpty);
      expect(p.tourId, isEmpty);
      expect(p.assignedSeats, isEmpty);
      expect(p.requestLines, isEmpty);
    });
  });

  group('load-bearing columns (what any projection MUST include)', () {
    test('is exactly the documented set — update the projection if this fails',
        () {
      final loadBearing = <String>{};

      for (final seed in seeds) {
        final gen = RowGen(seed);
        for (var i = 0; i < 30; i++) {
          final full = gen.passengerRow();
          final reference = encode(Passenger.fromMap(full));

          for (final key in full.keys.toList()) {
            final partial = Map<String, dynamic>.from(full)..remove(key);
            if (encode(Passenger.fromMap(partial)) != reference) {
              loadBearing.add(key);
            }
          }
        }
      }

      // Every column Passenger.fromMap actually consumes. Derived by
      // experiment above, not copied from the model by hand — so it stays
      // honest as the model changes.
      const expected = {
        'id',
        'tour_id',
        'user_id',
        'name',
        'phone',
        'age_group',
        'request_lines',
        'assigned_seats',
        'payment_status',
        'is_handler',
        'is_waitlisted',
        'is_confirmed',
        'note',
        'trip_type',
        'group_id',
        'priority_status',
        'priority_reason',
        'journey_done',
        'pickup_location_id',
        'pickup_location_name',
        'cancelled_at',
        'cancel_requested_at',
        'seats_notified_sig',
        'created_at',
      };

      expect(
        loadBearing,
        equals(expected),
        reason: 'A column became (or stopped being) load-bearing. If you '
            'narrowed a select, this is the authoritative list of columns it '
            'must still request.',
      );
    });

    test('updated_at is NOT load-bearing — safe to drop from any projection',
        () {
      for (final seed in seeds) {
        final gen = RowGen(seed);
        for (var i = 0; i < 20; i++) {
          final full = gen.passengerRow()..['updated_at'] = gen.isoDate();
          final withCol = encode(Passenger.fromMap(full));
          final without = encode(
            Passenger.fromMap(Map<String, dynamic>.from(full)
              ..remove('updated_at')),
          );
          expect(without, equals(withCol), reason: 'seed=$seed iter=$i');
        }
      }
    });
  });
}
