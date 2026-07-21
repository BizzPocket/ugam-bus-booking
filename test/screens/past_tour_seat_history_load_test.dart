import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:occubusbooking/controllers/tour_controller.dart';
import 'package:occubusbooking/design/components/ugam_skeleton.dart';
import 'package:occubusbooking/models/tour_seat_snapshot.dart';
import 'package:occubusbooking/screens/past_tour_seat_history_screen.dart';

/// AS-3 regression: a snapshot load that THROWS must still clear `_loading`
/// so the screen falls back to the live/empty path instead of shimmering
/// forever. Mirrors the `_FakeTourController` idiom from
/// past_tour_seat_history_screen_test.dart — [onInit] is a no-op so
/// registering it doesn't start the real `_loadTours` + realtime
/// subscription, and [loadSeatSnapshots] is overridden, here to throw.
class _ThrowingTourController extends TourController {
  @override
  // ignore: must_call_super
  void onInit() {}

  @override
  Future<List<TourSeatSnapshot>> loadSeatSnapshots(String tourId) async {
    throw StateError('snapshot load boom');
  }
}

void main() {
  tearDown(Get.reset);

  testWidgets('a thrown snapshot load clears the skeleton (no infinite shimmer)',
      (tester) async {
    Get.put<TourController>(_ThrowingTourController());

    await tester.pumpWidget(const GetMaterialApp(
      home: PastTourSeatHistoryScreen(tourId: 'unknown'),
    ));
    await tester.pumpAndSettle();

    // Before the fix: `_loading` stays true forever because `_load()` has no
    // try/catch/finally, so the skeleton never clears.
    expect(find.byType(UgamSkeleton), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
