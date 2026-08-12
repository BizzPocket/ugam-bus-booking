import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:occubusbooking/controllers/handler_controller.dart';
import 'package:occubusbooking/models/bus_details.dart';
import 'package:occubusbooking/models/bus_handover.dart';
import 'package:occubusbooking/models/collection.dart';
import 'package:occubusbooking/models/handler_manifest.dart';
import 'package:occubusbooking/screens/handler/handler_money_tab.dart';

/// What a handover ROW records as the expectation it was settling.
///
/// The handler's sheet has always asked for what is still owed
/// ([HandlerBusMoney.outstanding]), but the row it filed recorded [inHand] —
/// the GROSS the bus generated. Those are the same number on a FIRST handover
/// and diverge on every one after it, so a second partial settlement was
/// written down as "handed ₹5,000 of ₹20,000" when only ₹15,000 was ever owed
/// on that row, and `BusHandover.shortfall` overstated the gap by the cash the
/// handler had already remitted.
///
/// No Supabase under `flutter test`, so the controller is built by hand (its
/// state is plain observables) and the persistence call is intercepted — what
/// this locks is the VALUE the screen hands to `saveHandover`, which is exactly
/// where the bug lived. `tr()` returns raw keys with EasyLocalization
/// uninitialised, so the finders match keys.
class _CapturingController extends HandlerController {
  _CapturingController() : super(requestId: 'req-1');

  final saved = <({double expected, double amount})>[];

  @override
  Future<void> saveHandover({
    required Bus bus,
    required String draftId,
    required double expected,
    required double amount,
    required String? note,
  }) async {
    saved.add((expected: expected, amount: amount));
  }
}

void main() {
  const busId = 'bus-1';
  final bus = Bus(id: busId, tourId: 'tour-1', name: 'Bus 1');

  tearDown(Get.reset);

  /// A bus holding [collected] rupees of fare cash and nothing else: no
  /// passengers (so no seat fares to collect), no expenses, no income. inHand
  /// is therefore exactly [collected].
  _CapturingController controllerWith(
    double collected, {
    List<BusHandover> handovers = const [],
  }) {
    final c = _CapturingController();
    c.manifest.value = HandlerManifest(buses: [bus]);
    c.collections['p-1|$busId|A1'] = Collection(
      tourId: 'tour-1',
      busId: busId,
      passengerId: 'p-1',
      seatId: 'A1',
      amountDue: collected,
      amountReceived: collected,
    );
    for (final h in handovers) {
      c.handovers[h.id] = h;
    }
    return c;
  }

  Widget app(HandlerController c) => GetMaterialApp(
        theme: ThemeData(brightness: Brightness.dark),
        home: Scaffold(
          body: HandlerMoneyTab(controller: c, bus: bus),
        ),
      );

  /// Open the settlement sheet from the card CTA, which sits below the fold of
  /// the 800×600 test viewport.
  Future<void> openSheet(WidgetTester tester) async {
    final cta = find.text('handler_chart.settle_cta');
    await tester.ensureVisible(cta);
    await tester.pumpAndSettle();
    await tester.tap(cta);
    await tester.pumpAndSettle();
  }

  Future<void> saveSheet(WidgetTester tester) async {
    await tester.tap(find.text('handler_chart.handover_save'));
    await tester.pumpAndSettle();
  }

  /// Hand over exactly what the sheet pre-fills — the whole remaining balance,
  /// by far the common case.
  Future<void> handOverThePrefill(WidgetTester tester) async {
    await openSheet(tester);
    await saveSheet(tester);
  }

  testWidgets('the FIRST handover records the whole balance as expected', (
    tester,
  ) async {
    final c = controllerWith(20000);
    await tester.pumpWidget(app(c));
    await tester.pumpAndSettle();

    await handOverThePrefill(tester);

    // Nothing has been handed over yet, so gross and outstanding agree — this
    // case reads the same before and after the fix and must stay that way.
    expect(c.saved.single.expected, 20000);
    expect(c.saved.single.amount, 20000);
  });

  testWidgets('a SECOND handover expects only what is still owed', (
    tester,
  ) async {
    // ₹20,000 collected, ₹5,000 already handed to the organiser on the
    // roadside. The handler settles the rest.
    final c = controllerWith(
      20000,
      handovers: [
        BusHandover(
          id: 'h-1',
          tourId: 'tour-1',
          busId: busId,
          expectedAmount: 20000,
          handedOverAmount: 5000,
          source: 'handler',
        ),
      ],
    );
    await tester.pumpWidget(app(c));
    await tester.pumpAndSettle();

    await handOverThePrefill(tester);

    expect(c.saved.single.amount, 15000, reason: 'the sheet asks for the rest');
    expect(
      c.saved.single.expected,
      15000,
      reason: 'the row must expect the ₹15,000 outstanding, not the ₹20,000 '
          'gross — ₹5,000 of which the organiser already holds',
    );
  });

  testWidgets('two sequential partials each expect the balance of their moment',
      (tester) async {
    // The full trace: ₹20,000 in hand, handed over ₹8,000 then ₹12,000. The
    // recorded expectations must be ₹20,000 then ₹12,000 — never ₹20,000 twice,
    // which is what made the admin's ledger read two rows both claiming the
    // full gross was owed.
    final c = controllerWith(20000);
    await tester.pumpWidget(app(c));
    await tester.pumpAndSettle();

    await openSheet(tester);
    await tester.enterText(find.byType(TextField).first, '8000');
    await saveSheet(tester);

    // The intercepted save never reaches the store, so mirror the row the
    // server would have returned — that is what the second sheet reads.
    c.handovers['h-1'] = BusHandover(
      id: 'h-1',
      tourId: 'tour-1',
      busId: busId,
      expectedAmount: c.saved.first.expected,
      handedOverAmount: 8000,
      source: 'handler',
    );
    await tester.pumpAndSettle();

    await handOverThePrefill(tester);

    expect(c.saved.map((s) => s.expected).toList(), [20000, 12000]);
    expect(c.saved.map((s) => s.amount).toList(), [8000, 12000]);
  });
}
