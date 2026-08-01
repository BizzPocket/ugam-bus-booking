import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/components/chart_seat_tile.dart';
import 'package:occubusbooking/models/seat_layout.dart';
import 'package:occubusbooking/models/seat_type.dart';
import 'package:occubusbooking/models/trip_type.dart';
import 'package:occubusbooking/utils/chart_seat_availability.dart';

/// Every tile state, rendered under the constraints CombinedSeatGrid actually
/// supplies.
///
/// THE BUG THIS PREVENTS: the grid wraps each tile in a FittedBox, which hands
/// the child UNBOUNDED constraints. `Expanded` inside a Column under unbounded
/// height is a hard assertion failure, and one failing tile blanks the ENTIRE
/// chart — the customer saw an app bar over an empty body, with no error.
///
/// It only reproduced with real occupancy, because the split tile is the only
/// thing a half-taken double renders. An empty availability map never hit it.
void main() {
  const busId = 'bus-1';

  SeatCell single({bool reserved = false}) => SeatCell(
        row: 0, col: 0, seatType: SeatType.singleSofa,
        position: SeatPosition.upper, seatId: 'SU1', reserved: reserved,
      );
  SeatCell dbl() => const SeatCell(
        row: 0, col: 4, seatType: SeatType.doubleSofa,
        position: SeatPosition.lower, seatId: 'DL1',
      );

  /// Mirrors CombinedSeatGrid: a FittedBox, i.e. unbounded constraints.
  Widget unbounded(Widget child) => MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 44,
              height: 46,
              child: FittedBox(child: child),
            ),
          ),
        ),
      );

  Future<void> expectRenders(WidgetTester tester, Widget tile) async {
    await tester.pumpWidget(unbounded(tile));
    await tester.pumpAndSettle();
    expect(
      tester.takeException(),
      isNull,
      reason: 'a tile that throws under unbounded constraints blanks the '
          'whole chart, not just itself',
    );
  }

  testWidgets('free seat', (t) async {
    await expectRenders(t, ChartSeatTile(
      cell: single(), occupancy: null, leg: TripType.roundTrip,
    ));
  });

  testWidgets('selected seat', (t) async {
    await expectRenders(t, ChartSeatTile(
      cell: single(), occupancy: null, leg: TripType.roundTrip,
      selectedBerths: 1,
    ));
  });

  testWidgets('taken seat', (t) async {
    await expectRenders(t, ChartSeatTile(
      cell: single(), leg: TripType.roundTrip,
      occupancy: const SeatAvailability(
        busId: busId, seatId: 'SU1', usedGo: 1, usedRet: 1,
      ),
    ));
  });

  testWidgets('taken by a lady', (t) async {
    await expectRenders(t, ChartSeatTile(
      cell: single(), leg: TripType.roundTrip,
      occupancy: const SeatAvailability(
        busId: busId, seatId: 'SU1',
        usedGo: 1, usedRet: 1, ladyGo: true, ladyRet: true,
      ),
    ));
  });

  testWidgets('reserved / held back', (t) async {
    await expectRenders(t, ChartSeatTile(
      cell: single(reserved: true), occupancy: null, leg: TripType.roundTrip,
    ));
  });

  testWidgets('THE SPLIT TILE — half a double taken', (t) async {
    await expectRenders(t, ChartSeatTile(
      cell: dbl(), leg: TripType.roundTrip,
      occupancy: const SeatAvailability(
        busId: busId, seatId: 'DL1', usedGo: 1, usedRet: 1,
      ),
    ));
  });

  testWidgets('split tile with a lady on the taken half', (t) async {
    await expectRenders(t, ChartSeatTile(
      cell: dbl(), leg: TripType.roundTrip,
      occupancy: const SeatAvailability(
        busId: busId, seatId: 'DL1',
        usedGo: 1, usedRet: 1, ladyGo: true, ladyRet: true,
      ),
    ));
  });

  testWidgets('split tile with one berth selected', (t) async {
    await expectRenders(t, ChartSeatTile(
      cell: dbl(), leg: TripType.roundTrip, selectedBerths: 1,
      occupancy: const SeatAvailability(busId: busId, seatId: 'DL1'),
    ));
  });

  testWidgets('whole double selected', (t) async {
    await expectRenders(t, ChartSeatTile(
      cell: dbl(), occupancy: null, leg: TripType.roundTrip, selectedBerths: 2,
    ));
  });

  testWidgets('double sold GO-only still renders on the RETURN leg', (t) async {
    // The live seeded case: used_go 2, used_ret 0.
    await expectRenders(t, ChartSeatTile(
      cell: dbl(), leg: TripType.returnOnly,
      occupancy: const SeatAvailability(
        busId: busId, seatId: 'DL1', usedGo: 2, usedRet: 0, ladyGo: true,
      ),
    ));
  });
}
