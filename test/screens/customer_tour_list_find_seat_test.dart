import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:occubusbooking/controllers/tour_controller.dart';
import 'package:occubusbooking/models/tour.dart';
import 'package:occubusbooking/models/tour_status.dart';
import 'package:occubusbooking/screens/customer_tour_list_screen.dart';
import 'package:occubusbooking/screens/find_my_seat_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Test double for [TourController] mirroring the screen-test idiom (see
/// tours_screen_past_test.dart): [onInit] is a no-op so registering it does NOT
/// start the real `_loadTours` + realtime subscription.
class _FakeTourController extends TourController {
  @override
  // ignore: must_call_super
  void onInit() {
    // Intentionally empty: skip the real network load + realtime wiring.
  }
}

Tour _upcomingTour() => Tour(
      id: 'up1',
      title: 'Dwarka Yatra',
      fromCity: 'Surat',
      toCity: 'Dwarka',
      departureDate: DateTime(2099, 1, 1),
      pricePerSeat: 1200,
      status: TourStatus.planning,
    );

Widget _harness() => GetMaterialApp(
      theme: ThemeData(brightness: Brightness.dark),
      home: const CustomerTourListScreen(),
    );

/// Puts the customer home on screen with one visible tour. EasyLocalization is
/// not initialised in tests, so every tr() renders as its RAW KEY — the bar's
/// heading is the literal 'find_seat.title'.
Future<void> _pumpHome(WidgetTester tester) async {
  final ctrl = _FakeTourController();
  Get.put<TourController>(ctrl);
  ctrl.tours.assignAll([_upcomingTour()]);
  await tester.pumpWidget(_harness());
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(Get.reset);

  group('the customer home screen', () {
    testWidgets(
        'offers "Find my seat" on the first screen — the rider who already '
        'booked never has to go hunting through a menu for it', (tester) async {
      await _pumpHome(tester);

      expect(find.text('find_seat.title'), findsOneWidget);
      expect(find.text('find_seat.home_subtitle'), findsOneWidget);
    });

    testWidgets(
        'has NO search box — with two or three live tours the whole list is '
        'already on screen, so a filter could only ever hide rows',
        (tester) async {
      await _pumpHome(tester);

      expect(find.byIcon(Icons.search_rounded), findsNothing);
      expect(find.byIcon(Icons.search_off_rounded), findsNothing);
      // The hamburger promised a drawer this app has never had.
      expect(find.byIcon(Icons.menu_rounded), findsNothing);
      expect(find.byIcon(Icons.more_horiz_rounded), findsOneWidget);
    });

    testWidgets(
        'the bar starts folded and opens a number field in place — a first-time '
        'visitor loses one line of tour list, not a whole screen',
        (tester) async {
      await _pumpHome(tester);

      expect(find.text('find_seat.home_action'), findsNothing);

      await tester.tap(find.text('find_seat.title'));
      await tester.pumpAndSettle();

      expect(find.text('find_seat.home_action'), findsOneWidget);
      expect(find.text('find_seat.phone_hint'), findsOneWidget);
    });

    testWidgets(
        'the number typed on the home screen is carried into the lookup — the '
        'rider types it once, not twice', (tester) async {
      await _pumpHome(tester);

      await tester.tap(find.text('find_seat.title'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '98765 43210');
      await tester.tap(find.text('find_seat.home_action'));
      await tester.pumpAndSettle();

      final screen = tester.widget<FindMySeatScreen>(
        find.byType(FindMySeatScreen),
      );
      expect(screen.initialPhone, '98765 43210');
    });

    testWidgets(
        'a rider who found their seat before opens with that number already '
        'filled in — the manually-added passenger has no other thread back',
        (tester) async {
      SharedPreferences.setMockInitialValues({
        'find_my_seat_last_phone_v1': '9876543210',
      });
      await _pumpHome(tester);

      await tester.tap(find.text('find_seat.title'));
      await tester.pumpAndSettle();

      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.controller?.text, '9876543210');
    });
  });

  group('phone display', () {
    test('groups a ten-digit number the way it is read aloud', () {
      expect(prettyPhone('9876543210'), '98765 43210');
    });

    test('drops the country code and separators before grouping — the server '
        'matches on the last ten digits anyway', () {
      expect(prettyPhone('+91 98765-43210'), '98765 43210');
      expect(digitsOfPhone('+91 98765-43210'), '919876543210');
    });

    test('renders a half-typed number as-is rather than mis-grouping it', () {
      expect(prettyPhone('98765'), '98765');
    });
  });
}
