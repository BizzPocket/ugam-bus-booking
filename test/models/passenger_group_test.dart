import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/passenger_group.dart';

void main() {
  group('PassengerGroup', () {
    test('generates an id and defaults colorIndex to 0', () {
      final g = PassengerGroup(tourId: 't1', label: 'Patel family');
      expect(g.id, isNotEmpty);
      expect(g.colorIndex, 0);
      expect(g.tourId, 't1');
      expect(g.label, 'Patel family');
    });

    test('round-trips through toMap/fromMap', () {
      final g = PassengerGroup(
        id: 'g1', tourId: 't1', label: 'Surat group', colorIndex: 3,
      );
      final back = PassengerGroup.fromMap(g.toMap());
      expect(back.id, 'g1');
      expect(back.tourId, 't1');
      expect(back.label, 'Surat group');
      expect(back.colorIndex, 3);
    });

    test('toMap uses snake_case keys matching Postgres', () {
      final g = PassengerGroup(id: 'g1', tourId: 't1', label: 'x', colorIndex: 2);
      final m = g.toMap();
      expect(m.keys,
          containsAll(['id', 'tour_id', 'label', 'color_index', 'created_at']));
    });

    test('equality is by id', () {
      final a = PassengerGroup(id: 'g1', tourId: 't1', label: 'a');
      final b = PassengerGroup(id: 'g1', tourId: 't1', label: 'b');
      expect(a, equals(b));
    });
  });
}
