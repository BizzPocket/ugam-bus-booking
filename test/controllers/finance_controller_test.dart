import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:occubusbooking/controllers/finance_controller.dart';
import 'package:occubusbooking/controllers/tour_controller.dart';
import 'package:occubusbooking/models/tour.dart';
import 'package:occubusbooking/models/tour_finance.dart';
import 'package:occubusbooking/models/tour_status.dart';

/// Inert [TourController]: [onInit] is overridden so registering it never
/// starts the realtime subscription or the connectivity listener. These tests
/// exercise pure report logic over an in-memory tours list — nothing here
/// reaches the network, so the real init would only pull in Sync/Realtime
/// services the report never touches.
class _InertTours extends TourController {
  @override
  // ignore: must_call_super
  void onInit() {}
}

/// The cross-tour P&L behind the Settings finance card and the Finance report.
///
/// The reported symptom was "the settings page finance option is not working":
/// the card sat at ₹0 and the report showed its empty state no matter how much
/// money the agent had taken. The cause was scope, not the fetch — the report
/// counted ONLY tours manually marked [TourStatus.completed]. These lock the
/// scope in so it can't silently narrow again.
void main() {
  Tour tourOn(DateTime date, TourStatus status, {String? id}) => Tour(
        id: id,
        title: 'Trip ${date.toIso8601String()}',
        fromCity: 'Surat',
        toCity: 'Goa',
        departureDate: date,
        returnDate: date,
        pricePerSeat: 1000,
        status: status,
      );

  late FinanceController finance;
  late TourController tours;

  setUp(() {
    Get.reset();
    tours = _InertTours();
    Get.put<TourController>(tours);
    finance = FinanceController();
  });

  tearDown(Get.reset);

  group('report scope', () {
    test('counts running tours, not just completed ones', () {
      final now = DateTime.now();
      tours.tours.assignAll([
        tourOn(now, TourStatus.locked),
        tourOn(now, TourStatus.completed),
        tourOn(now, TourStatus.collecting),
      ]);

      // The whole reason the card read ₹0 mid-season.
      expect(finance.financesFor(FinancePeriod.allTime).length, 3);
    });

    test('completedOnly still narrows to realised P&L when asked', () {
      final now = DateTime.now();
      tours.tours.assignAll([
        tourOn(now, TourStatus.locked),
        tourOn(now, TourStatus.completed),
      ]);

      final realised =
          finance.financesFor(FinancePeriod.allTime, completedOnly: true);
      expect(realised.length, 1);
      expect(realised.single.isCompleted, isTrue);
    });

    test('each row still reports whether the trip is finished', () {
      final now = DateTime.now();
      tours.tours.assignAll([
        tourOn(now, TourStatus.completed, id: 'done'),
        tourOn(now, TourStatus.locked, id: 'running'),
      ]);

      final byId = {
        for (final f in finance.financesFor(FinancePeriod.allTime))
          f.tourId: f,
      };
      expect(byId['done']!.isCompleted, isTrue);
      expect(byId['running']!.isCompleted, isFalse);
    });
  });

  group('period filter', () {
    test('all-time keeps trips from previous years', () {
      tours.tours.assignAll([
        tourOn(DateTime(2020, 3, 4), TourStatus.completed),
        tourOn(DateTime.now(), TourStatus.locked),
      ]);
      expect(finance.financesFor(FinancePeriod.allTime).length, 2);
    });

    test('this-month drops a trip that ended in another month', () {
      tours.tours.assignAll([tourOn(DateTime(2020, 3, 4), TourStatus.completed)]);
      expect(finance.financesFor(FinancePeriod.thisMonth), isEmpty);
      // …which is exactly why the report no longer OPENS on this month.
      expect(finance.financesFor(FinancePeriod.allTime).length, 1);
    });

    test('newest trip first', () {
      tours.tours.assignAll([
        tourOn(DateTime(2021, 1, 1), TourStatus.completed, id: 'old'),
        tourOn(DateTime(2024, 1, 1), TourStatus.completed, id: 'new'),
        tourOn(DateTime(2022, 1, 1), TourStatus.completed, id: 'mid'),
      ]);
      expect(
        finance.financesFor(FinancePeriod.allTime).map((f) => f.tourId),
        ['new', 'mid', 'old'],
      );
    });
  });

  group('staleness', () {
    test('markStale is a no-op before the first load', () async {
      finance.markStale();
      // Nothing loaded yet, so refreshIfStale must fall through to the normal
      // first-load path rather than believing it already has data.
      expect(finance.loadedOnce.value, isFalse);
    });

    test('a money write re-arms the cached totals', () {
      // Simulate a completed first load.
      finance.loadedOnce.value = true;
      finance.markStale();
      // Still "loaded" — the stale figure keeps showing rather than flashing ₹0
      // while a refetch is in flight.
      expect(finance.loadedOnce.value, isTrue);
    });
  });
}
