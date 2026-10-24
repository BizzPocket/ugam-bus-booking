import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:occubusbooking/controllers/tour_controller.dart';
import 'package:occubusbooking/models/tour.dart';
import 'package:occubusbooking/screens/board/board_screen.dart';
import 'package:occubusbooking/models/tour_status.dart';
import 'package:occubusbooking/screens/manage_buses_screen.dart';
import 'package:occubusbooking/screens/seating_exceptions_screen.dart';
import 'package:occubusbooking/screens/tour_seat_assignment_screen.dart';
import 'package:occubusbooking/services/sync_service.dart';

/// The agent opens an ARCHIVED tour on a bus with one bar of 2G. Its roster was
/// never fetched at cold start, so it arrives with no buses. These screens used
/// to answer "No buses · Add bus" while the read was in flight AND after it
/// failed — and the agent, believing it, added a second copy of a bus the tour
/// already had.
class _FakeSync extends SyncService {
  _FakeSync({this.failRelations = 0});

  int failRelations;
  int relationCalls = 0;
  Completer<void>? gate;

  /// Buses the server returns once the roster read succeeds.
  List<Map<String, dynamic>> buses = const [];

  @override
  // ignore: must_call_super
  void onInit() {}

  @override
  Future<
      ({
        List<Map<String, dynamic>> passengers,
        List<Map<String, dynamic>> buses,
        List<Map<String, dynamic>> groups,
      })> fetchRelationsForTours(List<String> tourIds) async {
    relationCalls++;
    if (gate != null) await gate!.future;
    if (failRelations > 0) {
      failRelations--;
      throw TimeoutException('2G read timed out');
    }
    return (
      passengers: <Map<String, dynamic>>[],
      buses: buses,
      groups: <Map<String, dynamic>>[],
    );
  }

  @override
  Future<List<Map<String, dynamic>>> fetchBusLayouts(List<String> busIds) async =>
      [for (final id in busIds) {'id': id, 'layout': null}];
}

class _FakeTourController extends TourController {
  @override
  // ignore: must_call_super
  void onInit() {}

  // A landed roster schedules a debounced disk save; there is no disk here.
  @override
  Future<void> saveToDiskCache() async {}
}

/// Lets the landed roster's debounced disk save fire, so no timer outlives the
/// test.
Future<void> _drainDiskSave(WidgetTester tester) =>
    tester.pump(const Duration(seconds: 2));

Tour _archived() => Tour(
      id: 't1',
      title: 'Ambaji Yatra',
      fromCity: 'Ahmedabad',
      toCity: 'Ambaji',
      departureDate: DateTime(2026, 8, 10),
      status: TourStatus.completed,
      pricePerSeat: 1500,
    );

({_FakeSync sync, TourController ctrl}) _setUp({int failRelations = 0}) {
  final sync = _FakeSync(failRelations: failRelations);
  Get.put<SyncService>(sync);
  final ctrl = _FakeTourController();
  Get.put<TourController>(ctrl);
  ctrl.tours.assignAll([_archived()]);
  return (sync: sync, ctrl: ctrl);
}

void main() {
  tearDown(Get.reset);

  group('Manage buses', () {
    testWidgets('a FAILED roster read shows Retry, never "No buses · Add bus"',
        (tester) async {
      final env = _setUp(failRelations: 1);

      await tester.pumpWidget(
        const GetMaterialApp(home: ManageBusesScreen(tourId: 't1')),
      );
      await tester.pumpAndSettle();

      expect(find.text('actions.retry'), findsOneWidget);
      expect(find.text('manage_buses.empty_title'), findsNothing);
      expect(find.text('manage_buses.add_bus'), findsNothing);

      // Retry re-reads, and an answered-empty tour may now offer "Add bus".
      await tester.tap(find.text('actions.retry'));
      await tester.pumpAndSettle();
      expect(env.sync.relationCalls, 2);
      expect(find.text('manage_buses.empty_title'), findsOneWidget);
      await _drainDiskSave(tester);
    });

    testWidgets('while the roster is in flight it is a skeleton, not empty',
        (tester) async {
      final env = _setUp();
      env.sync.gate = Completer<void>();

      await tester.pumpWidget(
        const GetMaterialApp(home: ManageBusesScreen(tourId: 't1')),
      );
      await tester.pump();
      await tester.pump();

      expect(find.text('manage_buses.empty_title'), findsNothing);
      expect(find.text('manage_buses.add_bus'), findsNothing);
      expect(find.text('actions.retry'), findsNothing);

      env.sync.gate!.complete();
      await tester.pumpAndSettle();
      expect(find.text('manage_buses.empty_title'), findsOneWidget);
      await _drainDiskSave(tester);
    });

    testWidgets('a failed read is NOT re-sent on every rebuild', (tester) async {
      final env = _setUp(failRelations: 5);

      await tester.pumpWidget(
        const GetMaterialApp(home: ManageBusesScreen(tourId: 't1')),
      );
      await tester.pumpAndSettle();
      expect(env.sync.relationCalls, 1);

      // Unrelated realtime churn rebuilds the screen several times. The hydrate
      // used to be fired from build(), so each rebuild sent another roster
      // request down the same 2G radio.
      for (var i = 0; i < 4; i++) {
        env.ctrl.tours.refresh();
        await tester.pumpAndSettle();
      }
      expect(env.sync.relationCalls, 1);
      expect(find.text('actions.retry'), findsOneWidget);
    });
  });

  testWidgets('Seat assignment: a failed roster read shows Retry, not "No buses"',
      (tester) async {
    _setUp(failRelations: 1);

    await tester.pumpWidget(
      const GetMaterialApp(home: TourSeatAssignmentScreen(tourId: 't1')),
    );
    await tester.pumpAndSettle();

    expect(find.text('actions.retry'), findsOneWidget);
    expect(find.text('tour_seat_assignment.no_buses_title'), findsNothing);
  });

  testWidgets('Seating decisions: a failed roster read is not "All clear"',
      (tester) async {
    _setUp(failRelations: 1);

    await tester.pumpWidget(
      const GetMaterialApp(home: SeatingExceptionsScreen(tourId: 't1')),
    );
    await tester.pumpAndSettle();

    expect(find.text('actions.retry'), findsOneWidget);
    expect(find.text('seating_exceptions.all_clear_title'), findsNothing);
  });

  testWidgets('Board: a failed roster read is Retry, not "no bus · Add bus"',
      (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final env = _setUp(failRelations: 1);

    await tester.pumpWidget(
      const MaterialApp(home: BoardScreen(tourId: 't1')),
    );
    await tester.pumpAndSettle();

    expect(find.text('actions.retry'), findsOneWidget);
    expect(find.text('board_screen.no_bus_title'), findsNothing);
    expect(find.text('add_bus.title'), findsNothing);

    await tester.tap(find.text('actions.retry'));
    await tester.pumpAndSettle();
    expect(env.sync.relationCalls, 2);
    expect(find.text('board_screen.no_bus_title'), findsOneWidget);
    await _drainDiskSave(tester);
  });
}
