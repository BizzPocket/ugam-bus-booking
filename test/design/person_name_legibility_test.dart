import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/design/components/ugam_person_row.dart';
import 'package:occubusbooking/design/components/ugam_request_row.dart';

/// The app-wide name rule, guarded at the two SHARED row components every
/// roster, occupant list, picker and request list is built from.
///
/// A person's name must READ. A clipped one ("U Jana…") can't be called out on
/// roll-call, searched for, or matched against a WhatsApp contact — so a long
/// name wraps to a second line before it is allowed to ellipse. This regressed
/// once as a per-screen patch; these tests make the rule structural instead.
///
/// Two lines, not unbounded: a pasted paragraph in the name field must still
/// not blow a dense row open.

/// A name far longer than any row is wide, in the script the app actually
/// ships to (Gujarati), so the wrap is exercised the way users see it.
const _longName = 'વિનોદભાઈ રમેશચંદ્ર પટેલ સોસાયટી અબ્રામા';

/// The `maxLines` the widget under test applies to [text].
int? _maxLinesOf(WidgetTester tester, String text) =>
    tester.widget<Text>(find.text(text)).maxLines;

/// The rendered height of the widget holding [text] — used to prove the row
/// GROWS for a long name instead of clipping it.
double _heightOf(WidgetTester tester, String text) =>
    tester.getSize(find.text(text)).height;

Future<void> _pump(WidgetTester tester, Widget child) => tester.pumpWidget(
  MaterialApp(
    theme: ThemeData(brightness: Brightness.dark),
    home: Scaffold(
      // Phone-narrow on purpose: at a comfortable width nothing would wrap and
      // the test would pass without proving anything.
      body: SizedBox(width: 320, child: child),
    ),
  ),
);

void main() {
  group('UgamPersonRow name', () {
    testWidgets('wraps to 2 lines instead of ellipsing at 1', (tester) async {
      await _pump(tester, const UgamPersonRow(name: _longName));
      expect(_maxLinesOf(tester, _longName), 2);
    });

    testWidgets('a long name renders taller than a short one', (tester) async {
      await _pump(tester, const UgamPersonRow(name: 'Vi'));
      final short = _heightOf(tester, 'Vi');
      await _pump(tester, const UgamPersonRow(name: _longName));
      expect(_heightOf(tester, _longName), greaterThan(short));
    });

    testWidgets('still bounded — never grows past 2 lines', (tester) async {
      await _pump(tester, const UgamPersonRow(name: 'Vi'));
      final oneLine = _heightOf(tester, 'Vi');
      const paragraph = '$_longName $_longName $_longName';
      await _pump(tester, const UgamPersonRow(name: paragraph));
      expect(_heightOf(tester, paragraph), lessThanOrEqualTo(oneLine * 2 + 1));
    });

    testWidgets('renders without overflow on a narrow phone', (tester) async {
      await _pump(tester, const UgamPersonRow(name: _longName));
      expect(tester.takeException(), isNull);
    });
  });

  group('UgamRequestRow name', () {
    testWidgets('wraps to 2 lines instead of ellipsing at 1', (tester) async {
      await _pump(
        tester,
        const UgamRequestRow(initials: 'VP', name: _longName),
      );
      expect(_maxLinesOf(tester, _longName), 2);
    });

    testWidgets('a long name renders taller than a short one', (tester) async {
      await _pump(tester, const UgamRequestRow(initials: 'V', name: 'Vi'));
      final short = _heightOf(tester, 'Vi');
      await _pump(
        tester,
        const UgamRequestRow(initials: 'VP', name: _longName),
      );
      expect(_heightOf(tester, _longName), greaterThan(short));
    });

    testWidgets('renders without overflow on a narrow phone', (tester) async {
      await _pump(
        tester,
        const UgamRequestRow(initials: 'VP', name: _longName, timeAgo: '2h'),
      );
      expect(tester.takeException(), isNull);
    });
  });
}
