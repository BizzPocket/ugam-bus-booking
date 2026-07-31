import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/services/sync_service.dart';

import 'row_generators.dart';

/// COLD-START SCOPE — the fetch that decides whether the app works on 2G.
///
/// Cold start no longer pulls every tour's roster. Measured on a 25-tour book,
/// gzipped as the wire really carries it:
///   every tour hydrated  → 105 kB → 10.7s on EDGE, 43s on GPRS
///   running tours only   →  10 kB →  1.0s on EDGE,  4.1s on GPRS
/// against a 12s read budget that TLS handshake and query time eat into.
///
/// The dangerous failure mode is skipping a tour that should have been
/// hydrated: the user sees an EMPTY roster for a tour with fifty passengers,
/// with no error and no way to tell it apart from real data loss. So the rule
/// is asymmetric — skip ONLY on an exact `completed`, hydrate everything else.
/// These tests pin that asymmetry, including for inputs no fixture would try.
void main() {
  group('coldStartHydrationScope — the safe direction', () {
    test('skips exactly and only status == "completed"', () {
      final rows = [
        {'id': 'a', 'status': 'planning'},
        {'id': 'b', 'status': 'collecting'},
        {'id': 'c', 'status': 'busBooked'},
        {'id': 'd', 'status': 'assigning'},
        {'id': 'e', 'status': 'locked'},
        {'id': 'f', 'status': 'completed'},
      ];
      expect(coldStartHydrationScope(rows), ['a', 'b', 'c', 'd', 'e']);
    });

    test('an UNRECOGNISED status is hydrated, never skipped', () {
      // A renamed enum, a newer client, a hand-edited row. Fetching costs a
      // few kB; skipping shows an empty roster.
      const unknown = [
        'Completed', // wrong case
        'COMPLETED',
        ' completed',
        'completed ',
        'complete',
        'completed_at',
        'archived',
        'cancelled',
        'finished',
        '',
        'null',
        '0',
        'planning2',
      ];
      for (final s in unknown) {
        expect(
          coldStartHydrationScope([
            {'id': 'x', 'status': s}
          ]),
          ['x'],
          reason: 'status "$s" was skipped — it must be hydrated',
        );
      }
    });

    test('a missing or non-string status is hydrated', () {
      final rows = <Map<String, dynamic>>[
        {'id': 'a'}, // no status key at all
        {'id': 'b', 'status': null},
        {'id': 'c', 'status': 0},
        {'id': 'd', 'status': true},
        {'id': 'e', 'status': <String>[]},
        {'id': 'f', 'status': <String, dynamic>{}},
      ];
      expect(coldStartHydrationScope(rows), ['a', 'b', 'c', 'd', 'e', 'f']);
    });
  });

  group('coldStartHydrationScope — unusable ids', () {
    test('drops rows whose id cannot go into an in.() filter', () {
      final rows = <Map<String, dynamic>>[
        {'id': 'keep', 'status': 'locked'},
        {'id': null, 'status': 'locked'},
        {'status': 'locked'}, // no id key
        {'id': '', 'status': 'locked'},
        {'id': 42, 'status': 'locked'},
        {'id': <String>[], 'status': 'locked'},
        {'id': {'nested': 'map'}, 'status': 'locked'},
      ];
      // A null or non-string in an in.() list fails the ENTIRE request, taking
      // down every other tour's roster with it. Drop the row instead.
      expect(coldStartHydrationScope(rows), ['keep']);
    });

    test('empty input yields empty scope (caller must skip the request)', () {
      expect(coldStartHydrationScope(const []), isEmpty);
    });
  });

  group('coldStartHydrationScope — randomized', () {
    test('never throws, never invents an id, never returns a non-id', () {
      const seeds = [5, 17, 123, 999, 4096, 88888];
      for (final seed in seeds) {
        final gen = RowGen(seed);
        for (var i = 0; i < 300; i++) {
          final rows = List.generate(gen.intIn(0, 12), (_) {
            final row = <String, dynamic>{
              'id': gen.pick<Object?>([gen.uuid(), null, '', 7, <String>[]]),
              'status': gen.pick<Object?>([
                'planning',
                'collecting',
                'busBooked',
                'assigning',
                'locked',
                'completed',
                null,
                42,
                'unknown-status',
              ]),
            };
            return row;
          });

          late List<String> scope;
          expect(
            () => scope = coldStartHydrationScope(rows),
            returnsNormally,
            reason: 'seed=$seed iter=$i rows=$rows',
          );

          final validIds = rows
              .map((r) => r['id'])
              .whereType<String>()
              .where((s) => s.isNotEmpty)
              .toList();

          // Everything returned came from the input...
          for (final id in scope) {
            expect(validIds, contains(id), reason: 'seed=$seed invented $id');
          }
          // ...and every non-completed valid row is present.
          final mustHydrate = rows
              .where((r) =>
                  r['id'] is String &&
                  (r['id'] as String).isNotEmpty &&
                  r['status'] != 'completed')
              .map((r) => r['id'] as String);
          for (final id in mustHydrate) {
            expect(
              scope,
              contains(id),
              reason: 'seed=$seed iter=$i dropped a tour that needs hydrating',
            );
          }
        }
      }
    });

    test('a book of only completed tours issues no relation fetch at all', () {
      final gen = RowGen(2026);
      final rows = List.generate(
        40,
        (_) => <String, dynamic>{'id': gen.uuid(), 'status': 'completed'},
      );
      expect(coldStartHydrationScope(rows), isEmpty);
    });
  });
}
