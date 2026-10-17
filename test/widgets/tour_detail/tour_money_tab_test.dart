import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:occubusbooking/controllers/money_controller.dart';
import 'package:occubusbooking/controllers/tour_controller.dart';
import 'package:occubusbooking/design/ugam.dart';
import 'package:occubusbooking/models/bus_details.dart';
import 'package:occubusbooking/models/bus_type.dart';
import 'package:occubusbooking/models/collection.dart';
import 'package:occubusbooking/models/passenger.dart';
import 'package:occubusbooking/models/request_line.dart';
import 'package:occubusbooking/models/seat_assignment.dart';
import 'package:occubusbooking/models/seat_layout.dart';
import 'package:occubusbooking/models/seat_type.dart';
import 'package:occubusbooking/models/tour.dart';
import 'package:occubusbooking/models/trip_type.dart';
import 'package:occubusbooking/widgets/tour_detail/tour_money_tab.dart';
import 'package:occubusbooking/widgets/tour_detail/tour_overview_cockpit.dart';

/// The money controller holds ONE tour's rows at a time. Before the fix, the
/// tour-detail Money tab and the Overview "money due" vital read
/// `tourSummary()` unconditionally, so opening tour B straight after the
/// dashboard had loaded tour A painted A's money under B's name.

class _FakeTourController extends TourController {
  @override
  // ignore: must_call_super
  void onInit() {}
}

class _FakeMoneyController extends MoneyController {
  String? fakeLoadedTourId;

  @override
  String? get loadedTourId => fakeLoadedTourId;

  @override
  Future<void> loadForTour(String tourId) async {
    // No-op: the test decides which tour is "loaded".
  }
}

Bus _bus(String id) => Bus(
      id: id,
      name: 'Bus $id',
      busType: 'Sleeper',
      layout: BusLayout.generate(busType: BusType.sleeper, totalSeats: 30),
    );

Tour _tour(String id, {List<Passenger> passengers = const []}) => Tour(
      id: id,
      title: 'Tour $id',
      fromCity: 'Surat',
      toCity: 'Dwarka',
      departureDate: DateTime(2026, 9, 1),
      pricePerSeat: 1200,
      buses: [_bus('b-$id')],
      passengers: passengers,
    );

/// Tour A's money: ₹4,321 collected.
_FakeMoneyController _moneyHoldingTourA() {
  final money = _FakeMoneyController()..fakeLoadedTourId = 'tA';
  money.loadedOnce.value = true;
  money.collections.assignAll([
    Collection(
      tourId: 'tA',
      busId: 'b-tA',
      passengerId: 'p1',
      seatId: 'A1',
      amountDue: 4321,
      amountReceived: 4321,
    ),
  ]);
  return money;
}

Widget _sliverHost(Widget sliver) => GetMaterialApp(
      theme: ThemeData(brightness: Brightness.dark),
      home: Builder(
        builder: (context) => Scaffold(
          body: CustomScrollView(slivers: [sliver]),
        ),
      ),
    );

Widget _boxHost(Widget child) => GetMaterialApp(
      theme: ThemeData(brightness: Brightness.dark),
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

void main() {
  tearDown(Get.reset);

  void useTallSurface(WidgetTester tester) {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  group('TourMoneyTab', () {
    testWidgets('never shows another tour\'s money while its own is not loaded',
        (tester) async {
      useTallSurface(tester);
      Get.put<TourController>(_FakeTourController());
      final money = Get.put<MoneyController>(_moneyHoldingTourA());
      final tourB = _tour('tB');
      (Get.find<TourController>()).tours.assignAll([_tour('tA'), tourB]);

      await tester.pumpWidget(
        _sliverHost(TourMoneyTab(tour: tourB, c: UgamColors.dark)),
      );
      await tester.pump();

      expect(find.text('₹4,321'), findsNothing,
          reason: 'tour A\'s collected total must not render on tour B');
      expect(find.byType(UgamSkeleton), findsWidgets);
      expect(money.loadedTourId, 'tA');
    });

    testWidgets('shows the summary once THIS tour is loaded', (tester) async {
      useTallSurface(tester);
      Get.put<TourController>(_FakeTourController());
      Get.put<MoneyController>(_moneyHoldingTourA());
      final tourA = _tour('tA');
      (Get.find<TourController>()).tours.assignAll([tourA]);

      await tester.pumpWidget(
        _sliverHost(TourMoneyTab(tour: tourA, c: UgamColors.dark)),
      );
      await tester.pump();

      expect(find.text('₹4,321'), findsWidgets);
    });

    testWidgets('labels the per-bus berth count as seats, not riders',
        (tester) async {
      useTallSurface(tester);
      Get.put<TourController>(_FakeTourController());
      Get.put<MoneyController>(_moneyHoldingTourA());
      final tourA = _tour('tA', passengers: [
        Passenger(
          id: 'p1',
          tourId: 'tA',
          name: 'Rider',
          phone: '+919900000000',
          requestLines: [RequestLine(seatType: SeatType.singleSofa, qty: 1)],
          assignedSeats: [
            SeatAssignment(
                busId: 'b-tA', seatId: 'A1', leg: TripType.roundTrip),
          ],
          tripType: TripType.roundTrip,
        ),
      ]);
      (Get.find<TourController>()).tours.assignAll([tourA]);

      await tester.pumpWidget(
        _sliverHost(TourMoneyTab(tour: tourA, c: UgamColors.dark)),
      );
      await tester.pump();

      // tr() is uninitialised in tests, so it renders the raw key.
      expect(find.text('tour_detail.seats_count'), findsOneWidget);
      expect(find.text('tour_detail.vitals_riders_other'), findsNothing);
    });
  });

  group('TourOverviewVitals', () {
    testWidgets('shows "—" rather than another tour\'s money due',
        (tester) async {
      useTallSurface(tester);
      Get.put<TourController>(_FakeTourController());
      Get.put<MoneyController>(_moneyHoldingTourA());
      final tourB = _tour('tB');
      (Get.find<TourController>()).tours.assignAll([_tour('tA'), tourB]);

      await tester.pumpWidget(
        _boxHost(TourOverviewVitals(tour: tourB, c: UgamColors.dark)),
      );
      await tester.pump();

      // The "collected ₹x" sub-line (raw key: tr() is uninitialised here) only
      // renders when a summary was read.
      expect(find.text('tour_detail.vitals_collected'), findsNothing);
      expect(find.text('—'), findsOneWidget);
    });

    testWidgets('shows the money vital for the loaded tour', (tester) async {
      useTallSurface(tester);
      Get.put<TourController>(_FakeTourController());
      Get.put<MoneyController>(_moneyHoldingTourA());
      final tourA = _tour('tA');
      (Get.find<TourController>()).tours.assignAll([tourA]);

      await tester.pumpWidget(
        _boxHost(TourOverviewVitals(tour: tourA, c: UgamColors.dark)),
      );
      await tester.pump();

      expect(find.text('tour_detail.vitals_collected'), findsOneWidget);
      expect(find.text('—'), findsNothing);
    });
  });
}
