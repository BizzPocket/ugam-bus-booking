import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/passenger.dart';
import 'package:occubusbooking/models/seat_assignment.dart';
import 'package:occubusbooking/models/seat_layout.dart';
import 'package:occubusbooking/models/seat_type.dart';
import 'package:occubusbooking/models/tour.dart';
import 'package:occubusbooking/utils/seat_grid_placement.dart';

// ── Fixture helpers ─────────────────────────────────────────────────────────
//
// Tiny hand-rolled layouts so we control which lane / row each seat is on and
// can assert exact column ordering. Mirrors the builder style in
// test/services/seating_engine_test.dart.

SeatCell _seat(
  int row,
  int col,
  SeatType type,
  SeatPosition? pos,
  String id,
) =>
    SeatCell(row: row, col: col, seatType: type, position: pos, seatId: id);

BusLayout _layout(List<SeatCell> cells, {bool hasBalcony = false}) {
  var maxRow = 0;
  for (final c in cells) {
    if (c.row > maxRow) maxRow = c.row;
  }
  return BusLayout(
    rows: maxRow + 1,
    cols: SeatGridCols.count,
    grid: cells,
    hasBalcony: hasBalcony,
  );
}

Passenger _p(
  String id, {
  String name = '',
  String phone = '+910000000000',
  List<SeatAssignment> assigned = const [],
}) =>
    Passenger(
      id: id,
      tourId: 't1',
      name: name.isEmpty ? id : name,
      phone: phone,
      assignedSeats: assigned,
    );

Tour _tour(List<Passenger> passengers) => Tour(
      title: 'Trip',
      fromCity: 'A',
      toCity: 'B',
      departureDate: DateTime(2026, 5, 17),
      pricePerSeat: 0,
      passengers: passengers,
    );

void main() {
  group('SeatGridPlacement.rowsWithSeats', () {
    test('returns only rows carrying a seat, in order', () {
      // Seats on rows 0 and 2; row 1 is empty. rows is 3.
      final layout = _layout([
        _seat(0, SeatGridCols.singleUpper, SeatType.singleSofa,
            SeatPosition.upper, 'SU1'),
        _seat(2, SeatGridCols.singleLower, SeatType.singleSofa,
            SeatPosition.lower, 'SL1'),
      ]);
      expect(SeatGridPlacement.rowsWithSeats(layout), [0, 2]);
    });
  });

  group('SeatGridPlacement.usedLaneCols', () {
    test('reports lane cols with seats and excludes the aisle', () {
      final layout = _layout([
        _seat(0, SeatGridCols.singleUpper, SeatType.singleSofa,
            SeatPosition.upper, 'SU1'),
        _seat(0, SeatGridCols.doubleLower, SeatType.doubleSofa,
            SeatPosition.lower, 'DL1'),
        // A balcony seat sits in the aisle column but must never appear here.
        _seat(1, SeatGridCols.aisle, SeatType.singleSofa, SeatPosition.lower,
            'SLb'),
      ]);
      final used = SeatGridPlacement.usedLaneCols(layout);
      expect(used.contains(SeatGridCols.aisle), isFalse);
      expect(used, {SeatGridCols.singleUpper, SeatGridCols.doubleLower});
    });
  });

  group('SeatGridPlacement.columns', () {
    test('single-only layout: no aisle inserted', () {
      final layout = _layout([
        _seat(0, SeatGridCols.singleUpper, SeatType.singleSofa,
            SeatPosition.upper, 'SU1'),
        _seat(0, SeatGridCols.singleLower, SeatType.singleSofa,
            SeatPosition.lower, 'SL1'),
      ]);
      expect(SeatGridPlacement.columns(layout),
          [ChartColumn.singleUpper, ChartColumn.singleLower]);
    });

    test('double-only layout: no aisle inserted', () {
      final layout = _layout([
        _seat(0, SeatGridCols.doubleUpper, SeatType.doubleSofa,
            SeatPosition.upper, 'DU1'),
        _seat(0, SeatGridCols.doubleLower, SeatType.doubleSofa,
            SeatPosition.lower, 'DL1'),
      ]);
      expect(SeatGridPlacement.columns(layout),
          [ChartColumn.doubleUpper, ChartColumn.doubleLower]);
    });

    test('both sides present: aisle inserted between single and double', () {
      final layout = _layout([
        _seat(0, SeatGridCols.singleUpper, SeatType.singleSofa,
            SeatPosition.upper, 'SU1'),
        _seat(0, SeatGridCols.singleLower, SeatType.singleSofa,
            SeatPosition.lower, 'SL1'),
        _seat(0, SeatGridCols.doubleUpper, SeatType.doubleSofa,
            SeatPosition.upper, 'DU1'),
        _seat(0, SeatGridCols.doubleLower, SeatType.doubleSofa,
            SeatPosition.lower, 'DL1'),
      ]);
      expect(SeatGridPlacement.columns(layout), [
        ChartColumn.singleUpper,
        ChartColumn.singleLower,
        ChartColumn.aisle,
        ChartColumn.doubleUpper,
        ChartColumn.doubleLower,
      ]);
    });

    test('balcony forces the aisle even when only one side has seats', () {
      // Only single lanes carry seats, but hasBalcony => aisle still appears.
      final layout = _layout(
        [
          _seat(0, SeatGridCols.singleUpper, SeatType.singleSofa,
              SeatPosition.upper, 'SU1'),
          _seat(0, SeatGridCols.singleLower, SeatType.singleSofa,
              SeatPosition.lower, 'SL1'),
          _seat(1, SeatGridCols.aisle, SeatType.singleSofa,
              SeatPosition.lower, 'SLb'),
        ],
        hasBalcony: true,
      );
      expect(SeatGridPlacement.columns(layout), [
        ChartColumn.singleUpper,
        ChartColumn.singleLower,
        ChartColumn.aisle,
      ]);
    });
  });

  group('SeatGridPlacement.cellFor', () {
    test('maps each lane column to its cell and aisle to null', () {
      final layout = _layout([
        _seat(0, SeatGridCols.singleUpper, SeatType.singleSofa,
            SeatPosition.upper, 'SU1'),
        _seat(0, SeatGridCols.singleLower, SeatType.singleSofa,
            SeatPosition.lower, 'SL1'),
        _seat(0, SeatGridCols.doubleUpper, SeatType.doubleSofa,
            SeatPosition.upper, 'DU1'),
        _seat(0, SeatGridCols.doubleLower, SeatType.doubleSofa,
            SeatPosition.lower, 'DL1'),
      ]);
      expect(SeatGridPlacement.cellFor(layout, 0, ChartColumn.singleUpper)?.seatId,
          'SU1');
      expect(SeatGridPlacement.cellFor(layout, 0, ChartColumn.singleLower)?.seatId,
          'SL1');
      expect(SeatGridPlacement.cellFor(layout, 0, ChartColumn.doubleUpper)?.seatId,
          'DU1');
      expect(SeatGridPlacement.cellFor(layout, 0, ChartColumn.doubleLower)?.seatId,
          'DL1');
      expect(SeatGridPlacement.cellFor(layout, 0, ChartColumn.aisle), isNull);
    });
  });

  group('occupantsByBus', () {
    test('maps every assigned seatId to its passenger occupant', () {
      final p1 = _p('p1', name: 'Praful', phone: '+919879600000', assigned: [
        const SeatAssignment(busId: 'b1', seatId: 'SU1'),
      ]);
      final p2 = _p('p2', name: 'Vanita', phone: '7984500000', assigned: [
        const SeatAssignment(busId: 'b1', seatId: 'SL1'),
      ]);
      final byBus = occupantsByBus(_tour([p1, p2]));

      expect(byBus['b1']!['SU1']!.name, 'Praful');
      expect(byBus['b1']!['SU1']!.phone, '9879600000');
      expect(byBus['b1']!['SL1']!.name, 'Vanita');
      expect(byBus['b1']!['SL1']!.phone, '7984500000');
    });

    test('a whole double-sofa owner appears on BOTH berth assignments', () {
      // The agent records two SeatAssignment entries with the SAME seatId for a
      // whole double; both must resolve to the one owner.
      final p = _p('p1', name: 'Rasik', assigned: const [
        SeatAssignment(busId: 'b1', seatId: 'DL1'),
        SeatAssignment(busId: 'b1', seatId: 'DL1'),
      ]);
      final byBus = occupantsByBus(_tour([p]));
      expect(byBus['b1']!['DL1']!.name, 'Rasik');
    });

    test('separates occupants per bus', () {
      final p = _p('p1', name: 'Manoj', assigned: const [
        SeatAssignment(busId: 'b1', seatId: 'SU1'),
        SeatAssignment(busId: 'b2', seatId: 'DL2'),
      ]);
      final byBus = occupantsByBus(_tour([p]));
      expect(byBus['b1']!.containsKey('SU1'), isTrue);
      expect(byBus['b1']!.containsKey('DL2'), isFalse);
      expect(byBus['b2']!.containsKey('DL2'), isTrue);
    });
  });

  group('displayPhone', () {
    test('strips a 91 country prefix to the last 10 digits', () {
      expect(displayPhone('+919879654321'), '9879654321');
      expect(displayPhone('919879654321'), '9879654321');
    });

    test('passes a plain 10-digit number through unchanged', () {
      expect(displayPhone('9879654321'), '9879654321');
    });

    test('strips formatting characters but keeps a non-91 number', () {
      expect(displayPhone('98-79 65 43 21'), '9879654321');
    });

    test('junk with no digits returns null', () {
      expect(displayPhone('abc'), isNull);
    });

    test('empty / null returns null', () {
      expect(displayPhone(''), isNull);
      expect(displayPhone(null), isNull);
    });
  });
}
