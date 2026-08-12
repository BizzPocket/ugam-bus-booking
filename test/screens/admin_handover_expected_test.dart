import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:occubusbooking/controllers/money_controller.dart';
import 'package:occubusbooking/models/bus_details.dart';
import 'package:occubusbooking/models/bus_handover.dart';
import 'package:occubusbooking/models/bus_type.dart';
import 'package:occubusbooking/models/collection.dart';
import 'package:occubusbooking/models/seat_layout.dart';
import 'package:occubusbooking/models/tour.dart';
import 'package:occubusbooking/screens/bus_money_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The ADMIN half of the handover-expectation bug, and the provenance the
/// admin's ledger never showed.
///
/// 1. What a handover ROW records as the expectation it settles. The admin's
///    "Record" action seeded the sheet with [BusMoneySummary.expectedHandover]
///    — the GROSS the bus generated — so a SECOND partial settlement was
///    written down as owing money the admin was already holding, and the row
///    then read "Handed ₹5,000 of ₹20,000" on a row that only ever owed
///    ₹15,000. The handler's own sheet took this correction first
///    (handler_money_tab.dart:270, `summary.outstanding`); the admin's did not.
///    Note the property names differ across the two sides: the handler reads
///    `HandlerBusMoney.inHand`/`outstanding`, the admin
///    `BusMoneySummary.expectedHandover`/`outstandingHandover`.
///
/// 2. `BusHandover.source` was selected and parsed but only ever read for the
///    handler's edit permission, so an admin reconciling cash could not tell a
///    row the handler filed on the bus from one the office typed in.
///
/// No Supabase under `flutter test`: [MoneyController]'s persistence call is
/// intercepted, which is exactly where the seeded expectation lands. Real
/// translations ARE loaded (the handover row calls `context.locale`, which
/// needs an EasyLocalization ancestor), so finders resolve through `tr()`
/// rather than hardcoded English.
class _CapturingMoneyController extends MoneyController {
  final recorded = <BusHandover>[];

  @override
  Future<void> loadForTour(String tourId) async {}

  @override
  Future<void> refreshForTour(String tourId) async {}

  @override
  Future<void> recordHandover(BusHandover h) async {
    recorded.add(h);
    // Mirror the real controller's optimistic local insert, so a SECOND sheet
    // opened after this one reads the balance this row just moved.
    handovers.add(h);
    handovers.refresh();
  }
}

Bus _bus() => Bus(
      id: 'b1',
      tourId: 't1',
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

Widget _harness() => EasyLocalization(
      supportedLocales: const [Locale('en')],
      path: 'assets/translations',
      fallbackLocale: const Locale('en'),
      startLocale: const Locale('en'),
      child: Builder(
        builder: (context) => GetMaterialApp(
          theme: ThemeData(brightness: Brightness.dark),
          localizationsDelegates: context.localizationDelegates,
          supportedLocales: context.supportedLocales,
          locale: context.locale,
          home: BusMoneyScreen(tour: _tour(), bus: _bus()),
        ),
      ),
    );

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await EasyLocalization.ensureInitialized();
  });

  tearDown(Get.reset);

  /// Tall enough that the whole cockpit — hero, stats, expenses, income and the
  /// handover section — lays out without scrolling, so "Record" is directly
  /// tappable and every handover row is in the tree.
  void useTallSurface(WidgetTester tester) {
    tester.view.physicalSize = const Size(1200, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  /// A bus holding [collected] rupees of fare cash and nothing else: no
  /// expenses, no income, no rent. expectedHandover is therefore exactly
  /// [collected], and outstandingHandover is that minus whatever [handovers]
  /// already remitted.
  _CapturingMoneyController controllerWith(
    double collected, {
    List<BusHandover> handovers = const [],
  }) {
    final money = _CapturingMoneyController();
    money.collections.assignAll([
      Collection(
        tourId: 't1',
        busId: 'b1',
        passengerId: 'p1',
        seatId: 'A1',
        amountDue: collected,
        amountReceived: collected,
      ),
    ]);
    money.handovers.assignAll(handovers);
    return money;
  }

  Future<void> mount(
    WidgetTester tester,
    _CapturingMoneyController money,
  ) async {
    // Put BEFORE pumping: the screen resolves the controller in a field
    // initializer.
    Get.put<MoneyController>(money);
    // EasyLocalization reads its JSON off the asset bundle with REAL async
    // I/O, which only makes progress inside runAsync.
    await tester.runAsync(() async {
      await tester.pumpWidget(_harness());
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pumpAndSettle();
  }

  Future<void> openSheet(WidgetTester tester) async {
    // Exact match: the section action is "Record", the sheet title it opens is
    // "Record handover".
    final record = find.text(tr('bus_money.action_record'));
    await tester.ensureVisible(record);
    await tester.pumpAndSettle();
    await tester.tap(record);
    await tester.pumpAndSettle();
  }

  Future<void> saveSheet(WidgetTester tester) async {
    await tester.tap(find.text(tr('bus_money.save_handover')));
    await tester.pumpAndSettle();
  }

  /// Hand over exactly what the sheet pre-fills — the whole remaining balance,
  /// by far the common case.
  Future<void> handOverThePrefill(WidgetTester tester) async {
    await openSheet(tester);
    await saveSheet(tester);
  }

  group('what a handover row records as its expectation', () {
    testWidgets('the FIRST handover records the whole balance', (tester) async {
      useTallSurface(tester);
      final money = controllerWith(20000);
      await mount(tester, money);

      await handOverThePrefill(tester);

      // Nothing has been handed over yet, so gross and outstanding agree — this
      // case reads the same before and after the fix and must stay that way.
      expect(money.recorded.single.expectedAmount, 20000);
      expect(money.recorded.single.handedOverAmount, 20000);
    });

    testWidgets('a SECOND handover expects only what is still owed',
        (tester) async {
      // ₹20,000 collected, ₹5,000 already handed to the office. The admin
      // records the rest.
      final money = controllerWith(
        20000,
        handovers: [
          BusHandover(
            id: 'h-1',
            tourId: 't1',
            busId: 'b1',
            expectedAmount: 20000,
            handedOverAmount: 5000,
          ),
        ],
      );
      useTallSurface(tester);
      await mount(tester, money);

      await handOverThePrefill(tester);

      expect(
        money.recorded.single.handedOverAmount,
        15000,
        reason: 'the sheet asks for the rest',
      );
      expect(
        money.recorded.single.expectedAmount,
        15000,
        reason: 'the row must expect the ₹15,000 outstanding, not the ₹20,000 '
            'gross — ₹5,000 of which the office already holds',
      );
    });

    testWidgets('two sequential partials each expect the balance of the moment',
        (tester) async {
      // ₹20,000 in hand, handed over ₹8,000 then ₹12,000. The recorded
      // expectations must be ₹20,000 then ₹12,000 — never ₹20,000 twice, which
      // is what made the ledger show two rows both claiming the full gross.
      useTallSurface(tester);
      final money = controllerWith(20000);
      await mount(tester, money);

      await openSheet(tester);
      await tester.enterText(find.byType(TextField).first, '8000');
      await saveSheet(tester);

      await handOverThePrefill(tester);

      expect(
        money.recorded.map((h) => h.expectedAmount).toList(),
        [20000, 12000],
      );
      expect(
        money.recorded.map((h) => h.handedOverAmount).toList(),
        [8000, 12000],
      );
    });
  });

  group('who recorded the settlement', () {
    testWidgets('the row names the handler for a handler-filed settlement',
        (tester) async {
      useTallSurface(tester);
      final money = controllerWith(
        20000,
        handovers: [
          BusHandover(
            id: 'h-1',
            tourId: 't1',
            busId: 'b1',
            expectedAmount: 20000,
            handedOverAmount: 5000,
            source: 'handler',
          ),
        ],
      );
      await mount(tester, money);

      expect(find.text(tr('bus_money.handover_by_handler')), findsOneWidget);
      expect(find.text(tr('bus_money.handover_by_admin')), findsNothing);
    });

    testWidgets('and the admin for one the office typed in', (tester) async {
      useTallSurface(tester);
      final money = controllerWith(
        20000,
        handovers: [
          BusHandover(
            id: 'h-1',
            tourId: 't1',
            busId: 'b1',
            expectedAmount: 20000,
            handedOverAmount: 5000,
            // Postgres' own default, and what BusHandover.fromMap falls back to
            // for an unrecognised value.
          ),
        ],
      );
      await mount(tester, money);

      expect(find.text(tr('bus_money.handover_by_admin')), findsOneWidget);
      expect(find.text(tr('bus_money.handover_by_handler')), findsNothing);
    });

    testWidgets('two rows from different sources are told apart',
        (tester) async {
      useTallSurface(tester);
      final money = controllerWith(
        20000,
        handovers: [
          BusHandover(
            id: 'h-1',
            tourId: 't1',
            busId: 'b1',
            expectedAmount: 20000,
            handedOverAmount: 5000,
            source: 'handler',
          ),
          BusHandover(
            id: 'h-2',
            tourId: 't1',
            busId: 'b1',
            expectedAmount: 15000,
            handedOverAmount: 3000,
            source: 'admin',
          ),
        ],
      );
      await mount(tester, money);

      expect(find.text(tr('bus_money.handover_by_handler')), findsOneWidget);
      expect(find.text(tr('bus_money.handover_by_admin')), findsOneWidget);
    });
  });
}
