import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/components/combined_seat_grid.dart';
import 'package:occubusbooking/models/bus_type.dart';
import 'package:occubusbooking/models/seat_layout.dart';

Widget _harness(BusLayout layout, {double width = 320}) {
  return MaterialApp(
    theme: ThemeData(brightness: Brightness.dark),
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: width,
          child: SingleChildScrollView(
            child: CombinedSeatGrid(
              layout: layout,
              tileBuilder: (ctx, cell) => CombinedSeatGrid.seatTile(
                ctx,
                label: cell.seatId ?? '',
                background: const Color(0xFF222222),
                border: const Color(0xFF444444),
                foreground: const Color(0xFFFFFFFF),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  group('CombinedSeatGrid renders without overflow at 320px', () {
    testWidgets('all-double sleeper', (tester) async {
      await tester.pumpWidget(
        _harness(BusLayout.generate(busType: BusType.sleeper, totalSeats: 40)),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('2+1 sleeper with singles', (tester) async {
      await tester.pumpWidget(
        _harness(BusLayout.generate(
          busType: BusType.sleeper,
          totalSeats: 30,
          singleSofaCount: 10,
        )),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('seater 2+2', (tester) async {
      await tester.pumpWidget(
        _harness(BusLayout.generate(busType: BusType.seater, totalSeats: 40)),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('sleeper with balcony renders the aisle pair', (tester) async {
      final layout = BusLayout.generate(
        busType: BusType.sleeper,
        totalSeats: 30,
        singleSofaCount: 8,
        hasBalcony: true,
      );
      await tester.pumpWidget(_harness(layout));
      expect(tester.takeException(), isNull);

      // Both balcony seat IDs should be present on screen.
      final pair = layout.balconyPair(layout.rows - 1);
      expect(find.text(pair.upper.seatId!), findsOneWidget);
      expect(find.text(pair.lower.seatId!), findsOneWidget);
    });
  });
}
