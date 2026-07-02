import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/components/combined_seat_grid.dart';
import 'package:occubusbooking/models/bus_type.dart';
import 'package:occubusbooking/models/seat_layout.dart';
import 'package:occubusbooking/models/seat_type.dart';

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

    testWidgets('all-double back row with body singles renders the aisle pair',
        (tester) async {
      final layout = BusLayout.generate(
        busType: BusType.sleeper,
        totalSeats: 30,
        singleSofaCount: 8,
        allDoubleBackRow: true,
      );
      await tester.pumpWidget(_harness(layout));
      expect(tester.takeException(), isNull);

      // Both aisle (balcony) seat IDs should be present on screen.
      final pair = layout.balconyPair(layout.rows - 1);
      expect(find.text(pair.upper.seatId!), findsOneWidget);
      expect(find.text(pair.lower.seatId!), findsOneWidget);
    });

    testWidgets('toggle ON: all-double back row renders the double aisle pair',
        (tester) async {
      final layout = BusLayout.generate(
        busType: BusType.sleeper,
        totalSeats: 36,
        allDoubleBackRow: true,
      );
      final pair = layout.balconyPair(layout.rows - 1);
      expect(pair.upper.seatType, SeatType.doubleSofa);
      expect(pair.lower.seatType, SeatType.doubleSofa);

      await tester.pumpWidget(_harness(layout));
      expect(tester.takeException(), isNull);
      expect(find.text(pair.upper.seatId!), findsOneWidget);
      expect(find.text(pair.lower.seatId!), findsOneWidget);
    });

    testWidgets('toggle OFF: 3 single + 2 double back row renders flat',
        (tester) async {
      // OFF with singles → the back row is 3 single + 2 double sofas;
      // everything must render flat on one bench row with no overflow.
      // 37/13 carves the designed bench cleanly (13 singles odd, 12 doubles even
      // → body 10S+10D stays paired). An odd-double count like 35/13 would
      // instead drop to a hole-free minimal aisle bench, so it is not a 3S+2D
      // case — see the seat_layout sweep for that path.
      final layout = BusLayout.generate(
        busType: BusType.sleeper,
        totalSeats: 37,
        singleSofaCount: 13,
      );
      final benchRow = layout.rows - 1;
      final back = layout.grid.where((c) => c.row == benchRow && c.hasSeat);
      expect(back.where((c) => c.seatType == SeatType.singleSofa).length, 3);
      expect(back.where((c) => c.seatType == SeatType.doubleSofa).length, 2);

      await tester.pumpWidget(_harness(layout));
      expect(tester.takeException(), isNull);
      // Every bench seat id is on screen.
      for (final cell in back) {
        expect(find.text(cell.seatId!), findsOneWidget);
      }
    });
  });
}
