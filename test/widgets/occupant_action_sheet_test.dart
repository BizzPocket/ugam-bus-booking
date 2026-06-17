import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:occubusbooking/controllers/tour_controller.dart';
import 'package:occubusbooking/models/bus_details.dart';
import 'package:occubusbooking/models/bus_type.dart';
import 'package:occubusbooking/models/passenger.dart';
import 'package:occubusbooking/models/seat_assignment.dart';
import 'package:occubusbooking/models/seat_layout.dart';
import 'package:occubusbooking/models/tour.dart';
import 'package:occubusbooking/models/trip_type.dart';
import 'package:occubusbooking/widgets/occupant_action_sheet.dart';

/// Regression for the motivating bug: tapping a SHARED Double Sofa on the
/// READ-ONLY path (Charts/Handler) must surface BOTH occupants, not just the
/// first — and must offer NO mutating actions.
///
/// Localization is not initialised under `flutter test`, so `tr(...)` returns
/// the raw key. We assert on the un-localized action keys (which are stable)
/// and on the occupant DISPLAY NAMES (never localized), so a leg-shared sofa's
/// two names both render via the sheet's person toggle.
class _FakeTourController extends TourController {
  @override
  // ignore: must_call_super
  void onInit() {}
}

Bus _bus(String id, String name) => Bus(
      id: id,
      name: name,
      busType: 'Sleeper',
      layout: BusLayout.generate(busType: BusType.sleeper, totalSeats: 10),
    );

Passenger _p(String id, String name, TripType trip, String seatId) => Passenger(
      id: id,
      tourId: 't1',
      name: name,
      phone: '+910000000000',
      tripType: trip,
      assignedSeats: [SeatAssignment(busId: 'b1', seatId: seatId)],
    );

/// Pumps the sheet directly (no bottom-sheet host) so we can read its tree.
Widget _host(Widget sheet) => GetMaterialApp(
      theme: ThemeData(brightness: Brightness.dark),
      home: Scaffold(
        body: SingleChildScrollView(child: sheet),
      ),
    );

void main() {
  tearDown(Get.reset);

  testWidgets(
    'READ-ONLY shared Double Sofa surfaces BOTH occupants (the bug fix)',
    (tester) async {
      final ctrl = _FakeTourController();
      Get.put<TourController>(ctrl);

      // A leg-shared double: a GO-only rider and a different RET-only rider
      // sharing seat DS1 on disjoint legs — exactly the case that the old
      // `occupants.first` callback collapsed to one name.
      final go = _p('go', 'Asha', TripType.outboundOnly, 'DS1');
      final ret = _p('ret', 'Bina', TripType.returnOnly, 'DS1');

      ctrl.tours.assignAll([
        Tour(
          id: 't1',
          title: 'test',
          fromCity: 'A',
          toCity: 'B',
          departureDate: DateTime(2026, 7, 1),
          pricePerSeat: 1,
          buses: [_bus('b1', 'Bus 1')],
          passengers: [go, ret],
        ),
      ]);

      await tester.pumpWidget(
        _host(
          OccupantActionSheet(
            occupants: [go, ret],
            tourId: 't1',
            busId: 'b1',
            seatId: 'DS1',
            busName: 'Bus 1',
            mode: OccupantSheetMode.readOnly,
          ),
        ),
      );
      await tester.pump();

      // BOTH occupants render: the person toggle shows each name as a pill,
      // and the active occupant's name shows in the header. The first name is
      // present at minimum; the second name proves the list was NOT truncated
      // to `.first`.
      expect(find.text('Asha'), findsWidgets);
      expect(find.text('Bina'), findsWidgets);

      // READ-ONLY: the call row IS offered, but NO mutating actions are.
      expect(find.text('occupant_sheet.call'), findsOneWidget);
      expect(find.text('occupant_sheet.move_or_swap'), findsNothing);
      expect(find.text('occupant_sheet.edit_request'), findsNothing);
      expect(find.text('occupant_sheet.free'), findsNothing);
      expect(find.text('occupant.make_priority'), findsNothing);
      expect(find.text('occupant.make_handler'), findsNothing);

      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'ACTION mode (default) keeps every mutating action for one occupant',
    (tester) async {
      final ctrl = _FakeTourController();
      Get.put<TourController>(ctrl);

      final rt = _p('rt', 'Chetan', TripType.roundTrip, 'S2');
      ctrl.tours.assignAll([
        Tour(
          id: 't1',
          title: 'test',
          fromCity: 'A',
          toCity: 'B',
          departureDate: DateTime(2026, 7, 1),
          pricePerSeat: 1,
          buses: [_bus('b1', 'Bus 1')],
          passengers: [rt],
        ),
      ]);

      await tester.pumpWidget(
        _host(
          OccupantActionSheet(
            occupants: [rt],
            tourId: 't1',
            busId: 'b1',
            seatId: 'S2',
            busName: 'Bus 1',
            // mode defaults to action — assert the full agent sheet renders.
          ),
        ),
      );
      await tester.pump();

      expect(find.text('Chetan'), findsWidgets);
      expect(find.text('occupant_sheet.call'), findsOneWidget);
      expect(find.text('occupant_sheet.move_or_swap'), findsOneWidget);
      expect(find.text('occupant_sheet.edit_request'), findsOneWidget);
      expect(find.text('occupant_sheet.free'), findsOneWidget);
      expect(find.text('occupant.make_priority'), findsOneWidget);
      expect(find.text('occupant.make_handler'), findsOneWidget);

      expect(tester.takeException(), isNull);
    },
  );
}
