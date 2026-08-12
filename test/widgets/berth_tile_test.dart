import 'dart:convert';
import 'dart:io';

// ignore: implementation_imports
import 'package:easy_localization/src/localization.dart';
// ignore: implementation_imports
import 'package:easy_localization/src/translations.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/controllers/board_controller.dart'
    show BoardDensity;
import 'package:occubusbooking/design/tokens.dart';
import 'package:occubusbooking/models/board_lens.dart';
import 'package:occubusbooking/widgets/board/berth_tile.dart';

/// The Board's berth tile is rendered up to 74 times on one screen and is the
/// only thing a handler actually touches, so the things that have to hold are:
///
///  * both densities render what spec §3 says they render — and comfortable
///    renders THE NAME, which is the entire reason the Board replaces a chart
///    you can only look at;
///  * every occupancy / money / boarding state paints a GLYPH, because spec §11
///    forbids colour being the only signal and a colourblind handler has to be
///    able to work a 74-berth chart;
///  * the semantic label is the lens's full sentence, never a bare berth code;
///  * multi-select is unmistakable from the amber "this is yours" state, in both
///    palettes;
///  * a compact tile — deliberately below the 44pt touch minimum — still catches
///    a tap that lands off its painted face;
///  * the haptics match spec §12's table exactly.
void main() {
  Map<String, dynamic> load(String lang) =>
      jsonDecode(File('assets/translations/$lang.json').readAsStringSync())
          as Map<String, dynamic>;

  final en = load('en');
  final gu = load('gu');
  final hi = load('hi');

  // Real translations off the real asset, so a missing key fails here instead
  // of tr() quietly echoing it back and the assertions passing on nonsense.
  setUpAll(() {
    Localization.load(
      const Locale('en'),
      translations: Translations(en),
      ignorePluralRules: true,
    );
  });

  /// An explicit [Theme] inside the app rather than `MaterialApp.theme`:
  /// MaterialApp wraps its theme in an `AnimatedTheme`, so flipping brightness
  /// between two pumps would leave the tile reading a half-lerped palette for
  /// the next 200ms and the Daylight assertions would silently test Midnight.
  Widget host(Widget child, {Brightness brightness = Brightness.dark}) =>
      MaterialApp(
        home: Theme(
          data: ThemeData(brightness: brightness),
          child: Scaffold(body: Center(child: child)),
        ),
      );

  /// Captures every `HapticFeedback.*` the frame fires.
  List<String> spyHaptics(WidgetTester tester) {
    final log = <String>[];
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'HapticFeedback.vibrate') {
        log.add(call.arguments as String);
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
    return log;
  }

  BoxDecoration faceOf(WidgetTester tester) =>
      tester.widget<DecoratedBox>(find.byKey(BerthTile.faceKey)).decoration
          as BoxDecoration;

  // ── Berths, one per state the tile has to survive ──────────────────────────

  const priti = BoardBerth(
    code: 'DL3',
    isOccupied: true,
    occupantName: 'Priti Patel',
    isLadies: true,
    fareDue: 1400,
    paid: 1400,
    pickupStopId: 's1',
    pickupStopName: 'Adajan',
    groupId: 'g1',
    groupName: 'Patel family',
    boarding: BerthBoarding.boarded,
    seatTypeLabel: 'Double sofa',
  );
  const ramesh = BoardBerth(
    code: 'SU1',
    isOccupied: true,
    occupantName: 'Ramesh Bhai',
    fareDue: 1400,
    paid: 0,
    seatTypeLabel: 'Single sofa upper',
  );
  const halfPaid = BoardBerth(
    code: 'SL2',
    isOccupied: true,
    occupantName: 'Kiran',
    fareDue: 1400,
    paid: 600,
  );
  const overPaid = BoardBerth(
    code: 'SL4',
    isOccupied: true,
    occupantName: 'Jayesh',
    fareDue: 1400,
    paid: 1500,
  );
  const comped = BoardBerth(code: 'SL5', isOccupied: true, occupantName: 'Baby');
  const anonymous = BoardBerth(code: 'ST9', isOccupied: true, fareDue: 900);
  const vacant = BoardBerth(code: 'ST7');
  const blocked = BoardBerth(code: 'ST8', isBlocked: true);
  const expected = BoardBerth(
    code: 'DU1',
    isOccupied: true,
    occupantName: 'Nita',
  );
  const noShow = BoardBerth(
    code: 'DU2',
    isOccupied: true,
    occupantName: 'Amit',
    boarding: BerthBoarding.noShow,
  );

  const occupancy = OccupancyLens();
  const money = MoneyLens();
  const boarding = BoardingLens();

  // ───────────────────────────────────────────────────────────────────────────
  group('density (spec §3)', () {
    testWidgets('compact shows code + glyph and NOT the name', (tester) async {
      await tester.pumpWidget(
        host(
          const BerthTile(
            berth: priti,
            lens: occupancy,
            density: BoardDensity.compact,
          ),
        ),
      );

      expect(find.text('DL3'), findsOneWidget);
      expect(find.text('♀'), findsOneWidget);
      expect(find.text('Priti Patel'), findsNothing);
    });

    testWidgets('comfortable shows code + glyph + the occupant name', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          const BerthTile(
            berth: priti,
            lens: occupancy,
            density: BoardDensity.comfortable,
          ),
        ),
      );

      expect(find.text('DL3'), findsOneWidget);
      expect(find.text('♀'), findsOneWidget);
      // The whole point of the Board over the chart it replaces.
      expect(find.text('Priti Patel'), findsOneWidget);
    });

    testWidgets('a comfortable tile clears the 44pt touch minimum', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          const BerthTile(
            berth: priti,
            lens: occupancy,
            density: BoardDensity.comfortable,
          ),
        ),
      );

      final face = tester.getSize(find.byKey(BerthTile.faceKey));
      expect(face.height, greaterThanOrEqualTo(44));
      expect(face.width, greaterThanOrEqualTo(44));
    });

    testWidgets('compact is deliberately under 44pt but its SLOT is bigger', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          const BerthTile(
            berth: priti,
            lens: occupancy,
            density: BoardDensity.compact,
          ),
        ),
      );

      final face = tester.getSize(find.byKey(BerthTile.faceKey));
      final slot = tester.getSize(find.byType(BerthTile));

      expect(face.height, lessThan(44), reason: 'compact is a reading size');
      expect(slot.height, face.height + BerthTileMetrics.hitInset * 2);
      expect(slot.width, face.width + BerthTileMetrics.hitInset * 2);
    });

    testWidgets('comfortable is taller than compact at the same width', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          const BerthTile(
            berth: priti,
            lens: occupancy,
            density: BoardDensity.compact,
          ),
        ),
      );
      final compact = tester.getSize(find.byKey(BerthTile.faceKey));

      await tester.pumpWidget(
        host(
          const BerthTile(
            berth: priti,
            lens: occupancy,
            density: BoardDensity.comfortable,
          ),
        ),
      );
      final comfortable = tester.getSize(find.byKey(BerthTile.faceKey));

      expect(comfortable.width, compact.width);
      expect(comfortable.height, greaterThan(compact.height));
    });

    testWidgets('a nameless occupant is labelled, not left blank', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          const BerthTile(
            berth: anonymous,
            lens: occupancy,
            density: BoardDensity.comfortable,
          ),
        ),
      );

      expect(find.text(en['board_berth']['unnamed'] as String), findsOneWidget);
    });

    testWidgets('an empty berth reads as empty on its second line', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          const BerthTile(
            berth: vacant,
            lens: occupancy,
            density: BoardDensity.comfortable,
          ),
        ),
      );

      expect(
        find.text(en['board_lens']['state_empty'] as String),
        findsOneWidget,
      );
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('layout survives the worst case it will actually meet', () {
    /// Gujarati is the PRIMARY language and runs ~30% longer than English, and
    /// the smallest phone the app supports takes [UgamScale] down to its 0.85
    /// floor. A tile that only fits an English name on a 390pt phone is a tile
    /// that overflows on the device this app is actually used on.
    const gujaratiBerth = BoardBerth(
      code: 'ST40',
      isOccupied: true,
      occupantName: 'પ્રીતિબેન રમેશભાઈ પટેલ',
      fareDue: 140000,
      paid: 0,
      seatTypeLabel: 'ડબલ સોફા નીચે',
    );

    void useSmallestPhone(WidgetTester tester) {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
    }

    for (final density in BoardDensity.values) {
      testWidgets('${density.name}: long Gujarati name + ₹1.4L on a 320pt '
          'phone does not overflow', (tester) async {
        useSmallestPhone(tester);

        await tester.pumpWidget(
          host(
            BerthTile(
              berth: gujaratiBerth,
              lens: money,
              density: density,
              isSelected: true,
              isCurrent: true,
            ),
          ),
        );

        // A RenderFlex overflow throws here rather than merely painting a
        // yellow-and-black bar, so this is a real assertion.
        expect(tester.takeException(), isNull);
        expect(find.text('₹1.4L'), findsOneWidget);
      });
    }

    testWidgets('the face never grows to fit its text', (tester) async {
      useSmallestPhone(tester);

      await tester.pumpWidget(
        host(
          const BerthTile(
            berth: gujaratiBerth,
            lens: money,
            density: BoardDensity.comfortable,
          ),
        ),
      );
      final long = tester.getSize(find.byKey(BerthTile.faceKey));

      await tester.pumpWidget(
        host(
          const BerthTile(
            berth: vacant,
            lens: money,
            density: BoardDensity.comfortable,
          ),
        ),
      );
      final short = tester.getSize(find.byKey(BerthTile.faceKey));

      // Every berth on a bus is the same footprint, whatever is written on it —
      // otherwise a lens switch reflows all 74 rows.
      expect(long, short);
      // …and it is still a legal touch target down here.
      expect(long.height, greaterThanOrEqualTo(44));
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('colour is never the only signal (spec §11)', () {
    /// Every state × every density has to put a glyph on the tile.
    Future<void> expectGlyph(
      WidgetTester tester, {
      required BoardBerth berth,
      required BoardLens lens,
      required String glyph,
    }) async {
      for (final density in BoardDensity.values) {
        await tester.pumpWidget(
          host(BerthTile(berth: berth, lens: lens, density: density)),
        );
        expect(
          find.text(glyph),
          findsOneWidget,
          reason: '${lens.id.name} / ${berth.code} / ${density.name}',
        );
      }
    }

    testWidgets('occupancy: seated ● ladies ♀ empty — blocked ✕', (
      tester,
    ) async {
      await expectGlyph(tester, berth: ramesh, lens: occupancy, glyph: '●');
      await expectGlyph(tester, berth: priti, lens: occupancy, glyph: '♀');
      await expectGlyph(tester, berth: vacant, lens: occupancy, glyph: '—');
      await expectGlyph(tester, berth: blocked, lens: occupancy, glyph: '✕');
    });

    testWidgets('money: paid ✓ half ½ due ₹amount change ↩ no-fare —', (
      tester,
    ) async {
      await expectGlyph(tester, berth: priti, lens: money, glyph: '✓');
      await expectGlyph(tester, berth: halfPaid, lens: money, glyph: '½');
      // Spec §11 lists the AMOUNT as the glyph for a due berth.
      await expectGlyph(tester, berth: ramesh, lens: money, glyph: '₹1.4K');
      await expectGlyph(tester, berth: overPaid, lens: money, glyph: '↩');
      await expectGlyph(tester, berth: comped, lens: money, glyph: '—');
      await expectGlyph(tester, berth: vacant, lens: money, glyph: '—');
      await expectGlyph(tester, berth: blocked, lens: money, glyph: '✕');
    });

    testWidgets('boarding: aboard ● expected ○ no-show ✕', (tester) async {
      await expectGlyph(tester, berth: priti, lens: boarding, glyph: '●');
      await expectGlyph(tester, berth: expected, lens: boarding, glyph: '○');
      await expectGlyph(tester, berth: noShow, lens: boarding, glyph: '✕');
      await expectGlyph(tester, berth: vacant, lens: boarding, glyph: '—');
    });

    testWidgets('the fill genuinely changes with state as well', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          const BerthTile(
            berth: priti,
            lens: money,
            density: BoardDensity.comfortable,
          ),
        ),
      );
      final paid = faceOf(tester).color;

      await tester.pumpWidget(
        host(
          const BerthTile(
            berth: ramesh,
            lens: money,
            density: BoardDensity.comfortable,
          ),
        ),
      );
      final due = faceOf(tester).color;

      expect(paid, UgamColors.dark.goodFill);
      expect(due, UgamColors.dark.dangerFill);
      expect(paid, isNot(due));
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('semantics (spec §11)', () {
    /// Pumps [tile], reads its one semantics node, and disposes the handle
    /// BEFORE returning.
    ///
    /// `flutter_test` verifies that no [SemanticsHandle] is live at the end of
    /// the test *body* — earlier than any `addTearDown` runs — so a leaked
    /// handle would replace every genuine failure in this group with a
    /// misleading "SemanticsHandle was active" error.
    Future<({SemanticsData data, int children})> semanticsOf(
      WidgetTester tester,
      Widget tile,
    ) async {
      final handle = tester.ensureSemantics();
      try {
        await tester.pumpWidget(host(tile));
        final node = tester.getSemantics(find.byType(BerthTile));
        return (data: node.getSemanticsData(), children: node.childrenCount);
      } finally {
        handle.dispose();
      }
    }

    testWidgets('reads the whole passenger, not just the berth code', (
      tester,
    ) async {
      final node = await semanticsOf(
        tester,
        const BerthTile(
          berth: priti,
          lens: money,
          density: BoardDensity.comfortable,
          onTap: _ignore,
        ),
      );

      // "DL3, Priti Patel, paid, double sofa, boarding at Adajan"
      final label = node.data.label;
      expect(label, contains('DL3'));
      expect(label, contains('Priti Patel'));
      expect(label, contains(en['board_lens']['state_paid'] as String));
      expect(label, contains('Double sofa'));
      expect(label, contains('Adajan'));
      expect(label, isNot('DL3'));
    });

    testWidgets('an empty berth still gets a sentence', (tester) async {
      final node = await semanticsOf(
        tester,
        const BerthTile(
          berth: vacant,
          lens: occupancy,
          density: BoardDensity.compact,
        ),
      );

      expect(node.data.label, contains('ST7'));
      expect(
        node.data.label,
        contains(en['board_lens']['state_empty'] as String),
      );
    });

    testWidgets('selection is announced, not just drawn', (tester) async {
      final node = await semanticsOf(
        tester,
        const BerthTile(
          berth: priti,
          lens: occupancy,
          density: BoardDensity.comfortable,
          isSelected: true,
          onTap: _ignore,
        ),
      );

      expect(node.data.label, contains(en['board_berth']['a11y_selected']));
      expect(node.data, isSemantics(isSelected: true, isButton: true));
    });

    testWidgets('the walk cursor is announced too', (tester) async {
      final node = await semanticsOf(
        tester,
        const BerthTile(
          berth: priti,
          lens: occupancy,
          density: BoardDensity.comfortable,
          isCurrent: true,
        ),
      );

      expect(node.data.label, contains(en['board_berth']['a11y_current']));
    });

    testWidgets('one merged node per berth, not one per Text', (tester) async {
      final node = await semanticsOf(
        tester,
        const BerthTile(
          berth: priti,
          lens: money,
          density: BoardDensity.comfortable,
          onTap: _ignore,
        ),
      );

      // A 74-berth chart cannot afford three nodes per tile.
      expect(node.children, 0);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('multi-select vs the amber "yours" state (spec §7)', () {
    testWidgets('selected draws a neutral ring and a check badge', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          const BerthTile(
            berth: ramesh,
            lens: occupancy,
            density: BoardDensity.comfortable,
            isSelected: true,
          ),
        ),
      );

      final border = faceOf(tester).border! as Border;
      expect(border.top.color, UgamColors.dark.action);
      expect(border.top.width, BerthTileMetrics.ringWidth);
      expect(find.byKey(BerthTile.selectionBadgeKey), findsOneWidget);
    });

    testWidgets('unselected has no badge and only a hairline', (tester) async {
      await tester.pumpWidget(
        host(
          const BerthTile(
            berth: ramesh,
            lens: occupancy,
            density: BoardDensity.comfortable,
          ),
        ),
      );

      final border = faceOf(tester).border! as Border;
      expect(border.top.color, UgamColors.dark.border);
      expect(border.top.width, BerthTileMetrics.borderWidth);
      expect(find.byKey(BerthTile.selectionBadgeKey), findsNothing);
    });

    testWidgets('the walk cursor is amber + a glow, and carries no badge', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          const BerthTile(
            berth: ramesh,
            lens: occupancy,
            density: BoardDensity.comfortable,
            isCurrent: true,
          ),
        ),
      );

      final decoration = faceOf(tester);
      expect((decoration.border! as Border).top.color, UgamColors.dark.accent);
      expect(decoration.boxShadow, isNotNull);
      expect(find.byKey(BerthTile.selectionBadgeKey), findsNothing);
    });

    testWidgets('the two states are never the same colour, in either theme', (
      tester,
    ) async {
      for (final entry in const <Brightness, UgamColorSet>{
        Brightness.dark: UgamColors.dark,
        Brightness.light: UgamColors.light,
      }.entries) {
        await tester.pumpWidget(
          host(
            const BerthTile(
              berth: ramesh,
              lens: occupancy,
              density: BoardDensity.comfortable,
              isSelected: true,
            ),
            brightness: entry.key,
          ),
        );
        final selected = (faceOf(tester).border! as Border).top.color;

        await tester.pumpWidget(
          host(
            const BerthTile(
              berth: ramesh,
              lens: occupancy,
              density: BoardDensity.comfortable,
              isCurrent: true,
            ),
            brightness: entry.key,
          ),
        );
        final current = (faceOf(tester).border! as Border).top.color;

        expect(selected, entry.value.action);
        expect(current, entry.value.accent);
        expect(
          selected,
          isNot(current),
          reason: 'confusable under ${entry.key.name}',
        );
      }
    });

    testWidgets('a live drag outranks both rings (spec §7)', (tester) async {
      await tester.pumpWidget(
        host(
          const BerthTile(
            berth: ramesh,
            lens: occupancy,
            density: BoardDensity.comfortable,
            isSelected: true,
            isCurrent: true,
            isDropTarget: true,
          ),
        ),
      );
      expect(
        (faceOf(tester).border! as Border).top.color,
        UgamColors.dark.good,
      );

      await tester.pumpWidget(
        host(
          const BerthTile(
            berth: ramesh,
            lens: occupancy,
            density: BoardDensity.comfortable,
            isSelected: true,
            isCurrent: true,
            isDropRejected: true,
          ),
        ),
      );
      expect(
        (faceOf(tester).border! as Border).top.color,
        UgamColors.dark.danger,
      );
    });

    testWidgets('selected AND on the cursor: selection ring wins, glow stays', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          const BerthTile(
            berth: ramesh,
            lens: occupancy,
            density: BoardDensity.comfortable,
            isSelected: true,
            isCurrent: true,
          ),
        ),
      );

      final decoration = faceOf(tester);
      expect((decoration.border! as Border).top.color, UgamColors.dark.action);
      expect(decoration.boxShadow, isNotNull);
      expect(find.byKey(BerthTile.selectionBadgeKey), findsOneWidget);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('dimming (spec §5 / §10)', () {
    testWidgets('a filtered-out berth fades to 30% of its own alpha', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          const BerthTile(
            berth: priti,
            lens: money,
            density: BoardDensity.comfortable,
          ),
        ),
      );
      final lit = faceOf(tester).color!;

      await tester.pumpWidget(
        host(
          const BerthTile(
            berth: priti,
            lens: money,
            density: BoardDensity.comfortable,
            isDimmed: true,
          ),
        ),
      );
      final dimmed = faceOf(tester).color!;

      expect(dimmed.a, closeTo(lit.a * kBerthDimAlpha, 0.001));
      // Hue is untouched — dimming is a fade, not a recolour.
      expect(dimmed.r, closeTo(lit.r, 0.001));
    });

    testWidgets('a selected berth keeps its ring while dimmed', (tester) async {
      await tester.pumpWidget(
        host(
          const BerthTile(
            berth: priti,
            lens: money,
            density: BoardDensity.comfortable,
            isSelected: true,
            isDimmed: true,
          ),
        ),
      );

      expect(
        (faceOf(tester).border! as Border).top.color,
        UgamColors.dark.action,
      );
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('gestures and haptics (spec §7 / §12)', () {
    testWidgets('tap fires selectionClick and hands back the berth', (
      tester,
    ) async {
      final log = spyHaptics(tester);
      final tapped = <BoardBerth>[];

      await tester.pumpWidget(
        host(
          BerthTile(
            berth: priti,
            lens: occupancy,
            density: BoardDensity.comfortable,
            onTap: tapped.add,
          ),
        ),
      );

      await tester.tap(find.byType(BerthTile));
      await tester.pumpAndSettle();

      expect(tapped.single.code, 'DL3');
      expect(log, ['HapticFeedbackType.selectionClick']);
    });

    testWidgets('long-press fires mediumImpact — the pick-up weight', (
      tester,
    ) async {
      final log = spyHaptics(tester);
      final held = <BoardBerth>[];

      await tester.pumpWidget(
        host(
          BerthTile(
            berth: priti,
            lens: occupancy,
            density: BoardDensity.comfortable,
            onLongPress: held.add,
          ),
        ),
      );

      await tester.longPress(find.byType(BerthTile));
      await tester.pumpAndSettle();

      expect(held.single.code, 'DL3');
      expect(log, contains('HapticFeedbackType.mediumImpact'));
      expect(log, isNot(contains('HapticFeedbackType.lightImpact')));
    });

    testWidgets('compact: a tap in the expanded margin still lands', (
      tester,
    ) async {
      final tapped = <BoardBerth>[];

      await tester.pumpWidget(
        host(
          BerthTile(
            berth: priti,
            lens: occupancy,
            density: BoardDensity.compact,
            onTap: tapped.add,
          ),
        ),
      );

      // Two logical pixels inside the SLOT's top-left corner — comfortably
      // outside the painted face, which is inset by BerthTileMetrics.hitInset.
      final slot = tester.getRect(find.byType(BerthTile));
      final face = tester.getRect(find.byKey(BerthTile.faceKey));
      final spot = slot.topLeft + const Offset(2, 2);
      expect(face.contains(spot), isFalse, reason: 'must be off the face');

      await tester.tapAt(spot);
      await tester.pumpAndSettle();

      expect(tapped.single.code, 'DL3');
    });

    testWidgets('a read-only tile renders inert and fires nothing', (
      tester,
    ) async {
      final log = spyHaptics(tester);

      await tester.pumpWidget(
        host(
          const BerthTile(
            berth: priti,
            lens: occupancy,
            density: BoardDensity.comfortable,
          ),
        ),
      );

      await tester.tap(find.byType(BerthTile), warnIfMissed: false);
      await tester.pumpAndSettle();

      expect(log, isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('an invalid drop is the double heavyImpact "no" pattern', (
      tester,
    ) async {
      final log = spyHaptics(tester);
      await tester.pumpWidget(host(const SizedBox.shrink()));

      final done = BerthHaptics.reject();
      await tester.pump(const Duration(milliseconds: 400));
      await done;

      expect(log, [
        'HapticFeedbackType.heavyImpact',
        'HapticFeedbackType.heavyImpact',
      ]);
    });

    testWidgets('the rest of the haptic table maps as spec §12 says', (
      tester,
    ) async {
      final log = spyHaptics(tester);
      await tester.pumpWidget(host(const SizedBox.shrink()));

      BerthHaptics.tap();
      BerthHaptics.pickUp();
      BerthHaptics.success();
      await tester.pump();

      expect(log, [
        'HapticFeedbackType.selectionClick',
        'HapticFeedbackType.mediumImpact',
        'HapticFeedbackType.lightImpact',
      ]);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('i18n', () {
    test('every board_berth key ships in en, gu and hi', () {
      const keys = ['unnamed', 'a11y_selected', 'a11y_current'];
      for (final lang in {'en': en, 'gu': gu, 'hi': hi}.entries) {
        final block = lang.value['board_berth'] as Map<String, dynamic>?;
        expect(block, isNotNull, reason: '${lang.key} has no board_berth');
        for (final key in keys) {
          final value = block![key];
          expect(value, isA<String>(), reason: '${lang.key}.$key');
          expect(
            (value as String).trim(),
            isNotEmpty,
            reason: '${lang.key}.$key',
          );
        }
      }
    });

    test('gu and hi are real translations, not the English pasted across', () {
      final enBlock = en['board_berth'] as Map<String, dynamic>;
      for (final other in {'gu': gu, 'hi': hi}.entries) {
        final block = other.value['board_berth'] as Map<String, dynamic>;
        for (final key in enBlock.keys) {
          expect(
            block[key],
            isNot(enBlock[key]),
            reason: '${other.key}.$key is still English',
          );
        }
      }
    });
  });
}

/// A shared, allocation-free callback: the tile takes
/// `ValueChanged<BoardBerth>` precisely so one function can serve all 74 tiles.
void _ignore(BoardBerth _) {}
