import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:occubusbooking/controllers/money_controller.dart';
import 'package:occubusbooking/models/bus_details.dart';
import 'package:occubusbooking/models/collection.dart';
import 'package:occubusbooking/models/passenger.dart';
import 'package:occubusbooking/models/request_line.dart';
import 'package:occubusbooking/models/seat_assignment.dart';
import 'package:occubusbooking/models/seat_layout.dart';
import 'package:occubusbooking/models/seat_type.dart';
import 'package:occubusbooking/models/tour.dart';
import 'package:occubusbooking/screens/collection_screen.dart';

class _FakeMoneyController extends MoneyController {
  @override
  Future<void> loadForTour(String tourId) async {}

  @override
  Future<void> refreshForTour(String tourId) async {}
}

Bus _bus() => Bus(
      id: 'b1',
      name: 'Vantara',
      pricePerSeat: 2000,
      layout: BusLayout(
        rows: 1,
        cols: 2,
        grid: const [
          SeatCell(
            row: 0,
            col: 0,
            seatType: SeatType.seater,
            seatId: 'S1',
          ),
          SeatCell(
            row: 0,
            col: 1,
            seatType: SeatType.seater,
            seatId: 'S2',
          ),
        ],
      ),
    );

Passenger _passenger({
  required String id,
  required String name,
  required String seatId,
}) =>
    Passenger(
      id: id,
      tourId: 't1',
      name: name,
      phone: '9876543210',
      assignedSeats: [SeatAssignment(busId: 'b1', seatId: seatId)],
      requestLines: const [
        RequestLine(seatType: SeatType.seater, qty: 1),
      ],
    );

Tour _tour() => Tour(
      id: 't1',
      title: 'Dwarka Yatra',
      fromCity: 'Surat',
      toCity: 'Dwarka',
      departureDate: DateTime(2026, 7, 1),
      pricePerSeat: 2000,
      buses: [_bus()],
      passengers: [
        _passenger(id: 'p1', name: 'Riya Shah', seatId: 'S1'),
        _passenger(id: 'p2', name: 'Amit Patel', seatId: 'S2'),
      ],
    );

void main() {
  tearDown(Get.reset);

  void useTallSurface(WidgetTester tester) {
    tester.view.physicalSize = const Size(1200, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  testWidgets(
      'highlightPassengerId selects to-collect filter when rider owes',
      (tester) async {
    useTallSurface(tester);
    final money = _FakeMoneyController();
    Get.put<MoneyController>(money);
    money.collections.assignAll([
      Collection(
        tourId: 't1',
        busId: 'b1',
        passengerId: 'p1',
        seatId: 'S1',
        amountDue: 2000,
        amountReceived: 1600,
      ),
      Collection(
        tourId: 't1',
        busId: 'b1',
        passengerId: 'p2',
        seatId: 'S2',
        amountDue: 2000,
        amountReceived: 2000,
      ),
    ]);
    money.loadedOnce.value = true;

    await tester.pumpWidget(
      GetMaterialApp(
        theme: ThemeData(brightness: Brightness.dark),
        home: CollectionScreen(
          tour: _tour(),
          bus: _bus(),
          highlightPassengerId: 'p1',
        ),
      ),
    );
    await tester.pump();
    await tester.pump(); // post-frame highlight filter

    expect(find.text('Riya Shah'), findsOneWidget);
    // Settled rider is hidden once To collect filter is applied.
    expect(find.text('Amit Patel'), findsNothing);
  });
}
