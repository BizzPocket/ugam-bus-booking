import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:occubusbooking/controllers/tour_controller.dart';
import 'package:occubusbooking/models/passenger.dart';
import 'package:occubusbooking/models/passenger_group.dart';
import 'package:occubusbooking/models/request_line.dart';
import 'package:occubusbooking/models/seat_type.dart';
import 'package:occubusbooking/models/tour.dart';
import 'package:occubusbooking/widgets/group_picker.dart';

/// `setPassengerGroup` toasts its own error and then RETHROWS (that is
/// `_write`'s contract). The group sheets awaited it bare inside an onTap, so a
/// failed write became an unhandled async error — and, for the add sheet, no
/// false "added" toast could be told apart from a real one.
class _FailingTourController extends TourController {
  int calls = 0;

  @override
  // ignore: must_call_super
  void onInit() {}

  @override
  Future<void> setPassengerGroup(
      String tourId, String passengerId, String? groupId) async {
    calls++;
    throw Exception('offline');
  }
}

Passenger _p(String id, {String? groupId}) => Passenger(
      id: id,
      tourId: 't1',
      name: id,
      phone: '+910000000000',
      groupId: groupId,
      requestLines: const [RequestLine(seatType: SeatType.singleSofa, qty: 1)],
    );

void main() {
  tearDown(Get.reset);

  testWidgets('a failed add is handled, not an unhandled async error',
      (tester) async {
    final ctrl = _FailingTourController();
    Get.put<TourController>(ctrl);
    ctrl.tours.assignAll([
      Tour(
        id: 't1',
        title: 'Dwarka',
        fromCity: 'Surat',
        toCity: 'Dwarka',
        departureDate: DateTime(2026, 7, 1),
        pricePerSeat: 1200,
        passengers: [_p('Asha'), _p('Bharat', groupId: 'g1')],
        groups: [PassengerGroup(id: 'g1', tourId: 't1', label: 'Patel')],
      ),
    ]);

    await tester.pumpWidget(GetMaterialApp(
      theme: ThemeData(brightness: Brightness.dark),
      home: const Scaffold(
        body: AddMemberToGroupSheet(tourId: 't1', groupId: 'g1'),
      ),
    ));
    await tester.pump();

    await tester.tap(find.text('Asha'));
    await tester.pumpAndSettle();

    expect(ctrl.calls, 1);
    expect(tester.takeException(), isNull);
  });
}
