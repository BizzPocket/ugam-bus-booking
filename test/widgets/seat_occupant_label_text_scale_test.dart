import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/components/seat_chart_tile.dart';
import 'package:occubusbooking/design/group_color.dart';
import 'package:occubusbooking/models/passenger.dart';
import 'package:occubusbooking/models/seat_layout.dart';
import 'package:occubusbooking/models/seat_type.dart';
import 'package:occubusbooking/models/trip_type.dart';
import 'package:occubusbooking/widgets/seat_occupant_label.dart';

/// Regression for the vertical overflow every seat-chart surface in the app hit
/// at the 1.3x accessibility text scale `lib/app.dart` permits.
///
/// [SeatOccupantLabel] documented "FIXED font sizes", but a fixed font SIZE is
/// not a fixed rendered size: `MediaQuery.textScaler` still multiplies it, while
/// `kSeatTileH` is a hard 74 logical pixels. A two-line Gujarati name therefore
/// could not fit its tile at max scale. The fix clamps the label's OWN scaler to
/// [kSeatLabelMaxTextScale]; these tests pin both halves of that — that it no
/// longer overflows, and that the clamp is an upper bound only, so small phones
/// keep shrinking as they always did.
///
/// ## How overflow is detected here
///
/// Flutter does NOT throw on a layout overflow — `RenderFlex.paint` *reports* it
/// through `FlutterError.reportError` and carries on painting hazard stripes. So
/// [_overflowsIn] installs its own `FlutterError.onError` for the duration of
/// the pump and classifies on the shared "overflowed by" wording, the same way
/// `test/overflow/overflow_guard.dart` does. [_detectorCanFail] is the proof
/// that this actually catches something: it pumps the pre-fix layout into the
/// same box and asserts the detector goes red. A guard that has never been seen
/// to fail is not evidence.

/// A real long two-word Gujarati name. Real user data is the one legitimate
/// place for a literal in a layout test — it does not come from the translation
/// catalogue.
const String _guName = 'પ્રિયદર્શિની વાઘેલા';

/// The tightest real budget a [SeatOccupantLabel] is ever given, from
/// `SeatChartTile._bookedTile`:
///
///   74 (kSeatTileH) - 2x1.5 (priority border) - 15 (top pad) - 8 (bottom pad)
const double _tightestBudgetH = 48.0;

/// The body width the booked tile leaves the label: 68 - 2x1.5 - 2x5 inset.
const double _bodyW = 55.0;

Passenger _p(String name) => Passenger(
      id: 'p1',
      tourId: 't1',
      name: name,
      phone: '+919876543210',
      tripType: TripType.roundTrip,
    );

/// A booked seater cell. `forward: true` puts the tile on the 1.5pt priority
/// border, which is the variant with the least room for text.
SeatCell _priorityCell() => const SeatCell(
      row: 0,
      col: 0,
      seatType: SeatType.seater,
      seatId: 'S12',
      forward: true,
    );

/// Pumps [child] at [scale] and returns every "overflowed by" report Flutter
/// made while it laid out and painted.
Future<List<String>> _overflowsIn(
  WidgetTester tester,
  Widget child, {
  required double scale,
  Brightness brightness = Brightness.dark,
}) async {
  final reported = <String>[];
  final previous = FlutterError.onError;
  FlutterError.onError = (d) => reported.add(d.exception.toString());
  try {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(brightness: brightness),
        home: MediaQuery(
          // Delivered as the PRODUCT app.dart hands down
          // (`userFactor.clamp(0.9, 1.3) * UgamScale.of(context)`), which is the
          // number that actually reaches the glyphs.
          data: MediaQueryData(textScaler: TextScaler.linear(scale)),
          child: Scaffold(body: Center(child: child)),
        ),
      ),
    );
    await tester.pump();
  } finally {
    FlutterError.onError = previous;
  }
  // Anything the binding recorded while our handler was not installed.
  for (var i = 0; i < 8; i++) {
    final leaked = tester.takeException();
    if (leaked == null) break;
    reported.add(leaked.toString());
  }
  return reported.where((s) => s.contains('overflowed by')).toList();
}

/// The label sitting in exactly the room the tightest tile variant gives it.
Widget _inTightestBudget(Widget label) => SizedBox(
      width: _bodyW,
      height: _tightestBudgetH,
      child: Center(child: label),
    );

/// The pre-fix label: identical, minus the textScaler clamp. Only used to prove
/// the detector above can go red.
Widget _detectorCanFail() => _inTightestBudget(
      Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: const [
          Text(
            _guName,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              height: 1.12,
            ),
          ),
          SizedBox(height: 2),
          Text(
            '9876543210',
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 9.5, height: 1.2),
          ),
        ],
      ),
    );

double _paragraphHeight(WidgetTester tester, String text) {
  final ro = tester.renderObject<RenderParagraph>(
    find.descendant(of: find.byType(SeatOccupantLabel), matching: find.text(text)),
  );
  return ro.size.height;
}

void main() {
  // ── The detector has to be able to fail, or a green suite proves nothing ──

  testWidgets('the pre-fix layout DOES overflow the tile budget at 1.3x', (
    tester,
  ) async {
    final hits = await _overflowsIn(tester, _detectorCanFail(), scale: 1.3);
    expect(
      hits,
      isNotEmpty,
      reason: 'If this ever goes green, the overflow detector in this file has '
          'stopped detecting and every other test here is meaningless. '
          '40.52 x 1.3 + 2 = 54.7pt of content in a 48pt box.',
    );
  });

  // ── The fix ──

  group('SeatOccupantLabel fits the tightest tile budget', () {
    for (final scale in <double>[0.85, 1.0, 1.105, 1.25, 1.3]) {
      testWidgets('effective text scale $scale', (tester) async {
        final hits = await _overflowsIn(
          tester,
          _inTightestBudget(
            const SeatOccupantLabel(
              name: _guName,
              phone: '+919876543210',
              nameColor: Colors.white,
              phoneColor: Colors.white70,
            ),
          ),
          scale: scale,
        );
        expect(hits, isEmpty, reason: hits.join('\n'));
      });
    }
  });

  testWidgets('the whole booked tile survives 1.3x in both themes', (
    tester,
  ) async {
    for (final brightness in Brightness.values) {
      final hits = await _overflowsIn(
        tester,
        SeatChartTile(
          cell: _priorityCell(),
          occupants: [_p(_guName)],
          groupColors: const GroupColorResolver(<String, int>{}),
        ),
        scale: 1.3,
        brightness: brightness,
      );
      expect(hits, isEmpty, reason: '$brightness\n${hits.join('\n')}');
      // Still the canonical content: name over mobile, neither dropped.
      expect(find.text(_guName), findsOneWidget);
      expect(find.text('9876543210'), findsOneWidget);
    }
  });

  // ── The clamp is an UPPER bound only ──

  group('clamp semantics', () {
    Future<TextScaler> scalerAt(WidgetTester tester, double ambient) async {
      await _overflowsIn(
        tester,
        _inTightestBudget(
          const SeatOccupantLabel(
            name: _guName,
            phone: '+919876543210',
            nameColor: Colors.white,
            phoneColor: Colors.white70,
          ),
        ),
        scale: ambient,
      );
      final texts = tester
          .widgetList<Text>(
            find.descendant(
              of: find.byType(SeatOccupantLabel),
              matching: find.byType(Text),
            ),
          )
          .toList();
      expect(texts, hasLength(2), reason: 'name + mobile');
      // Both lines must ride the SAME scaler, or the two halves of one label
      // would grow at different rates.
      expect(texts[0].textScaler, texts[1].textScaler);
      return texts[0].textScaler!;
    }

    testWidgets('a small phone still shrinks — 0.85 is not raised to 1.10', (
      tester,
    ) async {
      final s = await scalerAt(tester, 0.85);
      expect(s.scale(10), closeTo(8.5, 0.0001));
    });

    testWidgets('the default scale passes straight through', (tester) async {
      final s = await scalerAt(tester, 1.0);
      expect(s.scale(10), closeTo(10.0, 0.0001));
    });

    testWidgets('320pt at OS 1.3 (effective 1.105) is barely touched', (
      tester,
    ) async {
      final s = await scalerAt(tester, 1.105);
      expect(s.scale(10), closeTo(kSeatLabelMaxTextScale * 10, 0.0001));
    });

    testWidgets('390pt at OS 1.3 is capped at the ceiling', (tester) async {
      final s = await scalerAt(tester, 1.3);
      expect(s.scale(10), closeTo(kSeatLabelMaxTextScale * 10, 0.0001));
    });
  });

  // ── The name keeps BOTH lines: the point of clamping rather than
  //    ellipsising was that a 1.3x reader can still read who is in the seat ──

  testWidgets('the name still gets two lines at 1.3x, not one', (tester) async {
    await _overflowsIn(
      tester,
      _inTightestBudget(
        const SeatOccupantLabel(
          name: _guName,
          phone: '+919876543210',
          nameColor: Colors.white,
          phoneColor: Colors.white70,
        ),
      ),
      scale: 1.3,
    );
    // 2 lines x 13pt x 1.12 line-height x the 1.10 ceiling.
    expect(
      _paragraphHeight(tester, _guName),
      closeTo(2 * 13 * 1.12 * kSeatLabelMaxTextScale, 0.5),
    );
  });

  testWidgets('a one-line caller (stacked/leg half) is unaffected', (
    tester,
  ) async {
    final hits = await _overflowsIn(
      tester,
      SizedBox(
        // (74 - 2x1.5 border - 1 divider) / 2 - 2x2 padding, from
        // SeatChartTile._stackedHalf.
        width: _bodyW,
        height: 31,
        child: Center(
          child: const SeatOccupantLabel(
            name: _guName,
            phone: '+919876543210',
            nameColor: Colors.white,
            phoneColor: Colors.white70,
            nameSize: 11.5,
            phoneSize: 8.5,
            nameMaxLines: 1,
          ),
        ),
      ),
      scale: 1.3,
    );
    expect(hits, isEmpty, reason: hits.join('\n'));
  });
}
