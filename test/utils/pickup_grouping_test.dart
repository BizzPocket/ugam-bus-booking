import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/utils/pickup_grouping.dart';

/// A minimal row for exercising the grouper: an id we can spot in assertions
/// plus its pickup snapshot (id + name), either of which may be null/blank.
class _Row {
  final String tag;
  final String? pickupId;
  final String? pickupName;
  const _Row(this.tag, this.pickupId, this.pickupName);
}

List<PickupGroup<_Row>> _group(List<_Row> rows) => groupByPickup<_Row>(
  rows,
  idOf: (r) => r.pickupId,
  nameOf: (r) => r.pickupName,
);

/// The tags in each group, group order preserved.
List<List<String>> _tags(List<PickupGroup<_Row>> groups) =>
    groups.map((g) => g.items.map((r) => r.tag).toList()).toList();

void main() {
  group('groupByPickup', () {
    test('named pickups are sorted alphabetically A→Z (case-insensitive)', () {
      final groups = _group(const [
        _Row('c', 'id-c', 'Charlie'),
        _Row('a', 'id-a', 'alpha'),
        _Row('b', 'id-b', 'Bravo'),
      ]);
      expect(groups.map((g) => g.locationName).toList(), [
        'alpha',
        'Bravo',
        'Charlie',
      ]);
    });

    test('the no-pickup bucket is always last', () {
      final groups = _group(const [
        _Row('none', null, null),
        _Row('z', 'id-z', 'Zebra'),
        _Row('a', 'id-a', 'Apple'),
      ]);
      expect(groups.map((g) => g.locationName).toList(), [
        'Apple',
        'Zebra',
        null,
      ]);
      expect(groups.last.isUnassigned, isTrue);
    });

    test('a blank / whitespace name falls into the no-pickup bucket', () {
      final groups = _group(const [
        _Row('blank', 'id-x', '   '),
        _Row('empty', 'id-y', ''),
        _Row('named', 'id-n', 'Named'),
      ]);
      expect(groups.first.locationName, 'Named');
      final unassigned = groups.last;
      expect(unassigned.isUnassigned, isTrue);
      expect(unassigned.items.map((r) => r.tag), ['blank', 'empty']);
    });

    test('order WITHIN a group preserves input order', () {
      final groups = _group(const [
        _Row('first', 'id-a', 'Alpha'),
        _Row('second', 'id-a', 'Alpha'),
        _Row('third', 'id-a', 'Alpha'),
      ]);
      expect(_tags(groups), [
        ['first', 'second', 'third'],
      ]);
    });

    test('same name, different id → one merged group', () {
      final groups = _group(const [
        _Row('one', 'id-1', 'Temple'),
        _Row('two', 'id-2', 'Temple'),
      ]);
      expect(groups, hasLength(1));
      expect(groups.single.items.map((r) => r.tag), ['one', 'two']);
    });

    test('the same name in different letter case merges into one group', () {
      final groups = _group(const [
        _Row('lower', 'id-1', 'temple'),
        _Row('upper', 'id-2', 'TEMPLE'),
      ]);
      expect(groups, hasLength(1));
      expect(groups.single.items.map((r) => r.tag), ['lower', 'upper']);
    });

    test('a named group carries the first-seen id + original-cased name', () {
      final groups = _group(const [
        _Row('one', 'id-first', 'Temple'),
        _Row('two', 'id-second', 'temple'),
      ]);
      expect(groups.single.locationId, 'id-first');
      expect(groups.single.locationName, 'Temple');
    });

    test('empty input → empty list', () {
      expect(_group(const []), isEmpty);
    });

    test('all-unassigned input → a single trailing bucket', () {
      final groups = _group(const [_Row('a', null, null), _Row('b', null, '')]);
      expect(groups, hasLength(1));
      expect(groups.single.isUnassigned, isTrue);
      expect(groups.single.items.map((r) => r.tag), ['a', 'b']);
    });
  });

  // The handler boards pickup points in ROUTE order, which is the admin's
  // manual serial — not the alphabet. `rankOf` is how that serial reaches the
  // grouper (in the app: PickupController.rankFor).
  group('groupByPickup with a serial rank', () {
    // A stand-in admin list: index = the admin's manual position.
    const serial = ['Parking', 'Temple', 'Patiya', 'Circle', 'Hotel'];
    int? rankById(String? id, String name) {
      final i = serial.indexWhere((s) => 'id-${s.toLowerCase()}' == id);
      return i >= 0 ? i : null;
    }

    List<PickupGroup<_Row>> groupRanked(
      List<_Row> rows, {
      int? Function(String?, String)? rankOf,
    }) => groupByPickup<_Row>(
      rows,
      idOf: (r) => r.pickupId,
      nameOf: (r) => r.pickupName,
      rankOf: rankOf ?? rankById,
    );

    test('sections follow the admin serial, not the alphabet', () {
      final groups = groupRanked(const [
        _Row('c', 'id-circle', 'Circle'),
        _Row('h', 'id-hotel', 'Hotel'),
        _Row('p', 'id-parking', 'Parking'),
      ]);
      // Alphabetical would be Circle, Hotel, Parking.
      expect(groups.map((g) => g.locationName).toList(), [
        'Parking',
        'Circle',
        'Hotel',
      ]);
    });

    test('a point the ranker cannot place sorts after the ranked ones', () {
      final groups = groupRanked(const [
        _Row('x', 'id-gone', 'Aardvark Stop'), // unknown id AND unknown name
        _Row('h', 'id-hotel', 'Hotel'),
        _Row('p', 'id-parking', 'Parking'),
      ]);
      expect(groups.map((g) => g.locationName).toList(), [
        'Parking',
        'Hotel',
        'Aardvark Stop',
      ]);
    });

    test('unranked leftovers keep their A→Z order among themselves', () {
      final groups = groupRanked(const [
        _Row('z', 'id-z', 'Zulu'),
        _Row('m', 'id-m', 'Mike'),
        _Row('h', 'id-hotel', 'Hotel'),
      ]);
      expect(groups.map((g) => g.locationName).toList(), [
        'Hotel',
        'Mike',
        'Zulu',
      ]);
    });

    test('the no-pickup bucket stays last even with ranks', () {
      final groups = groupRanked(const [
        _Row('none', null, null),
        _Row('h', 'id-hotel', 'Hotel'),
        _Row('p', 'id-parking', 'Parking'),
      ]);
      expect(groups.map((g) => g.locationName).toList(), [
        'Parking',
        'Hotel',
        null,
      ]);
      expect(groups.last.isUnassigned, isTrue);
    });

    test('a null rank for every point degrades to plain A→Z', () {
      // What happens before the pickup list has loaded.
      final groups = groupRanked(const [
        _Row('z', 'id-z', 'Zulu'),
        _Row('a', 'id-a', 'Alpha'),
      ], rankOf: (_, _) => null);
      expect(groups.map((g) => g.locationName).toList(), ['Alpha', 'Zulu']);
    });

    test('ties on the same rank fall back to A→Z (no wobble)', () {
      final groups = groupRanked(const [
        _Row('b', 'id-b', 'Bravo'),
        _Row('a', 'id-a', 'Alpha'),
      ], rankOf: (_, _) => 3);
      expect(groups.map((g) => g.locationName).toList(), ['Alpha', 'Bravo']);
    });
  });
}
