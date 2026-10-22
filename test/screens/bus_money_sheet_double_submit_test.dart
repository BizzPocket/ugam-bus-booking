import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:occubusbooking/controllers/money_controller.dart';
import 'package:occubusbooking/design/ugam.dart';
import 'package:occubusbooking/models/bus_details.dart';
import 'package:occubusbooking/models/bus_type.dart';
import 'package:occubusbooking/models/expense.dart';
import 'package:occubusbooking/models/seat_layout.dart';
import 'package:occubusbooking/models/tour.dart';
import 'package:occubusbooking/screens/bus_money_screen.dart';

/// A slow money write on 2G: each save is held open by the test, so a second
/// tap lands while the first is still on the wire.
class _SlowMoney extends MoneyController {
  final saves = <Expense>[];
  final pending = <Completer<void>>[];

  @override
  Future<void> loadForTour(String tourId) async {}

  @override
  Future<void> refreshForTour(String tourId) async {}

  @override
  Future<void> upsertExpense(Expense e) {
    saves.add(e);
    final c = Completer<void>();
    pending.add(c);
    return c.future;
  }
}

Bus _bus() => Bus(
      id: 'b1',
      name: 'Vantara',
      busType: 'Sleeper',
      layout: BusLayout.generate(busType: BusType.sleeper, totalSeats: 30),
    );

Tour _tour() => Tour(
      id: 't1',
      title: 'Dwarka Yatra',
      fromCity: 'Surat',
      toCity: 'Dwarka',
      departureDate: DateTime(2026, 7, 1),
      pricePerSeat: 1200,
      buses: [_bus()],
    );

void main() {
  tearDown(Get.reset);

  testWidgets(
      'a double-tapped expense save posts ONCE, and the retry after a '
      'failure re-sends the SAME row id', (tester) async {
    tester.view.physicalSize = const Size(1200, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final money = _SlowMoney();
    Get.put<MoneyController>(money);
    await tester.pumpWidget(GetMaterialApp(
      theme: ThemeData(brightness: Brightness.dark),
      home: BusMoneyScreen(tour: _tour(), bus: _bus()),
    ));
    await tester.pump();

    // Open "Add expense" (first section action).
    await tester.tap(find.text('app.action.add').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('5').last);
    await tester.pump();

    final save = find.text('bus_money.save_expense');
    // The CTA itself — its label is swapped for a spinner while saving.
    final cta = find.byWidgetPredicate(
      (w) => w is UgamCTA && w.label == 'bus_money.save_expense',
    );
    await tester.tap(save);
    await tester.pump();
    await tester.tap(cta, warnIfMissed: false);
    await tester.pump();
    expect(money.saves, hasLength(1),
        reason: 'the second tap must not post a second expense');

    // The write fails (timed out) — the sheet stays open for a retry.
    money.pending.single.completeError(Exception('timed out'));
    await tester.pumpAndSettle();
    expect(save, findsOneWidget);

    await tester.tap(save);
    await tester.pump();
    expect(money.saves, hasLength(2));
    expect(money.saves[1].id, money.saves[0].id,
        reason: 'a save that landed but timed out must converge on one row');

    money.pending.last.complete();
    await tester.pumpAndSettle();
    expect(save, findsNothing, reason: 'success closes the sheet');
  });
}
