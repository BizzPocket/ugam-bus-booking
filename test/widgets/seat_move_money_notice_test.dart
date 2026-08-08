import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:occubusbooking/models/tour.dart';
import 'package:occubusbooking/services/collection_reconciler.dart';
import 'package:occubusbooking/widgets/seat_move_money_notice.dart';

void main() {
  tearDown(Get.reset);

  testWidgets('Collect now invokes onCollectNow with the collect delta',
      (tester) async {
    SeatMoveMoneyDelta? collected;
    var returnLater = false;

    final tour = Tour(
      id: 't1',
      title: 'T',
      fromCity: 'A',
      toCity: 'B',
      departureDate: DateTime(2026, 1, 1),
      pricePerSeat: 2000,
    );

    final delta = const SeatMoveMoneyDelta(
      passengerId: 'p1',
      passengerName: 'Riya',
      paid: 1600,
      due: 2000,
      fromBusNames: ['Bus 1'],
      toBusNames: ['Bus 2'],
      fromBusIds: ['b1'],
      toBusIds: ['b2'],
    );

    await tester.pumpWidget(
      GetMaterialApp(
        theme: ThemeData(brightness: Brightness.dark),
        home: Builder(
          builder: (context) {
            return Scaffold(
              body: TextButton(
                onPressed: () {
                  SeatMoveMoneyNotice.show(
                    [delta],
                    tour: tour,
                    onCollectNow: (d) => collected = d,
                    onReturnLater: () => returnLater = true,
                  );
                },
                child: const Text('open'),
              ),
            );
          },
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('seat_move_money.action_collect'), findsOneWidget);
    expect(find.text('seat_move_money.action_dismiss'), findsOneWidget);

    await tester.tap(find.text('seat_move_money.action_collect'));
    await tester.pumpAndSettle();

    expect(collected?.passengerId, 'p1');
    expect(collected?.toCollect, 400);
    expect(returnLater, isFalse);
  });

  testWidgets('Mark return later invokes onReturnLater', (tester) async {
    var returnLater = false;

    final tour = Tour(
      id: 't1',
      title: 'T',
      fromCity: 'A',
      toCity: 'B',
      departureDate: DateTime(2026, 1, 1),
      pricePerSeat: 1400,
    );

    final delta = const SeatMoveMoneyDelta(
      passengerId: 'p1',
      passengerName: 'Riya',
      paid: 1600,
      due: 1400,
      fromBusNames: ['Bus 1'],
      toBusNames: ['Bus 2'],
      fromBusIds: ['b1'],
      toBusIds: ['b2'],
    );

    await tester.pumpWidget(
      GetMaterialApp(
        theme: ThemeData(brightness: Brightness.dark),
        home: Scaffold(
          body: TextButton(
            onPressed: () {
              SeatMoveMoneyNotice.show(
                [delta],
                tour: tour,
                onReturnLater: () => returnLater = true,
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('seat_move_money.action_return_later'));
    await tester.pumpAndSettle();

    expect(returnLater, isTrue);
  });
}
