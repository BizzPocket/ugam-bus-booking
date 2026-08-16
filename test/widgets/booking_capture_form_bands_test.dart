import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:occubusbooking/models/bus_details.dart';
import 'package:occubusbooking/models/seat_layout.dart';
import 'package:occubusbooking/models/seat_type.dart';
import 'package:occubusbooking/models/trip_type.dart';
import 'package:occubusbooking/utils/band_options.dart';
import 'package:occubusbooking/utils/request_pricing.dart';
import 'package:occubusbooking/widgets/booking_capture_form.dart';

/// Banding the request form: the FULL-TRIP tab asks which price band each seat
/// is for and charges it; the one-leg tabs stay free and join the waiting list.
///
/// Localization is not initialised under `flutter test`, so `tr(...)` returns
/// raw keys — every finder targets a stable widget key, never label text.

const _phone = '9824011223';

Widget _host(Widget child) => GetMaterialApp(
      theme: ThemeData(brightness: Brightness.dark),
      home: Scaffold(body: ListView(children: [child])),
    );

void _useTallSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(1200, 3200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final prevOnError = FlutterError.onError;
  FlutterError.onError = (details) {
    if (details.exceptionAsString().contains('A RenderFlex overflowed')) return;
    prevOnError?.call(details);
  };
  addTearDown(() => FlutterError.onError = prevOnError);
}

SeatCell _cell(int row, int col, SeatType type, String id) =>
    SeatCell(row: row, col: col, seatType: type, seatId: id);

/// The live bus read from Supabase on 2026-08-16: three bands over six rows,
/// every row carrying both sofa types.
Bus _liveBus() => Bus(
      id: 'bus1',
      name: 'મોમાઈ કૃપા',
      pricePerSeat: 1351.35,
      priceBands: const [
        PriceBand(label: 'બેન્ડ', fromRow: 0, toRow: 3, price: 1600),
        PriceBand(label: 'બેન્ડ', fromRow: 4, toRow: 4, price: 1500),
        PriceBand(label: 'બેન્ડ', fromRow: 5, toRow: 5, price: 1200),
      ],
      layout: BusLayout(
        rows: 6,
        cols: 5,
        grid: [
          for (var r = 0; r < 6; r++) ...[
            _cell(r, 0, SeatType.doubleSofa, 'DL$r'),
            _cell(r, 4, SeatType.singleSofa, 'SL$r'),
          ],
        ],
      ),
    );

Future<void> _fillIdentity(WidgetTester tester) async {
  final fields = find.byType(TextField);
  await tester.enterText(fields.at(0), 'Asha');
  await tester.enterText(fields.at(1), _phone);
}

/// Tap the banded "add" affordance for [type], then choose [optionIndex] and
/// [qty] in the dialog it opens.
Future<void> _pickBand(
  WidgetTester tester, {
  required SeatType type,
  required int optionIndex,
  required int qty,
}) async {
  await tester.tap(find.byKey(Key('seat-band-add-${type.name}')));
  await tester.pumpAndSettle();

  final options = bandOptionsFor(buses: [_liveBus()], type: type);
  await tester.tap(find.byKey(Key('band-${options[optionIndex].key}')));
  await tester.pumpAndSettle();

  await tester.tap(find.byKey(Key('bandqty-$qty')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a full-trip seat is charged at the band the customer picked',
      (tester) async {
    _useTallSurface(tester);
    final key = GlobalKey<BookingCaptureFormState>();
    await tester.pumpWidget(_host(BookingCaptureForm(
      key: key,
      fromCity: 'A',
      toCity: 'B',
      buses: [_liveBus()],
    )));
    await _fillIdentity(tester);

    // Front band (rows 1-4) at Rs 1,600 per berth, two single sofas.
    await _pickBand(
      tester,
      type: SeatType.singleSofa,
      optionIndex: 0,
      qty: 2,
    );

    final data = key.currentState!.collect()!;
    final line = data.lines.single;

    expect(line.leg, TripType.roundTrip);
    expect(line.seatType, SeatType.singleSofa);
    expect(line.qty, 2);
    expect(line.band!.pricePaise, 160000);
    expect(requestChargePaise(data.lines), 320000);
  });

  testWidgets('a whole double sofa is charged as two berths of the band',
      (tester) async {
    _useTallSurface(tester);
    final key = GlobalKey<BookingCaptureFormState>();
    await tester.pumpWidget(_host(BookingCaptureForm(
      key: key,
      fromCity: 'A',
      toCity: 'B',
      buses: [_liveBus()],
    )));
    await _fillIdentity(tester);

    await _pickBand(
      tester,
      type: SeatType.doubleSofa,
      optionIndex: 0,
      qty: 1,
    );

    final data = key.currentState!.collect()!;

    expect(data.totalSeats, 2, reason: 'a double sofa occupies two berths');
    expect(requestChargePaise(data.lines), 320000);
  });

  testWidgets('the same seat type can be taken in two different bands',
      (tester) async {
    _useTallSurface(tester);
    final key = GlobalKey<BookingCaptureFormState>();
    await tester.pumpWidget(_host(BookingCaptureForm(
      key: key,
      fromCity: 'A',
      toCity: 'B',
      buses: [_liveBus()],
    )));
    await _fillIdentity(tester);

    // 2 singles in the Rs 1,600 band, then 1 more in the Rs 1,200 band.
    await _pickBand(tester, type: SeatType.singleSofa, optionIndex: 0, qty: 2);
    await _pickBand(tester, type: SeatType.singleSofa, optionIndex: 2, qty: 1);

    final data = key.currentState!.collect()!;
    final singles =
        data.lines.where((l) => l.seatType == SeatType.singleSofa).toList();

    expect(singles.length, 2, reason: 'one line per band');
    expect(data.totalSeats, 3);
    // 2 x 1,600 + 1 x 1,200 = Rs 4,400
    expect(requestChargePaise(data.lines), 440000);
  });

  testWidgets('a one-leg seat stays free and unbanded', (tester) async {
    _useTallSurface(tester);
    final key = GlobalKey<BookingCaptureFormState>();
    await tester.pumpWidget(_host(BookingCaptureForm(
      key: key,
      fromCity: 'A',
      toCity: 'B',
      buses: [_liveBus()],
    )));
    await _fillIdentity(tester);

    await tester.tap(find.byKey(Key('legtab-${TripType.outboundOnly.name}')));
    await tester.pumpAndSettle();
    // The one-leg tabs keep the plain stepper — no band is ever asked for.
    await tester.tap(find.byKey(const Key('seat-add-singleSofa')));
    await tester.pump();

    final data = key.currentState!.collect()!;
    final line = data.lines.single;

    expect(line.leg, TripType.outboundOnly);
    expect(line.band, isNull);
    expect(requestChargePaise(data.lines), 0);
    expect(isWaitlistLine(line), isTrue);
  });

  testWidgets('removing a band line drops it from the request', (tester) async {
    _useTallSurface(tester);
    final key = GlobalKey<BookingCaptureFormState>();
    await tester.pumpWidget(_host(BookingCaptureForm(
      key: key,
      fromCity: 'A',
      toCity: 'B',
      buses: [_liveBus()],
    )));
    await _fillIdentity(tester);

    await _pickBand(tester, type: SeatType.singleSofa, optionIndex: 0, qty: 2);
    await tester.tap(find.byKey(const Key('seat-band-remove-singleSofa-0')));
    await tester.pumpAndSettle();

    expect(key.currentState!.totalSeats, 0);
    expect(key.currentState!.collect(), isNull, reason: 'no seats is invalid');
  });

  testWidgets('with no buses the form keeps the plain stepper everywhere',
      (tester) async {
    // The admin add/edit surfaces pass no buses. They must behave exactly as
    // before — this feature is customer-request-only for now.
    _useTallSurface(tester);
    final key = GlobalKey<BookingCaptureFormState>();
    await tester.pumpWidget(
      _host(BookingCaptureForm(key: key, fromCity: 'A', toCity: 'B')),
    );
    await _fillIdentity(tester);

    expect(find.byKey(const Key('seat-band-add-singleSofa')), findsNothing);
    await tester.tap(find.byKey(const Key('seat-add-singleSofa')));
    await tester.pump();

    final data = key.currentState!.collect()!;
    expect(data.lines.single.band, isNull);
    expect(data.lines.single.leg, TripType.roundTrip);
  });

  testWidgets('bands appear when the buses arrive after the first frame',
      (tester) async {
    // THE BUG THIS PINS: the customer screen cannot read `Tour.buses` (no anon
    // SELECT policy), so it fetches them over an RPC and passes them down on a
    // LATER frame. Deriving the bands once in initState meant they were derived
    // from an empty list and never again — the picker never appeared on a real
    // device, only in tests that passed buses up front.
    _useTallSurface(tester);
    final key = GlobalKey<BookingCaptureFormState>();

    await tester.pumpWidget(_host(
      BookingCaptureForm(key: key, fromCity: 'A', toCity: 'B'),
    ));
    expect(find.byKey(const Key('seat-band-add-singleSofa')), findsNothing);

    // The RPC answers.
    await tester.pumpWidget(_host(BookingCaptureForm(
      key: key,
      fromCity: 'A',
      toCity: 'B',
      buses: [_liveBus()],
    )));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('seat-band-add-singleSofa')), findsOneWidget);
    expect(find.byKey(const Key('seat-add-singleSofa')), findsNothing);
  });

  testWidgets('a quantity typed before the buses arrive is not lost',
      (tester) async {
    // A fast customer can tap the stepper in the window before the RPC answers.
    // Those berths must survive the swap to the banded tile rather than being
    // stranded behind a control that is no longer rendered.
    _useTallSurface(tester);
    final key = GlobalKey<BookingCaptureFormState>();

    await tester.pumpWidget(_host(
      BookingCaptureForm(key: key, fromCity: 'A', toCity: 'B'),
    ));
    await _fillIdentity(tester);
    await tester.tap(find.byKey(const Key('seat-add-singleSofa')));
    await tester.pump();
    expect(key.currentState!.totalSeats, 1);

    await tester.pumpWidget(_host(BookingCaptureForm(
      key: key,
      fromCity: 'A',
      toCity: 'B',
      buses: [_liveBus()],
    )));
    await tester.pumpAndSettle();

    expect(key.currentState!.totalSeats, 1, reason: 'the berth survives');
    // It carries no band, so it is not chargeable — the customer must still
    // choose one, but nothing they did was thrown away.
    expect(key.currentState!.chargePaise, 0);
    expect(find.byKey(const Key('seat-band-remove-singleSofa-0')),
        findsOneWidget);
  });

  testWidgets('an unpriced bus falls back to the plain stepper', (tester) async {
    // price_per_seat 0 is the normal state of a request-mode tour until the
    // agent prices it. Nothing can be quoted, so nothing may be charged — the
    // form must degrade to today's free request rather than offering Rs 0.
    _useTallSurface(tester);
    final key = GlobalKey<BookingCaptureFormState>();
    await tester.pumpWidget(_host(BookingCaptureForm(
      key: key,
      fromCity: 'A',
      toCity: 'B',
      buses: [
        Bus(
          id: 'b',
          name: 'b',
          pricePerSeat: 0,
          layout: BusLayout(rows: 1, cols: 2, grid: [
            _cell(0, 0, SeatType.singleSofa, 'SL0'),
          ]),
        ),
      ],
    )));
    await _fillIdentity(tester);

    expect(find.byKey(const Key('seat-band-add-singleSofa')), findsNothing);
    expect(find.byKey(const Key('seat-add-singleSofa')), findsOneWidget);
  });
}
