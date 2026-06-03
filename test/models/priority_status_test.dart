import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/priority_status.dart';

void main() {
  group('PriorityStatus', () {
    test('fromString maps known names', () {
      expect(PriorityStatus.fromString('approved'), PriorityStatus.approved);
      expect(PriorityStatus.fromString('requested'), PriorityStatus.requested);
      expect(PriorityStatus.fromString('declined'), PriorityStatus.declined);
      expect(PriorityStatus.fromString('none'), PriorityStatus.none);
    });

    test('fromString falls back to none for null/unknown', () {
      expect(PriorityStatus.fromString(null), PriorityStatus.none);
      expect(PriorityStatus.fromString('garbage'), PriorityStatus.none);
    });

    test('isApproved / isPending helpers', () {
      expect(PriorityStatus.approved.isApproved, isTrue);
      expect(PriorityStatus.requested.isPending, isTrue);
      expect(PriorityStatus.approved.isPending, isFalse);
      expect(PriorityStatus.none.isApproved, isFalse);
    });
  });
}
