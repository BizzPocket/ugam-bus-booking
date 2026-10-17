import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/tour_status.dart';
import 'package:occubusbooking/utils/admin_handler_operate.dart';

void main() {
  group('tourAllowsAdminHandlerOperate', () {
    test('allows locked and completed only', () {
      expect(tourAllowsAdminHandlerOperate(TourStatus.locked), isTrue);
      expect(tourAllowsAdminHandlerOperate(TourStatus.completed), isTrue);
      expect(tourAllowsAdminHandlerOperate(TourStatus.assigning), isFalse);
      expect(tourAllowsAdminHandlerOperate(TourStatus.planning), isFalse);
    });
  });
}
