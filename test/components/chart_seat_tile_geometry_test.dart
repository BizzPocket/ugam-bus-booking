import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/components/chart_seat_tile.dart';
import 'package:occubusbooking/models/seat_layout.dart';
import 'package:occubusbooking/models/seat_type.dart';
import 'package:occubusbooking/models/trip_type.dart';
import 'package:occubusbooking/utils/chart_seat_availability.dart';

/// Every customer chart tile must occupy the SAME footprint, whatever its state.
///
/// THE BUG THIS PREVENTS — two symptoms, one cause:
///
///   1. `_WholeTile` was a Container sized by its text while `_SplitTile` was
///      hardcoded 34x17 berths. CombinedSeatGrid wraps both in
///      FittedBox(scaleDown), which never scales UP, so each tile rendered at
///      its own natural size: a single (one text line) came out a short pill, a
///      double (seat id + the "2") a taller blob. The grid read as ragged.
///
///   2. Worse, availability POLLS every 20s. A double going free -> half-taken
///      swaps _WholeTile for _SplitTile — a different physical size — so the
///      FittedBox rescaled and the whole row reflowed under the customer's
///      finger. That was the "chart flickers" report.
///
/// Fixing the geometry fixes both. Assert it directly: same size, every state.
void main() {
  const busId = 'bus-1';

  SeatCell single({bool reserved = false}) => SeatCell(
        row: 0,
        col: 0,
        seatType: SeatType.singleSofa,
        position: SeatPosition.upper,
        seatId: 'SU1',
        reserved: reserved,
      );
  SeatCell dbl() => const SeatCell(
        row: 0,
        col: 4,
        seatType: SeatType.doubleSofa,
        position: SeatPosition.lower,
        seatId: 'DL1',
      );
  SeatCell seater() => const SeatCell(
        row: 0,
        col: 1,
        seatType: SeatType.seater,
        seatId: 'ST1',
      );

  /// Measures a tile's INTRINSIC size under unbounded constraints — exactly
  /// what CombinedSeatGrid's `FittedBox` hands it before scaling.
  ///
  /// Measuring inside a bounded box would be dishonest: a Container with an
  /// `alignment` and no explicit size expands to fill whatever it is given, so
  /// every tile would report the parent's size and the test would pass while
  /// the real grid stayed ragged.
  Future<Size> sizeOf(WidgetTester tester, Widget tile) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(child: UnconstrainedBox(child: tile)),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    return tester.getSize(find.byType(ChartSeatTile));
  }

  testWidgets('a single and a double occupy the same footprint', (t) async {
    final singleSize = await sizeOf(
      t,
      ChartSeatTile(
        cell: single(),
        occupancy: null,
        leg: TripType.roundTrip,
      ),
    );
    final doubleSize = await sizeOf(
      t,
      ChartSeatTile(
        cell: dbl(),
        occupancy: null,
        leg: TripType.roundTrip,
      ),
    );

    expect(
      doubleSize,
      singleSize,
      reason: 'a double rendered taller than a single, which is the '
          'SU1-pill vs DL1-blob mismatch on the customer chart',
    );
  });

  testWidgets('a double does not change size when half of it sells', (t) async {
    final free = await sizeOf(
      t,
      ChartSeatTile(
        cell: dbl(),
        occupancy: null,
        leg: TripType.roundTrip,
      ),
    );
    final halfTaken = await sizeOf(
      t,
      ChartSeatTile(
        cell: dbl(),
        leg: TripType.roundTrip,
        occupancy: const SeatAvailability(
          busId: busId,
          seatId: 'DL1',
          usedGo: 1,
          usedRet: 1,
        ),
      ),
    );

    expect(
      halfTaken,
      free,
      reason: 'the 20s availability poll swaps a whole tile for a split tile; '
          'if they differ in size the whole row reflows and the chart flickers',
    );
  });

  testWidgets('every state renders at one identical size', (t) async {
    final states = <String, ChartSeatTile>{
      'free single': ChartSeatTile(
        cell: single(),
        occupancy: null,
        leg: TripType.roundTrip,
      ),
      'selected single': ChartSeatTile(
        cell: single(),
        occupancy: null,
        leg: TripType.roundTrip,
        selectedBerths: 1,
      ),
      'taken single': ChartSeatTile(
        cell: single(),
        leg: TripType.roundTrip,
        occupancy: const SeatAvailability(
          busId: busId,
          seatId: 'SU1',
          usedGo: 1,
          usedRet: 1,
        ),
      ),
      'lady-taken single': ChartSeatTile(
        cell: single(),
        leg: TripType.roundTrip,
        occupancy: const SeatAvailability(
          busId: busId,
          seatId: 'SU1',
          usedGo: 1,
          usedRet: 1,
          ladyGo: true,
          ladyRet: true,
        ),
      ),
      'reserved single': ChartSeatTile(
        cell: single(reserved: true),
        occupancy: null,
        leg: TripType.roundTrip,
      ),
      'seater': ChartSeatTile(
        cell: seater(),
        occupancy: null,
        leg: TripType.roundTrip,
      ),
      'free double': ChartSeatTile(
        cell: dbl(),
        occupancy: null,
        leg: TripType.roundTrip,
      ),
      'half-taken double': ChartSeatTile(
        cell: dbl(),
        leg: TripType.roundTrip,
        occupancy: const SeatAvailability(
          busId: busId,
          seatId: 'DL1',
          usedGo: 1,
          usedRet: 1,
        ),
      ),
      'half-selected double': ChartSeatTile(
        cell: dbl(),
        leg: TripType.roundTrip,
        selectedBerths: 1,
        occupancy: const SeatAvailability(busId: busId, seatId: 'DL1'),
      ),
      'whole double selected': ChartSeatTile(
        cell: dbl(),
        occupancy: null,
        leg: TripType.roundTrip,
        selectedBerths: 2,
      ),
      'double sold GO-only, viewed on RETURN': ChartSeatTile(
        cell: dbl(),
        leg: TripType.returnOnly,
        occupancy: const SeatAvailability(
          busId: busId,
          seatId: 'DL1',
          usedGo: 2,
          usedRet: 0,
          ladyGo: true,
        ),
      ),
    };

    final measured = <String, Size>{};
    for (final entry in states.entries) {
      measured[entry.key] = await sizeOf(t, entry.value);
    }

    final expected = measured['free single'];
    final diverged = Map.fromEntries(
      measured.entries.where((e) => e.value != expected),
    );
    expect(
      diverged,
      isEmpty,
      reason: 'these states did not match the free-single footprint '
          '($expected): $diverged',
    );
  });
}
