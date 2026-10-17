import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:occubusbooking/controllers/tour_controller.dart';
import 'package:occubusbooking/models/tour.dart';
import 'package:occubusbooking/models/tour_status.dart';
import 'package:occubusbooking/screens/tours_screen.dart';

/// Test double for [TourController] mirroring the screen-test idiom (see
/// tour_groups_screen_test.dart / seats_screen_test.dart): [onInit] is a no-op
/// so registering it does NOT start the real `_loadTours` + realtime
/// subscription. The screen reads `tours` straight off the controller, so the
/// test just seeds that list.
class _FakeTourController extends TourController {
  @override
  // ignore: must_call_super
  void onInit() {
    // Intentionally empty: skip the real network load + realtime wiring.
  }
}

/// A clearly PAST tour: its end day (no return date → departureDate) is years
/// before today, so `_group` files it into the collapsed Past bucket.
Tour _pastTour() => Tour(
      id: 'past1',
      title: 'Old Somnath Yatra',
      fromCity: 'Surat',
      toCity: 'Somnath',
      departureDate: DateTime(2020, 1, 1),
      pricePerSeat: 1000,
      status: TourStatus.completed,
    );

/// A clearly UPCOMING tour: a far-future departure so it never lands in Past.
Tour _upcomingTour() => Tour(
      id: 'up1',
      title: 'Future Dwarka Yatra',
      fromCity: 'Surat',
      toCity: 'Dwarka',
      departureDate: DateTime(2099, 1, 1),
      pricePerSeat: 1200,
      status: TourStatus.planning,
    );

Widget _harness() => GetMaterialApp(
      theme: ThemeData(brightness: Brightness.dark),
      home: const ToursScreen(),
    );

void main() {
  tearDown(Get.reset);

  testWidgets(
      'browse mode collapses past tours behind a Past trips header, upcoming '
      'visible', (tester) async {
    final ctrl = _FakeTourController();
    Get.put<TourController>(ctrl);
    ctrl.tours.assignAll([_pastTour(), _upcomingTour()]);

    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    // Past tours sit behind a COLLAPSED "Past trips (n)" header in browse
    // mode (changed intentionally — they used to be reachable only by
    // search): the header shows, the past tour itself does not until tapped.
    expect(find.text('tours.group.past_trips'), findsOneWidget);
    expect(find.text('Old Somnath Yatra'), findsNothing);

    // The upcoming tour IS visible.
    expect(find.text('Future Dwarka Yatra'), findsOneWidget);

    // One tap on the header reveals the past tour.
    await tester.tap(find.text('tours.group.past_trips'));
    await tester.pumpAndSettle();
    expect(find.text('Old Somnath Yatra'), findsOneWidget);
  });

  testWidgets('searching surfaces the Past group with the matching past tour',
      (tester) async {
    final ctrl = _FakeTourController();
    Get.put<TourController>(ctrl);
    ctrl.tours.assignAll([_pastTour(), _upcomingTour()]);

    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    // Open the search field (app-bar icon) and query the past tour.
    await tester.tap(find.byIcon(Icons.search_rounded));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'Somnath');
    await tester.pumpAndSettle();

    // Now the Past group renders (search surfaces it) with the matching tour,
    // and the non-matching upcoming tour is filtered out.
    expect(find.text('tours.group.past_trips'), findsOneWidget);
    expect(find.text('Future Dwarka Yatra'), findsNothing);
  });
}
