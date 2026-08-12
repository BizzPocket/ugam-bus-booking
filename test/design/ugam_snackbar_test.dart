import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/design/components/ugam_snackbar.dart';
import 'package:occubusbooking/design/components/ugam_tappable.dart';
import 'package:occubusbooking/design/tokens.dart';

/// Cover for the undo affordance the Board depends on (interaction spec §8):
/// every Board mutation raises a toast that can be taken back, so the action
/// has to be reachable, tappable, announced, and on screen long enough to be
/// noticed by someone who has just realised they tapped the wrong berth.
///
/// EasyLocalization is not initialised here, so `tr()` renders raw keys — the
/// same convention the rest of the suite uses. Only `plural()` needs a loaded
/// locale, and this component does not call it.
Widget _host(Widget child, {Brightness brightness = Brightness.dark}) =>
    MaterialApp(
      theme: ThemeData(brightness: brightness),
      home: Scaffold(body: Center(child: child)),
    );

void main() {
  group('default appearance is unchanged', () {
    testWidgets('no action renders message, title and no button', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          const UgamSnackbar(
            title: 'Saved',
            message: 'Seat DL3 assigned',
            tone: UgamSnackTone.success,
          ),
        ),
      );

      expect(find.text('Saved'), findsOneWidget);
      expect(find.text('Seat DL3 assigned'), findsOneWidget);
      // The action control is the ONLY UgamTappable this widget ever builds.
      expect(find.byType(UgamTappable), findsNothing);
      // ...and no LayoutBuilder is introduced into the existing tree.
      expect(
        find.descendant(
          of: find.byType(UgamSnackbar),
          matching: find.byType(LayoutBuilder),
        ),
        findsNothing,
      );
    });

    testWidgets('an action-less bar stays shorter than one with an action', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          const SizedBox(
            width: 350,
            child: UgamSnackbar(message: 'Seat DL3 assigned'),
          ),
        ),
      );
      final plain = tester.getSize(find.byType(UgamSnackbar)).height;

      await tester.pumpWidget(
        _host(
          SizedBox(
            width: 350,
            child: UgamSnackbar(
              message: 'Seat DL3 assigned',
              action: UgamSnackAction(label: 'Undo', onPressed: () {}),
            ),
          ),
        ),
      );
      final withAction = tester.getSize(find.byType(UgamSnackbar)).height;

      // The extra height is the 44pt target; the plain bar must not inherit it.
      expect(plain, lessThan(withAction));
    });
  });

  group('the action', () {
    testWidgets('renders its label and fires its callback', (tester) async {
      var fired = 0;
      await tester.pumpWidget(
        _host(
          SizedBox(
            width: 350,
            child: UgamSnackbar(
              message: 'Moved Priti Patel to DL3',
              action: UgamSnackAction(
                label: 'Undo',
                icon: Icons.undo_rounded,
                onPressed: () => fired++,
              ),
            ),
          ),
        ),
      );

      expect(find.text('Undo'), findsOneWidget);
      expect(find.byIcon(Icons.undo_rounded), findsOneWidget);

      await tester.tap(find.byType(UgamTappable));
      await tester.pumpAndSettle();
      expect(fired, 1);
    });

    testWidgets('meets the 44pt touch minimum despite the short bar', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          SizedBox(
            width: 350,
            child: UgamSnackbar(
              // Single short line — the tightest the bar ever gets.
              message: 'Done',
              action: UgamSnackAction(label: 'Undo', onPressed: () {}),
            ),
          ),
        ),
      );

      final target = tester.getSize(find.byType(UgamTappable));
      expect(target.height, greaterThanOrEqualTo(44.0));
      expect(target.width, greaterThanOrEqualTo(44.0));
    });

    testWidgets('exposes exactly one button node with the semantic label', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        _host(
          SizedBox(
            width: 350,
            child: UgamSnackbar(
              message: 'Moved Priti Patel to DL3',
              action: UgamSnackAction(
                label: 'Undo',
                icon: Icons.undo_rounded,
                onPressed: () {},
                semanticLabel: 'Undo moving Priti Patel to DL3',
              ),
            ),
          ),
        ),
      );

      expect(
        find.bySemanticsLabel('Undo moving Priti Patel to DL3'),
        findsOneWidget,
      );
      // The bare word must NOT also surface as its own node.
      expect(find.bySemanticsLabel('Undo'), findsNothing);
      handle.dispose();
    });

    testWidgets('falls back to the visible label when none is supplied', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        _host(
          SizedBox(
            width: 350,
            child: UgamSnackbar(
              message: 'Done',
              action: UgamSnackAction(label: 'Undo', onPressed: () {}),
            ),
          ),
        ),
      );

      expect(find.bySemanticsLabel('Undo'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('does not steal focus from a field the user is typing in', (
      tester,
    ) async {
      final node = FocusNode();
      addTearDown(node.dispose);
      var showBar = false;
      late StateSetter setter;

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(brightness: Brightness.dark),
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                setter = setState;
                return Column(
                  children: [
                    TextField(focusNode: node),
                    if (showBar)
                      SizedBox(
                        width: 350,
                        child: UgamSnackbar(
                          message: 'Moved Priti Patel to DL3',
                          action: UgamSnackAction(
                            label: 'Undo',
                            onPressed: () {},
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
        ),
      );

      node.requestFocus();
      await tester.pump();
      expect(node.hasFocus, isTrue);

      // The toast arrives mid-typing, exactly as it will on the Board.
      setter(() => showBar = true);
      await tester.pumpAndSettle();

      expect(
        node.hasFocus,
        isTrue,
        reason: 'the toast must be inert to the focus system — a focusable '
            'action would dismiss the keyboard the user is typing on',
      );
    });
  });

  group('layout survives a long label', () {
    // Gujarati is the primary language and runs ~30% longer than English.
    const gujaratiUndo = 'પાછું લો';

    testWidgets('no overflow on a narrow phone with Gujarati strings', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          SizedBox(
            // 320pt device minus the host's two 14pt gutters.
            width: 292,
            child: UgamSnackbar(
              title: 'ફેરફાર સાચવ્યો',
              message: 'પ્રીતિ પટેલને DL3 પર ખસેડ્યાં',
              action: UgamSnackAction(
                label: gujaratiUndo,
                icon: Icons.undo_rounded,
                onPressed: () {},
              ),
            ),
          ),
        ),
      );

      expect(tester.takeException(), isNull);
      expect(find.text(gujaratiUndo), findsOneWidget);
    });

    testWidgets('a pathologically long action cannot crowd out the message', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          SizedBox(
            width: 292,
            child: UgamSnackbar(
              message: 'પ્રીતિ પટેલને DL3 પર ખસેડ્યાં',
              action: UgamSnackAction(
                label: 'આ છેલ્લો ફેરફાર સંપૂર્ણપણે પાછો લો',
                onPressed: () {},
              ),
            ),
          ),
        ),
      );

      expect(tester.takeException(), isNull);
      final action = tester.getSize(find.byType(UgamTappable));
      expect(
        action.width,
        lessThanOrEqualTo(292 * 0.45 + 0.5),
        reason: 'the action is capped at 45% of the bar so the message keeps '
            'a readable column',
      );
    });
  });

  group('tone', () {
    testWidgets('each tone picks its own glyph', (tester) async {
      for (final (tone, icon) in const [
        (UgamSnackTone.success, Icons.check_circle_rounded),
        (UgamSnackTone.error, Icons.error_rounded),
        (UgamSnackTone.info, Icons.info_rounded),
      ]) {
        await tester.pumpWidget(
          _host(UgamSnackbar(message: 'm', tone: tone)),
        );
        expect(find.byIcon(icon), findsOneWidget, reason: '$tone');
      }
    });

    testWidgets('renders in both themes', (tester) async {
      for (final b in Brightness.values) {
        await tester.pumpWidget(
          _host(
            SizedBox(
              width: 350,
              child: UgamSnackbar(
                message: 'Moved Priti Patel to DL3',
                tone: UgamSnackTone.error,
                action: UgamSnackAction(label: 'Undo', onPressed: () {}),
              ),
            ),
            brightness: b,
          ),
        );
        expect(tester.takeException(), isNull, reason: '$b');
      }
    });
  });

  group('geometry and timing contracts', () {
    test('an action toast dwells long enough to be acted on', () {
      // Read → realise it is wrong → reach. Platform guidance puts actionable
      // toasts in the 4-10s band; the plain 3.2s dwell is inside none of it.
      expect(UgamSnackbar.actionDuration, greaterThan(UgamMotion.snackbar));
      expect(
        UgamSnackbar.actionDuration.inMilliseconds,
        inInclusiveRange(4000, 10000),
      );
    });

    test('dock clearance actually clears the dock', () {
      // The dock's own cells are floored at the 44pt tap minimum; anything
      // less than that plus its padding puts the toast on top of them.
      expect(
        UgamSnackbar.dockClearance,
        greaterThanOrEqualTo(44 + UgamSpacing.lg + UgamSpacing.md),
      );
    });
  });

  group('UgamSnackAction.undo', () {
    testWidgets('is translated, glyphed and wired', (tester) async {
      var fired = 0;
      final action = UgamSnackAction.undo(onUndo: () => fired++);

      // tr() renders raw keys in tests — asserting on them proves the keys are
      // the ones added to en/gu/hi rather than a hardcoded English string.
      expect(action.label, 'actions.undo');
      expect(action.semanticLabel, 'actions.undo_semantic');
      expect(action.icon, Icons.undo_rounded);

      await tester.pumpWidget(
        _host(
          SizedBox(
            width: 350,
            child: UgamSnackbar(message: 'Moved', action: action),
          ),
        ),
      );
      await tester.tap(find.byType(UgamTappable));
      await tester.pumpAndSettle();
      expect(fired, 1);
    });

    test('a caller-supplied semantic label wins', () {
      final action = UgamSnackAction.undo(
        onUndo: () {},
        semanticLabel: 'Undo collecting 550 from Priti Patel',
      );
      expect(action.semanticLabel, 'Undo collecting 550 from Priti Patel');
    });
  });
}
