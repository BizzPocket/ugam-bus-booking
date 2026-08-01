import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/booking_mode.dart';
import 'package:occubusbooking/models/bus_details.dart';
import 'package:occubusbooking/models/seat_layout.dart';
import 'package:occubusbooking/models/seat_type.dart';
import 'package:occubusbooking/models/tour.dart';
import 'package:occubusbooking/models/tour_status.dart';

/// Regression cover for a real bug: the customer "Pick your berth" button was
/// gated on `tour.chartNeedsBus`, which reads `tour.buses`.
///
/// `buses` carries an owner-only RLS policy and has NO anon SELECT — that is
/// precisely why `chart_tour_buses` exists as a SECURITY DEFINER RPC. So on
/// the customer app `tour.buses` is ALWAYS empty, the gate could never pass,
/// and every chart tour showed "seats open soon" forever.
///
/// The rule these tests pin: whether a customer may ENTER the chart must not
/// depend on any organiser-only data.
void main() {
  Tour tour({
    required BookingMode mode,
    List<Bus> buses = const [],
    TourStatus status = TourStatus.busBooked,
  }) =>
      Tour(
        title: 'T',
        fromCity: 'Surat',
        toCity: 'Shirdi',
        departureDate: DateTime(2026, 9, 15),
        pricePerSeat: 900,
        status: status,
        bookingMode: mode,
        buses: buses,
      );

  Bus busWithLayout() => Bus(
        id: 'b1',
        name: 'Bus 1',
        layout: BusLayout(
          rows: 1,
          cols: SeatGridCols.count,
          grid: const [
            SeatCell(
              row: 0,
              col: 0,
              seatType: SeatType.singleSofa,
              position: SeatPosition.upper,
              seatId: 'SU1',
            ),
          ],
        ),
      );

  group('the customer entry condition is bus-independent', () {
    test('a chart tour the customer sees with NO buses is still enterable', () {
      // This is EXACTLY the shape the customer app holds: chart mode, and an
      // empty `buses` list because RLS hid them.
      final t = tour(mode: BookingMode.chart);
      expect(t.buses, isEmpty);

      // What the CTA is allowed to depend on:
      expect(t.bookingMode.isChart, isTrue);
      expect(t.acceptsBookings, isTrue);

      // What it must NOT depend on — true here purely because buses are hidden.
      expect(
        t.chartNeedsBus,
        isTrue,
        reason: 'organiser-only signal; gating the customer CTA on this is the '
            'bug this file exists to prevent',
      );
    });

    test('locking the tour still closes bookings for everyone', () {
      final t = tour(mode: BookingMode.chart, status: TourStatus.locked);
      expect(t.acceptsBookings, isFalse);
    });

    test('a request-mode tour never routes to the chart', () {
      expect(tour(mode: BookingMode.request).bookingMode.isChart, isFalse);
    });
  });

  group('the organiser-side signal still works, where buses ARE loaded', () {
    test('chartNeedsBus warns when the organiser has added no bus', () {
      expect(tour(mode: BookingMode.chart).chartNeedsBus, isTrue);
    });

    test('and clears once a bus with a layout exists', () {
      final t = tour(mode: BookingMode.chart, buses: [busWithLayout()]);
      expect(t.chartNeedsBus, isFalse);
      expect(t.sellsFromChart, isTrue);
      expect(t.chartableBuses, hasLength(1));
    });

    test('a bus with no layout does not count as chartable', () {
      final t = tour(mode: BookingMode.chart, buses: [Bus(id: 'b2', name: 'X')]);
      expect(t.chartableBuses, isEmpty);
      expect(t.sellsFromChart, isFalse);
    });

    test('a request-mode tour never reports needing a bus for the chart', () {
      expect(tour(mode: BookingMode.request).chartNeedsBus, isFalse);
    });
  });
}
