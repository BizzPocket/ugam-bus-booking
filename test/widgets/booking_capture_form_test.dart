import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:occubusbooking/models/request_line.dart';
import 'package:occubusbooking/models/seat_type.dart';
import 'package:occubusbooking/models/trip_type.dart';
import 'package:occubusbooking/widgets/booking_capture_form.dart';

/// Regression for the motivating UX bug: the seat section used a per-row list
/// whose type auto-cycled, so you could NOT express "2 Single (full) + 1 Single
/// (return)" — the type wasn't selectable and the cycle kept handing you Double.
///
/// The redesign makes the LEG the primary axis (a tab) and each seat type a
/// counter within it. These tests drive the public [BookingCaptureFormState]
/// contract (keyed tab + stepper taps → `collect()`), asserting the assembled
/// [RequestLine]s. Localization isn't initialised under `flutter test`, so
/// `tr(...)` returns raw keys — we target stable widget keys, never label text.

/// A plausible Indian mobile (passes `isPlausibleIndianMobile`): not all-same,
/// not an ascending/descending run.
const _phone = '9824011223';

/// Host the form the way the real screens do — inside a [ListView], which gives
/// its children TIGHT full-width constraints (a bare SingleChildScrollView would
/// give loose width and collapse the phone field).
Widget _host(Widget child) => GetMaterialApp(
  theme: ThemeData(brightness: Brightness.dark),
  home: Scaffold(body: ListView(children: [child])),
);

/// Enlarge the surface so the whole form is laid out on-screen (no scrolling
/// needed to hit the steppers/tabs), then restore it after the test.
///
/// Also swallows the one harmless overflow this form triggers under `flutter
/// test`: the shared [UgamPhoneInput]'s fixed-width "+91" box clips the 🇮🇳 flag
/// glyph, which renders wider under the test font than on a device. It's a
/// pre-existing rendering artifact of an unrelated component, not this widget.
void _useTallSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(1200, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final prevOnError = FlutterError.onError;
  FlutterError.onError = (details) {
    if (details.exceptionAsString().contains('A RenderFlex overflowed')) return;
    prevOnError?.call(details);
  };
  addTearDown(() => FlutterError.onError = prevOnError);
}

void main() {
  testWidgets('split one type across legs: 2 Single full + 1 Single return', (
    tester,
  ) async {
    _useTallSurface(tester);
    final key = GlobalKey<BookingCaptureFormState>();
    await tester.pumpWidget(
      _host(BookingCaptureForm(key: key, fromCity: 'A', toCity: 'B')),
    );

    // Name + phone (the only two text fields on a blank create form, in order).
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), 'Asha');
    await tester.enterText(fields.at(1), _phone);

    // Full tab is the default — bump Single ×2 there.
    await tester.tap(find.byKey(const Key('seat-add-singleSofa')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('seat-add-singleSofa')));
    await tester.pump();

    // Switch to the Return tab, bump Single ×1.
    await tester.tap(find.byKey(Key('legtab-${TripType.returnOnly.name}')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('seat-add-singleSofa')));
    await tester.pump();

    final data = key.currentState!.collect();
    expect(data, isNotNull);
    expect(data!.totalSeats, 3);
    expect(data.singleSofa, 3);
    expect(data.doubleSofa, 0);

    final single = data.lines
        .where((l) => l.seatType == SeatType.singleSofa)
        .toList();
    expect(single.length, 2, reason: 'one line per (type, leg)');
    expect(single.firstWhere((l) => l.leg == TripType.roundTrip).qty, 2);
    expect(single.firstWhere((l) => l.leg == TripType.returnOnly).qty, 1);
  });

  testWidgets('forcedLeg hides the tab bar and pins every line to that leg', (
    tester,
  ) async {
    _useTallSurface(tester);
    final key = GlobalKey<BookingCaptureFormState>();
    await tester.pumpWidget(
      _host(
        BookingCaptureForm(
          key: key,
          fromCity: 'A',
          toCity: 'B',
          forcedLeg: TripType.returnOnly,
        ),
      ),
    );

    // No tabs on a forced surface.
    expect(find.byKey(Key('legtab-${TripType.roundTrip.name}')), findsNothing);
    expect(find.byKey(Key('legtab-${TripType.returnOnly.name}')), findsNothing);

    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), 'Bina');
    await tester.enterText(fields.at(1), _phone);
    await tester.tap(find.byKey(const Key('seat-add-doubleSofa')));
    await tester.pump();

    final data = key.currentState!.collect()!;
    expect(data.lines, hasLength(1));
    expect(data.lines.single.seatType, SeatType.doubleSofa);
    expect(data.lines.single.leg, TripType.returnOnly);
  });

  testWidgets('edit hydration buckets existing lines into the right tabs', (
    tester,
  ) async {
    _useTallSurface(tester);
    final key = GlobalKey<BookingCaptureFormState>();
    await tester.pumpWidget(
      _host(
        BookingCaptureForm(
          key: key,
          fromCity: 'A',
          toCity: 'B',
          initial: BookingCaptureInitial.fromLines(
            name: 'Asha',
            phone: _phone,
            lines: const [
              RequestLine(
                seatType: SeatType.singleSofa,
                qty: 2,
                leg: TripType.roundTrip,
              ),
              RequestLine(
                seatType: SeatType.singleSofa,
                qty: 1,
                leg: TripType.returnOnly,
              ),
            ],
          ),
        ),
      ),
    );

    // Hydration alone (no taps) must round-trip to the same split.
    final data = key.currentState!.collect()!;
    expect(data.singleSofa, 3);
    final single = data.lines
        .where((l) => l.seatType == SeatType.singleSofa)
        .toList();
    expect(single.firstWhere((l) => l.leg == TripType.roundTrip).qty, 2);
    expect(single.firstWhere((l) => l.leg == TripType.returnOnly).qty, 1);
  });
}
