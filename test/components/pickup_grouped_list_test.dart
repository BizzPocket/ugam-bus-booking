import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/components/pickup_grouped_list.dart';
import 'package:occubusbooking/design/tokens.dart';
import 'package:occubusbooking/utils/pickup_grouping.dart';

/// A minimal roster row: a person's name and the pickup snapshot it belongs to.
typedef _Rider = ({String name, String? pickupName});

const _noPickup = 'NO_PICKUP';

List<PickupGroup<_Rider>> _groups(List<_Rider> riders) => groupByPickup<_Rider>(
  riders,
  idOf: (r) => r.pickupName, // id doubles as the colour key in this fixture
  nameOf: (r) => r.pickupName,
);

Future<void> _pump(
  WidgetTester tester,
  List<_Rider> riders, {
  Brightness brightness = Brightness.dark,
}) {
  return tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(brightness: brightness),
      home: Scaffold(
        body: SingleChildScrollView(
          child: PickupGroupedList<_Rider>(
            groups: _groups(riders),
            unassignedLabel: _noPickup,
            c: brightness == Brightness.dark
                ? UgamColors.dark
                : UgamColors.light,
            rowBuilder: (r) => Text(r.name),
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('renders a header per named pickup plus every row', (
    tester,
  ) async {
    await _pump(tester, const [
      (name: 'Anish', pickupName: 'Temple'),
      (name: 'Bhavna', pickupName: 'Airport'),
      (name: 'Chetan', pickupName: null),
    ]);
    expect(tester.takeException(), isNull);

    // Every rider row rendered via the rowBuilder.
    for (final n in ['Anish', 'Bhavna', 'Chetan']) {
      expect(find.text(n), findsOneWidget);
    }
    // A header per named location + the no-pickup bucket header.
    expect(find.text('Temple'), findsOneWidget);
    expect(find.text('Airport'), findsOneWidget);
    expect(find.text(_noPickup), findsOneWidget);
  });

  testWidgets('shows a head-count on each pickup header', (tester) async {
    await _pump(tester, const [
      (name: 'Anish', pickupName: 'Temple'),
      (name: 'Dev', pickupName: 'Temple'),
      (name: 'Bhavna', pickupName: 'Airport'),
    ]);
    // Temple has 2, Airport has 1.
    expect(find.text('· 2'), findsOneWidget);
    expect(find.text('· 1'), findsOneWidget);
  });

  testWidgets('orders named pickups A→Z with the no-pickup bucket last', (
    tester,
  ) async {
    await _pump(tester, const [
      (name: 'Anish', pickupName: 'Temple'),
      (name: 'Chetan', pickupName: null),
      (name: 'Bhavna', pickupName: 'Airport'),
    ]);
    final airportY = tester.getTopLeft(find.text('Airport')).dy;
    final templeY = tester.getTopLeft(find.text('Temple')).dy;
    final noneY = tester.getTopLeft(find.text(_noPickup)).dy;
    expect(airportY, lessThan(templeY)); // Airport before Temple
    expect(templeY, lessThan(noneY)); // no-pickup bucket last
  });

  testWidgets(
    'falls back to a flat list (no headers) when no pickup is tagged',
    (tester) async {
      await _pump(tester, const [
        (name: 'Anish', pickupName: null),
        (name: 'Bhavna', pickupName: ''),
      ]);
      expect(tester.takeException(), isNull);
      // Rows still render...
      expect(find.text('Anish'), findsOneWidget);
      expect(find.text('Bhavna'), findsOneWidget);
      // ...but there is no header at all — neither a label nor a head-count.
      expect(find.text(_noPickup), findsNothing);
      expect(find.textContaining('·'), findsNothing);
    },
  );

  testWidgets('renders without error on the light theme too', (tester) async {
    await _pump(tester, const [
      (name: 'Anish', pickupName: 'Temple'),
    ], brightness: Brightness.light);
    expect(tester.takeException(), isNull);
    expect(find.text('Temple'), findsOneWidget);
  });
}
