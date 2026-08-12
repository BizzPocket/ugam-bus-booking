import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:occubusbooking/controllers/handler_controller.dart';
import 'package:occubusbooking/design/ugam.dart';
import 'package:occubusbooking/models/bus_details.dart';
import 'package:occubusbooking/models/bus_type.dart';
import 'package:occubusbooking/models/handler_manifest.dart';
import 'package:occubusbooking/models/handler_phase.dart';
import 'package:occubusbooking/models/passenger.dart';
import 'package:occubusbooking/models/seat_assignment.dart';
import 'package:occubusbooking/models/seat_layout.dart';
import 'package:occubusbooking/models/trip_type.dart';
import 'package:occubusbooking/components/seat_chart_tile.dart';
import 'package:occubusbooking/screens/handler/handler_chart_tab.dart';
import 'package:occubusbooking/utils/seat_occupants.dart';
import 'package:occubusbooking/widgets/handler/handler_occupant_chooser.dart';

/// Which leg the shared-seat chooser opens on.
///
/// The chart tab computed its own `passengers.any((p) => p.journeyDone)` over
/// the WHOLE TOUR manifest — the same quantifier `Tour.goLegCompleted` was just
/// corrected away from, and wrong here for the same two reasons plus one more:
///
///   * MULTI-BUS — `handler_complete_outbound_leg` (migration 046) retires only
///     the riders seated on ONE bus, so the first bus to arrive flipped every
///     OTHER bus's chart to the return leg while those buses were still
///     boarding, and the handler collected from the wrong roster;
///   * CANCELLED RETURN — `cancelReturnSeatTransform` demotes a round-trip
///     rider to outbound-only + journeyDone, so dropping ONE rider's return
///     flipped the chart before the bus had left;
///   * and the tour-level answer is the wrong QUESTION for this screen anyway:
///     [HandlerChartTab] is scoped to one [Bus].
///
/// The fix is bus-scoped, through [HandlerController.phaseForBus] — i.e. the
/// bus's own `go_arrived_at` milestone, which [HandlerTripState] documents as
/// what ends the GO leg. Same rule [HandlerController.legForBoarding] applies
/// to the boarding roster, so the two can no longer disagree.
///
/// Asserted through the chooser's GO/Return pill (index 0 = GO, 1 = RETURN) —
/// the seed's only visible consequence, and unambiguous while the seat grid
/// behind the modal still shows the same rider names.
class _FakeHandlerController extends HandlerController {
  _FakeHandlerController() : super(requestId: 'req-1');

  // Constructed directly rather than via Get.put, so onInit (and its real
  // Supabase load) never runs.
}

const _busId = 'bus-1';
const _otherBusId = 'bus-2';

final _layout = BusLayout.generate(busType: BusType.sleeper, totalSeats: 6);
final _seatId = _layout.allSeatIds.first;

Bus _bus(String id) =>
    Bus(id: id, tourId: 'tour-1', name: 'Bus $id', layout: _layout);

/// A round-trip rider holding [_seatId] on this bus for BOTH legs.
Passenger _roundTripRider() => Passenger(
      id: 'p-round',
      tourId: 'tour-1',
      name: 'Roundtrip Rider',
      phone: '+919000000001',
      tripType: TripType.roundTrip,
      assignedSeats: [
        SeatAssignment(
          busId: _busId,
          seatId: _seatId,
          leg: TripType.roundTrip,
        ),
      ],
    );

/// A return-only rider sharing the SAME berth on the way home. Her presence is
/// what makes the seat leg-split, so the chooser shows the GO/Return pill — and
/// she is only listed on the RETURN side of it.
Passenger _returnOnlyRider() => Passenger(
      id: 'p-return',
      tourId: 'tour-1',
      name: 'Return Rider',
      phone: '+919000000002',
      tripType: TripType.returnOnly,
      assignedSeats: [
        SeatAssignment(
          busId: _busId,
          seatId: _seatId,
          leg: TripType.returnOnly,
        ),
      ],
    );

/// A one-way rider on a DIFFERENT bus whose leg is already finished — the
/// tour-wide `journeyDone` this screen used to read.
Passenger _retiredRiderOnAnotherBus() => Passenger(
      id: 'p-done',
      tourId: 'tour-1',
      name: 'Finished Rider',
      phone: '+919000000003',
      tripType: TripType.outboundOnly,
      journeyDone: true,
      assignedSeats: const [
        SeatAssignment(busId: _otherBusId, seatId: 'X1'),
      ],
    );

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await EasyLocalization.ensureInitialized();
  });

  tearDown(Get.reset);

  /// Big enough that the whole seat grid lays out and the tapped berth is on
  /// screen; the chooser then opens as a modal over it.
  void useLargeSurface(WidgetTester tester) {
    tester.view.physicalSize = const Size(1400, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  _FakeHandlerController controllerWith({
    required List<Passenger> passengers,
    required List<Bus> buses,
    bool goArrived = false,
  }) {
    final c = _FakeHandlerController();
    c.manifest.value = HandlerManifest(buses: buses, passengers: passengers);
    c.selectedBusId.value = _busId;
    if (goArrived) {
      c.tripState[_busId] = HandlerTripState(
        busId: _busId,
        goDepartedAt: DateTime(2026, 7, 1, 6),
        goArrivedAt: DateTime(2026, 7, 1, 14),
      );
    }
    return c;
  }

  // Real translations, not raw keys: the chooser's rider tiles lay a Call and
  // a Collect button beside the name, and 30-character translation KEYS blow
  // that row out in a way the shipped copy never does.
  Widget app(HandlerController c) => EasyLocalization(
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
            home: Scaffold(
              body: HandlerChartTab(controller: c, bus: _bus(_busId)),
            ),
          ),
        ),
      );

  /// EasyLocalization reads its JSON off the asset bundle with REAL async I/O,
  /// which only makes progress inside runAsync.
  Future<void> mount(WidgetTester tester, HandlerController c) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(app(c));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pumpAndSettle();
  }

  /// Taps the shared berth and returns the leg its chooser opened on.
  Future<CollectLeg> openChooser(WidgetTester tester) async {
    final seat = find.byWidgetPredicate(
      (w) => w is SeatChartTile && w.occupants.any((p) => p.id == 'p-return'),
    );
    expect(seat, findsOneWidget, reason: 'the shared berth must render');
    await tester.ensureVisible(seat);
    await tester.pumpAndSettle();
    await tester.tap(seat);
    await tester.pumpAndSettle();

    expect(
      find.byType(HandlerOccupantChooserSheet),
      findsOneWidget,
      reason: 'a berth with two riders opens the chooser, not the collect sheet',
    );
    final pills = tester.widget<UgamTabPills>(find.byType(UgamTabPills));
    return pills.currentIndex == 0 ? CollectLeg.go : CollectLeg.ret;
  }

  testWidgets(
      'another bus finishing its outbound leaves THIS bus on the GO leg',
      (tester) async {
    useLargeSurface(tester);
    // Bus 2 has arrived and retired its one-way riders. Bus 1 has not even
    // departed — its chooser must still open on GO.
    final c = controllerWith(
      buses: [_bus(_busId), _bus(_otherBusId)],
      passengers: [
        _roundTripRider(),
        _returnOnlyRider(),
        _retiredRiderOnAnotherBus(),
      ],
    );
    await mount(tester, c);

    expect(
      await openChooser(tester),
      CollectLeg.go,
      reason: 'bus 2 arriving says nothing about bus 1, which is still '
          'boarding — the old tour-wide journeyDone quantifier flipped it',
    );
  });

  testWidgets('this bus arriving DOES move its chooser to the return leg',
      (tester) async {
    useLargeSurface(tester);
    // Nobody is journeyDone anywhere: the milestone alone must carry it. This
    // is the half the old predicate could not answer — a bus of round-trip
    // riders has no outbound-only seats to release, so nothing is ever flagged.
    final c = controllerWith(
      buses: [_bus(_busId)],
      passengers: [_roundTripRider(), _returnOnlyRider()],
      goArrived: true,
    );
    await mount(tester, c);

    expect(
      await openChooser(tester),
      CollectLeg.ret,
      reason: 'the bus has arrived, so the riders still aboard are the return '
          'ones',
    );
  });

  testWidgets('a bus that has not departed opens on the GO leg', (tester) async {
    useLargeSurface(tester);
    final c = controllerWith(
      buses: [_bus(_busId)],
      passengers: [_roundTripRider(), _returnOnlyRider()],
    );
    await mount(tester, c);

    expect(await openChooser(tester), CollectLeg.go);
  });
}
