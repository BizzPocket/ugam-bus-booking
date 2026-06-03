import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/passenger.dart';
import 'package:occubusbooking/models/priority_status.dart';

void main() {
  group('Passenger priority + group fields', () {
    test('defaults: no group, priority none, no reason', () {
      final p = Passenger(tourId: 't1', name: 'Suresh', phone: '9327148044');
      expect(p.groupId, isNull);
      expect(p.priorityStatus, PriorityStatus.none);
      expect(p.priorityReason, isNull);
      expect(p.isPriorityApproved, isFalse);
    });

    test('round-trips group + priority through toMap/fromMap', () {
      final p = Passenger(
        id: 'p1', tourId: 't1', name: 'Lila ben', phone: '9000000000',
        groupId: 'g1',
        priorityStatus: PriorityStatus.approved,
        priorityReason: 'elderly, needs front',
      );
      final m = p.toMap();
      expect(m['group_id'], 'g1');
      expect(m['priority_status'], 'approved');
      expect(m['priority_reason'], 'elderly, needs front');

      final back = Passenger.fromMap(m);
      expect(back.groupId, 'g1');
      expect(back.priorityStatus, PriorityStatus.approved);
      expect(back.priorityReason, 'elderly, needs front');
      expect(back.isPriorityApproved, isTrue);
    });

    test('fromMap tolerates missing columns (old rows)', () {
      final p = Passenger.fromMap({
        'id': 'p1', 'tour_id': 't1', 'name': 'x', 'phone': '9000000000',
      });
      expect(p.groupId, isNull);
      expect(p.priorityStatus, PriorityStatus.none);
      expect(p.priorityReason, isNull);
    });

    test('copyWith sets priorityStatus and groupId', () {
      final p = Passenger(tourId: 't1', name: 'x', phone: '9000000000');
      final c = p.copyWith(
        priorityStatus: PriorityStatus.requested,
        groupId: 'g9',
      );
      expect(c.priorityStatus, PriorityStatus.requested);
      expect(c.groupId, 'g9');
      expect(c.isPriorityPending, isTrue);
    });
  });
}
