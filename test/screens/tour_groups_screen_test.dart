import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:occubusbooking/controllers/tour_controller.dart';
import 'package:occubusbooking/models/passenger.dart';
import 'package:occubusbooking/models/passenger_group.dart';
import 'package:occubusbooking/models/priority_status.dart';
import 'package:occubusbooking/models/request_line.dart';
import 'package:occubusbooking/models/seat_type.dart';
import 'package:occubusbooking/models/tour.dart';
import 'package:occubusbooking/screens/tour_groups_screen.dart';

/// Test double for [TourController] mirroring the slice-1/2/3a idiom:
/// [onInit] is a no-op so registering it does NOT start the real
/// `_loadTours` + realtime subscription, and the group/priority writes
/// are stubbed to RECORD their arguments (and mutate local `tours` so the
/// reactive Obx repaints) instead of touching Supabase.
class _FakeTourController extends TourController {
  /// (passengerId, approved) pairs captured from setPassengerPriority.
  final List<({String passengerId, bool approved})> priorityCalls = [];

  /// (passengerId, groupId) pairs captured from setPassengerGroup.
  final List<({String passengerId, String? groupId})> groupCalls = [];

  /// Labels passed to createGroup.
  final List<String> createGroupLabels = [];

  /// Group ids passed to deleteGroup.
  final List<String> deleteGroupIds = [];

  @override
  // ignore: must_call_super
  void onInit() {
    // Intentionally empty: skip the real network load + realtime wiring.
  }

  @override
  Future<void> setPassengerPriority(
      String tourId, String passengerId, bool approved) async {
    priorityCalls.add((passengerId: passengerId, approved: approved));
  }

  @override
  Future<void> setPassengerGroup(
      String tourId, String passengerId, String? groupId) async {
    groupCalls.add((passengerId: passengerId, groupId: groupId));
  }

  @override
  Future<String> createGroup(String tourId, String label,
      {int colorIndex = 0}) async {
    createGroupLabels.add(label);
    return 'g-new';
  }

  @override
  Future<void> deleteGroup(String tourId, String groupId) async {
    deleteGroupIds.add(groupId);
  }
}

Passenger _passenger(
  String id,
  String tourId, {
  bool priority = false,
  String? groupId,
}) =>
    Passenger(
      id: id,
      tourId: tourId,
      name: id,
      phone: '+910000000000',
      groupId: groupId,
      priorityStatus: priority ? PriorityStatus.approved : PriorityStatus.none,
      requestLines: const [
        RequestLine(seatType: SeatType.doubleSofa, qty: 1),
      ],
    );

Tour _fakeTour({List<PassengerGroup> groups = const []}) {
  const tourId = 't1';
  return Tour(
    id: tourId,
    title: 'Dwarka Yatra',
    fromCity: 'Surat',
    toCity: 'Dwarka',
    departureDate: DateTime(2026, 7, 1),
    pricePerSeat: 1200,
    passengers: [
      _passenger('Asha', tourId),
      _passenger('Bharat', tourId, priority: true),
      _passenger('Chandni', tourId),
    ],
    groups: groups,
  );
}

Widget _harness() => GetMaterialApp(
      theme: ThemeData(brightness: Brightness.dark),
      home: const TourGroupsScreen(tourId: 't1'),
    );

void main() {
  tearDown(Get.reset);

  testWidgets('renders the passenger roster', (tester) async {
    final ctrl = _FakeTourController();
    Get.put<TourController>(ctrl);
    ctrl.tours.assignAll([_fakeTour()]);

    await tester.pumpWidget(_harness());
    await tester.pump();

    expect(find.text('Groups & priority'), findsOneWidget);
    expect(find.text('Asha'), findsOneWidget);
    expect(find.text('Bharat'), findsOneWidget);
    expect(find.text('Chandni'), findsOneWidget);
  });

  testWidgets('tapping the priority star invokes setPassengerPriority',
      (tester) async {
    final ctrl = _FakeTourController();
    Get.put<TourController>(ctrl);
    ctrl.tours.assignAll([_fakeTour()]);

    await tester.pumpWidget(_harness());
    await tester.pump();

    expect(ctrl.priorityCalls, isEmpty);

    // Asha is not yet priority → hollow star. Tapping should request approval.
    expect(find.byIcon(Icons.star_rounded), findsOneWidget); // Bharat only
    expect(find.byIcon(Icons.star_outline_rounded), findsNWidgets(2));

    await tester.tap(find.byIcon(Icons.star_outline_rounded).first);
    await tester.pump();

    expect(ctrl.priorityCalls.length, 1);
    expect(ctrl.priorityCalls.single.approved, isTrue);
  });

  testWidgets('tapping a filled star clears priority (approved=false)',
      (tester) async {
    final ctrl = _FakeTourController();
    Get.put<TourController>(ctrl);
    ctrl.tours.assignAll([_fakeTour()]);

    await tester.pumpWidget(_harness());
    await tester.pump();

    // Bharat is the only approved one → his filled star toggles OFF.
    await tester.tap(find.byIcon(Icons.star_rounded));
    await tester.pump();

    expect(ctrl.priorityCalls.single.passengerId, 'Bharat');
    expect(ctrl.priorityCalls.single.approved, isFalse);
  });

  testWidgets('existing groups render with member names + delete', (tester) async {
    final ctrl = _FakeTourController();
    Get.put<TourController>(ctrl);
    final group = PassengerGroup(id: 'g1', tourId: 't1', label: 'Patel family');
    final tour = Tour(
      id: 't1',
      title: 'Dwarka Yatra',
      fromCity: 'Surat',
      toCity: 'Dwarka',
      departureDate: DateTime(2026, 7, 1),
      pricePerSeat: 1200,
      passengers: [
        _passenger('Asha', 't1', groupId: 'g1'),
        _passenger('Bharat', 't1'),
      ],
      groups: [group],
    );
    ctrl.tours.assignAll([tour]);

    await tester.pumpWidget(_harness());
    await tester.pump();

    // Group label appears (in the group card + the member's row chip).
    expect(find.text('Patel family'), findsWidgets);

    // Delete the group.
    await tester.tap(find.byIcon(Icons.delete_outline_rounded));
    await tester.pump();
    expect(ctrl.deleteGroupIds, ['g1']);
  });
}
