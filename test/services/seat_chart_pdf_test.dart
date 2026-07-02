import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/bus_details.dart';
import 'package:occubusbooking/models/chart_footer.dart';
import 'package:occubusbooking/models/passenger.dart';
import 'package:occubusbooking/models/seat_assignment.dart';
import 'package:occubusbooking/models/seat_layout.dart';
import 'package:occubusbooking/models/seat_type.dart';
import 'package:occubusbooking/models/tour.dart';
import 'package:occubusbooking/models/trip_type.dart';
import 'package:occubusbooking/services/seat_chart_pdf.dart';
import 'package:occubusbooking/utils/seat_occupants.dart';

// ── Page counting ───────────────────────────────────────────────────────────
//
// The `pdf` package (used by SeatChartPdf) writes each page's dictionary as a
// plain, uncompressed `/Type /Page` object — object streams (/ObjStm) are not
// used at the default compression level. So counting `/Type /Page` markers in
// the raw bytes gives the page count without needing the platform pdfium
// rasterizer (which is unavailable under `flutter test`). The `\b` word
// boundary excludes the single `/Type /Pages` tree node.
int _pageCount(Uint8List bytes) {
  final text = String.fromCharCodes(bytes);
  return RegExp(r'/Type\s*/Page\b').allMatches(text).length;
}

// ── Fixture helpers ─────────────────────────────────────────────────────────

SeatCell _seat(
  int row,
  int col,
  SeatType type,
  SeatPosition? pos,
  String id,
) =>
    SeatCell(row: row, col: col, seatType: type, position: pos, seatId: id);

/// A two-row bus: a single·upper / single·lower pair, a double·lower berth,
/// and a balcony aisle pair on the back row. Exercises both lanes, the aisle,
/// a whole double, and the balcony-stacking path of the chart builder.
Bus _balconyBus(String id) => Bus(
      id: id,
      name: id == 'b1' ? 'Bus 1' : 'Bus 2',
      busNumber: id == 'b1' ? 'GJ05HU7162' : '',
      busType: 'Sleeper',
      layout: BusLayout(
        rows: 2,
        cols: SeatGridCols.count,
        hasBalcony: true,
        grid: [
          _seat(0, SeatGridCols.singleUpper, SeatType.singleSofa,
              SeatPosition.upper, '${id}_SU1'),
          _seat(0, SeatGridCols.singleLower, SeatType.singleSofa,
              SeatPosition.lower, '${id}_SL1'),
          _seat(0, SeatGridCols.doubleLower, SeatType.doubleSofa,
              SeatPosition.lower, '${id}_DL1'),
          _seat(1, SeatGridCols.aisle, SeatType.singleSofa, SeatPosition.upper,
              '${id}_BU1'),
          _seat(1, SeatGridCols.aisle, SeatType.singleSofa, SeatPosition.lower,
              '${id}_BL1'),
        ],
      ),
    );

Passenger _p(
  String id, {
  required String name,
  String phone = '+919879600000',
  List<SeatAssignment> assigned = const [],
  TripType tripType = TripType.roundTrip,
}) =>
    Passenger(
      id: id,
      tourId: 't1',
      name: name,
      phone: phone,
      assignedSeats: assigned,
      tripType: tripType,
    );

/// A 2-bus tour with a Gujarati passenger name and a whole double-sofa holder.
Tour _twoBusTour() {
  final b1 = _balconyBus('b1');
  final b2 = _balconyBus('b2');
  return Tour(
    title: 'Devam Yatra',
    fromCity: 'Surat',
    toCity: 'Dwarka',
    departureDate: DateTime(2026, 5, 17),
    pricePerSeat: 0,
    buses: [b1, b2],
    passengers: [
      // Gujarati script name → exercises the font-fallback path.
      _p('p1', name: 'પ્રફુલ', assigned: const [
        SeatAssignment(busId: 'b1', seatId: 'b1_SU1'),
      ]),
      // Whole double sofa: two assignment entries on the SAME seatId.
      _p('p2', name: 'Rasik', assigned: const [
        SeatAssignment(busId: 'b1', seatId: 'b1_DL1'),
        SeatAssignment(busId: 'b1', seatId: 'b1_DL1'),
      ]),
      _p('p3', name: 'Bharat', assigned: const [
        SeatAssignment(busId: 'b2', seatId: 'b2_SL1'),
      ]),
    ],
  );
}

void main() {
  // Needed for rootBundle access if the font loader reaches the asset path.
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SeatChartPdf.buildTourChartPdf', () {
    test('all-buses chart: non-empty bytes, one page per bus', () async {
      final tour = _twoBusTour();
      final bytes = await SeatChartPdf.buildTourChartPdf(
        tour: tour,
        footer: const ChartFooter(
          boardingPlace: 'સ્થળ બસ સ્ટેન્ડ',
          departureTime: 'સાંજે 5 વાગ્યે',
          note: 'હેન્ડલર: રસિક',
        ),
      );

      expect(bytes, isNotEmpty);
      expect(_pageCount(bytes), tour.buses.length);
      expect(_pageCount(bytes), 2);
    });

    test('onlyBusId restricts the document to a single page', () async {
      final tour = _twoBusTour();
      final bytes = await SeatChartPdf.buildTourChartPdf(
        tour: tour,
        footer: const ChartFooter(),
        onlyBusId: 'b1',
      );

      expect(bytes, isNotEmpty);
      expect(_pageCount(bytes), 1);
    });

    test('builds without throwing when the footer is empty', () async {
      final tour = _twoBusTour();
      final bytes = await SeatChartPdf.buildTourChartPdf(
        tour: tour,
        footer: const ChartFooter(),
      );

      expect(bytes, isNotEmpty);
      expect(_pageCount(bytes), 2);
    });

    test('highlighting a passenger\'s seats still yields a valid page',
        () async {
      final tour = _twoBusTour();
      final bytes = await SeatChartPdf.buildTourChartPdf(
        tour: tour,
        footer: const ChartFooter(),
        onlyBusId: 'b1',
        highlightByBus: const {
          'b1': {'b1_DL1'},
        },
      );

      expect(bytes, isNotEmpty);
      expect(_pageCount(bytes), 1);
    });
  });

  // ── Leg-shared seat occupants (the per-person chart bug) ────────────────────
  //
  // When a GO-only passenger and a different RET-only passenger share the SAME
  // physical seat across legs, BOTH names must appear on the chart. The old
  // builder kept a single occupant per seat (last writer wins), so the chart
  // dropped one leg — a one-leg booker never saw their own name. These tests
  // lock the rendered per-seat occupant names the PDF draws.
  group('SeatChartPdf occupant names per seat', () {
    Tour legSharedTour() {
      final b1 = _balconyBus('b1');
      return Tour(
        title: 'Leg Share',
        fromCity: 'Surat',
        toCity: 'Dwarka',
        departureDate: DateTime(2026, 6, 16),
        pricePerSeat: 0,
        buses: [b1],
        passengers: [
          // GO leg of SU1.
          _p('go', name: 'GoRider',
              tripType: TripType.outboundOnly,
              assigned: const [SeatAssignment(busId: 'b1', seatId: 'b1_SU1')]),
          // RETURN leg of the SAME seat, a different person.
          _p('ret', name: 'RetRider',
              tripType: TripType.returnOnly,
              assigned: const [SeatAssignment(busId: 'b1', seatId: 'b1_SU1')]),
          // A whole double sofa held solo (two entries, same seatId) must stay
          // a SINGLE name — the fix must not double-list a solo owner.
          _p('solo', name: 'SoloOwner', assigned: const [
            SeatAssignment(busId: 'b1', seatId: 'b1_DL1'),
            SeatAssignment(busId: 'b1', seatId: 'b1_DL1'),
          ]),
        ],
      );
    }

    test('leg-shared seat lists BOTH occupants, GO first', () {
      final names =
          SeatChartPdf.debugOccupantNamesForBus(legSharedTour(), 'b1');
      expect(names['b1_SU1'], ['GoRider', 'RetRider']);
    });

    test('whole double held solo lists a single occupant', () {
      final names =
          SeatChartPdf.debugOccupantNamesForBus(legSharedTour(), 'b1');
      expect(names['b1_DL1'], ['SoloOwner']);
    });

    // ── Leg-scoped per-passenger chart ────────────────────────────────────
    //
    // A one-way recipient's after-lock image must show only THEIR leg. On the
    // outbound (GO) chart a return-only rider is not on the bus at all, so a
    // leg-shared seat collapses to just the GO holder — and vice versa. Without
    // this, a GO rider's own seat printed a return-only stranger's name beside
    // their own, with no leg context (live tour "bij", seat SU3/SL4/etc).

    test('GO-scoped chart shows only the outbound holder of a shared seat', () {
      final names = SeatChartPdf.debugOccupantNamesForBus(
        legSharedTour(),
        'b1',
        leg: CollectLeg.go,
      );
      expect(names['b1_SU1'], ['GoRider']);
    });

    test('RETURN-scoped chart shows only the return holder of a shared seat',
        () {
      final names = SeatChartPdf.debugOccupantNamesForBus(
        legSharedTour(),
        'b1',
        leg: CollectLeg.ret,
      );
      expect(names['b1_SU1'], ['RetRider']);
    });

    test('null leg (round-trip recipient) keeps BOTH leg-shared occupants', () {
      final names = SeatChartPdf.debugOccupantNamesForBus(
        legSharedTour(),
        'b1',
        leg: null,
      );
      expect(names['b1_SU1'], ['GoRider', 'RetRider']);
    });

    test('whole double held solo still lists once on a leg-scoped chart', () {
      final names = SeatChartPdf.debugOccupantNamesForBus(
        legSharedTour(),
        'b1',
        leg: CollectLeg.go,
      );
      // SoloOwner is round-trip → present on the GO leg, listed once.
      expect(names['b1_DL1'], ['SoloOwner']);
    });
  });

  // ── Recipient leg derivation ────────────────────────────────────────────
  //
  // The per-passenger image is scoped to the recipient's OWN leg. The leg MUST
  // come from the same tripType field the occupant filter uses, or the rider
  // would be filtered off their own seat. Round-trip → null (full chart).
  group('SeatChartPdf.recipientChartLeg', () {
    test('outbound-only recipient → GO leg', () {
      expect(
        SeatChartPdf.recipientChartLeg(
            _p('a', name: 'A', tripType: TripType.outboundOnly)),
        CollectLeg.go,
      );
    });

    test('return-only recipient → RETURN leg', () {
      expect(
        SeatChartPdf.recipientChartLeg(
            _p('a', name: 'A', tripType: TripType.returnOnly)),
        CollectLeg.ret,
      );
    });

    test('round-trip recipient → null (whole-journey chart)', () {
      expect(
        SeatChartPdf.recipientChartLeg(
            _p('a', name: 'A', tripType: TripType.roundTrip)),
        isNull,
      );
    });
  });
}
