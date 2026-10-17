import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:occubusbooking/controllers/money_controller.dart';
import 'package:occubusbooking/models/bus_details.dart';
import 'package:occubusbooking/models/bus_type.dart';
import 'package:occubusbooking/models/collection.dart';
import 'package:occubusbooking/models/passenger.dart';
import 'package:occubusbooking/models/seat_assignment.dart';
import 'package:occubusbooking/models/seat_layout.dart';
import 'package:occubusbooking/models/tour.dart';
import 'package:occubusbooking/screens/collection_screen.dart';
import 'package:occubusbooking/widgets/board/passenger_sheet.dart'
    show BoardUndoToast;

/// Records money writes in memory instead of hitting SyncService, mirroring
/// what the real controller does to the obs list so the screen re-renders.
class _RecordingMoney extends MoneyController {
  final upserts = <Collection>[];
  final deletes = <String>[];
  int refreshes = 0;

  @override
  Future<void> loadForTour(String tourId) async {}

  @override
  Future<void> refreshForTour(String tourId) async => refreshes++;

  @override
  Future<void> upsertCollection(Collection c) async {
    upserts.add(c);
    final i = collections.indexWhere((e) => e.id == c.id);
    if (i >= 0) {
      collections[i] = c;
    } else {
      collections.add(c);
    }
    collections.refresh();
  }

  @override
  Future<void> deleteCollection(String id) async {
    deletes.add(id);
    collections.removeWhere((c) => c.id == id);
  }
}

Bus _bus() => Bus(
  id: 'b1',
  name: 'Vantara',
  busType: 'Sleeper',
  pricePerSeat: 1200,
  layout: BusLayout.generate(busType: BusType.sleeper, totalSeats: 30),
);

String _firstSeatId() => _bus().layout!.grid
    .firstWhere((c) => c.seatId != null && c.seatId!.isNotEmpty)
    .seatId!;

Passenger _rider(String seat) => Passenger(
  id: 'p1',
  tourId: 't1',
  name: 'Dr janak',
  phone: '9876543210',
  assignedSeats: [SeatAssignment(busId: 'b1', seatId: seat)],
);

Widget _harness(String seat) {
  final bus = _bus();
  return GetMaterialApp(
    theme: ThemeData(brightness: Brightness.dark),
    home: CollectionScreen(
      tour: Tour(
        id: 't1',
        title: 'Dwarka Yatra',
        fromCity: 'Surat',
        toCity: 'Dwarka',
        departureDate: DateTime(2026, 7, 1),
        pricePerSeat: 1200,
        buses: [bus],
        passengers: [_rider(seat)],
      ),
      bus: bus,
    ),
  );
}

void main() {
  tearDown(() {
    BoardUndoToast.dismiss();
    Get.reset();
  });

  void tall(WidgetTester tester) {
    tester.view.physicalSize = const Size(1200, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  testWidgets(
    'a mis-tapped ✓ can be undone from the toast: the new row is deleted',
    (tester) async {
      tall(tester);
      final seat = _firstSeatId();
      final money = _RecordingMoney();
      Get.put<MoneyController>(money);
      money.loadedOnce.value = true;

      await tester.pumpWidget(_harness(seat));
      await tester.pump();

      final markPaid = find.byKey(ValueKey('mark-paid-$seat-p1'));
      expect(markPaid, findsOneWidget, reason: 'an owing seat offers ✓');
      await tester.tap(markPaid);
      await tester.pump();

      expect(money.upserts, hasLength(1));
      final written = money.upserts.single;
      expect(written.amountReceived, greaterThan(0));
      // Paid now → the row swaps ✓ for the undo control.
      expect(find.byKey(ValueKey('undo-paid-$seat-p1')), findsOneWidget);

      // The toast's Undo restores the prior state: no row existed, so it is
      // deleted rather than zeroed.
      await tester.tap(find.text('actions.undo'));
      await tester.pump();
      expect(money.deletes, [written.id]);
      expect(money.collections, isEmpty);
      expect(find.byKey(ValueKey('mark-paid-$seat-p1')), findsOneWidget);
    },
  );

  testWidgets('a Paid row reverses its payment only after a confirm', (
    tester,
  ) async {
    tall(tester);
    final seat = _firstSeatId();
    final money = _RecordingMoney();
    Get.put<MoneyController>(money);
    money.loadedOnce.value = true;
    await tester.pumpWidget(_harness(seat));
    await tester.pump();

    // Settle in full via ✓, then dismiss the toast so only the row control is
    // left to undo with.
    await tester.tap(find.byKey(ValueKey('mark-paid-$seat-p1')));
    await tester.pump();
    BoardUndoToast.dismiss();
    await tester.pump();
    final paid = money.collections.single;

    final undo = find.byKey(ValueKey('undo-paid-$seat-p1'));
    expect(undo, findsOneWidget);

    // Cancel leaves the money alone.
    await tester.tap(undo);
    await tester.pumpAndSettle();
    expect(find.text('collection.undo_payment_title'), findsOneWidget);
    await tester.tap(find.text('app.action.cancel'));
    await tester.pumpAndSettle();
    expect(money.deletes, isEmpty);

    // Confirm removes the recorded row and the seat owes again.
    await tester.tap(undo);
    await tester.pumpAndSettle();
    await tester.tap(find.text('collection.undo_payment_confirm'));
    await tester.pumpAndSettle();
    expect(money.deletes, [paid.id]);
    expect(find.byKey(ValueKey('mark-paid-$seat-p1')), findsOneWidget);
    expect(
      money.refreshes,
      greaterThan(0),
      reason: 'header totals refetch after the reversal',
    );
  });
}
