// ignore: implementation_imports
import 'package:easy_localization/src/localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:occubusbooking/controllers/tour_controller.dart';
import 'package:occubusbooking/models/bus_details.dart';
import 'package:occubusbooking/models/bus_type.dart';
import 'package:occubusbooking/models/passenger.dart';
import 'package:occubusbooking/models/passenger_group.dart';
import 'package:occubusbooking/models/priority_status.dart';
import 'package:occubusbooking/models/request_line.dart';
import 'package:occubusbooking/models/seat_layout.dart';
import 'package:occubusbooking/models/seat_type.dart';
import 'package:occubusbooking/models/tour.dart';
import 'package:occubusbooking/models/trip_type.dart';
import 'package:occubusbooking/screens/requests_screen.dart';

/// Skip the real network load + realtime wiring.
class _FakeTourController extends TourController {
  @override
  // ignore: must_call_super
  void onInit() {}
}

Bus _bus(String id, {int seats = 30}) => Bus(
      id: id,
      name: id,
      busType: 'Sleeper',
      layout: BusLayout.generate(busType: BusType.sleeper, totalSeats: seats),
    );

/// A NEW-tab passenger. Defaults to a single seater line so it has real berths
/// (seatBerths > 0) and lands on the New tab — an empty requestLines list makes
/// isFullyAssigned true (0 >= 0), pushing it onto the Assigned tab instead.
/// plural() is made test-safe by initialising the locale in setUpAll below.
Passenger _newPassenger(
  String id, {
  String name = 'Anjali QA',
  String phone = '+919000000005',
  List<RequestLine>? lines,
  String? note,
  String? groupId,
  String? pickupLocationName,
  PriorityStatus priority = PriorityStatus.none,
  TripType tripType = TripType.roundTrip,
}) =>
    Passenger(
      id: id,
      tourId: 't1',
      name: name,
      phone: phone,
      requestLines: lines ?? [RequestLine(seatType: SeatType.seater, qty: 1)],
      note: note,
      groupId: groupId,
      pickupLocationName: pickupLocationName,
      priorityStatus: priority,
      tripType: tripType,
    );

Tour _tour({
  required List<Passenger> passengers,
  List<PassengerGroup> groups = const [],
}) =>
    Tour(
      id: 't1',
      title: 'Dwarka Yatra',
      fromCity: 'Surat',
      toCity: 'Dwarka',
      departureDate: DateTime(2026, 7, 1),
      pricePerSeat: 1200,
      buses: [_bus('b1')],
      passengers: passengers,
      groups: groups,
    );

Widget _harness() => const GetMaterialApp(
      home: RequestsScreen(),
    );

Future<void> _pumpScreen(WidgetTester tester, Tour tour) async {
  final ctrl = _FakeTourController();
  Get.put<TourController>(ctrl);
  ctrl.tours.assignAll([tour]);
  await tester.binding.setSurfaceSize(const Size(1200, 2600));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(_harness());
  await tester.pump();
}

void main() {
  // Initialise the global easy_localization locale so plural() (used by the
  // expanded seat chips) doesn't throw LateInitializationError on _locale.
  // Translations stay null, so tr()/plural() still return raw keys as the
  // other screen tests expect. ignorePluralRules avoids the CLDR tables.
  setUpAll(() {
    Localization.load(const Locale('en'), ignorePluralRules: true);
  });

  tearDown(Get.reset);

  testWidgets('collapsed row shows name + seat summary, hides actions',
      (tester) async {
    await _pumpScreen(
      tester,
      _tour(passengers: [
        _newPassenger('p1',
            name: 'Anjali QA',
            lines: [RequestLine(seatType: SeatType.seater, qty: 2)]),
      ]),
    );

    // Name is visible collapsed.
    expect(find.text('Anjali QA'), findsOneWidget);
    // Seat summary is plural-free "2 · <type>" — assert on the count prefix.
    expect(find.textContaining('2 ·'), findsOneWidget);
    // Collapsed → the per-card primary action is NOT built yet.
    expect(find.text('requests.action.confirm'), findsNothing);
  });

  testWidgets('tapping a row expands it to reveal note + primary action',
      (tester) async {
    await _pumpScreen(
      tester,
      _tour(passengers: [
        _newPassenger('p1', name: 'Anjali QA', note: 'qa-note-xyz'),
      ]),
    );

    expect(find.text('requests.action.confirm'), findsNothing);
    expect(find.textContaining('qa-note-xyz'), findsNothing);

    await tester.tap(find.text('Anjali QA'));
    await tester.pumpAndSettle();

    // Expanded → note box + New-state primary action are now in the tree.
    expect(find.textContaining('qa-note-xyz'), findsOneWidget);
    expect(find.text('requests.action.confirm'), findsOneWidget);
  });

  testWidgets('only one row is expanded at a time', (tester) async {
    await _pumpScreen(
      tester,
      _tour(passengers: [
        _newPassenger('p1', name: 'Anjali QA', note: 'note-A'),
        _newPassenger('p2', name: 'Mahesh QA', note: 'note-B'),
      ]),
    );

    await tester.tap(find.text('Anjali QA'));
    await tester.pumpAndSettle();
    expect(find.textContaining('note-A'), findsOneWidget);

    await tester.tap(find.text('Mahesh QA'));
    await tester.pumpAndSettle();
    // Opening the second collapses the first.
    expect(find.textContaining('note-B'), findsOneWidget);
    expect(find.textContaining('note-A'), findsNothing);
  });

  testWidgets('collapsed row renders Material-icon indicators for flags',
      (tester) async {
    await _pumpScreen(
      tester,
      _tour(
        passengers: [
          _newPassenger('p1',
              name: 'Anjali QA',
              note: 'has-note',
              groupId: 'g1',
              pickupLocationName: 'Raj Hotel',
              priority: PriorityStatus.approved,
              tripType: TripType.outboundOnly),
        ],
        groups: [
          PassengerGroup(id: 'g1', tourId: 't1', label: 'A', colorIndex: 2),
        ],
      ),
    );

    // Scope to THIS request row (the card wrapping the name) so the assertions
    // don't collide with the same icon elsewhere on the screen (e.g. the
    // capacity meter also renders a forward arrow).
    final row = find
        .ancestor(
          of: find.text('Anjali QA'),
          matching: find.byType(AnimatedContainer),
        )
        .first;
    Finder iconInRow(IconData icon) =>
        find.descendant(of: row, matching: find.byIcon(icon));

    // Collapsed → indicator icons present, expanded content still absent.
    expect(iconInRow(Icons.star_rounded), findsOneWidget); // priority
    expect(iconInRow(Icons.place_outlined), findsOneWidget); // pickup
    expect(iconInRow(Icons.chat_bubble_outline_rounded), findsOneWidget); // note
    expect(iconInRow(Icons.arrow_forward_rounded),
        findsOneWidget); // outbound one-way
    // Not yet expanded → the action row is not built.
    expect(find.text('requests.action.confirm'), findsNothing);
  });

  testWidgets('rows are swipeable normally, not in selection mode',
      (tester) async {
    await _pumpScreen(
      tester,
      _tour(passengers: [
        _newPassenger('p1', name: 'Anjali QA'),
        _newPassenger('p2', name: 'Mahesh QA'),
      ]),
    );

    // Each visible request row is wrapped in a swipe action (Dismissible).
    expect(find.byType(Dismissible), findsNWidgets(2));

    // Long-press enters bulk selection → swipe wrappers are removed.
    await tester.longPress(find.text('Anjali QA'));
    await tester.pumpAndSettle();
    expect(find.byType(Dismissible), findsNothing);
  });
}
