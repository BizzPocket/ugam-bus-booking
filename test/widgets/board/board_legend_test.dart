import 'dart:convert';
import 'dart:io';

// ignore: implementation_imports
import 'package:easy_localization/src/localization.dart';
// ignore: implementation_imports
import 'package:easy_localization/src/translations.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/board_lens.dart';
import 'package:occubusbooking/widgets/board/board_legend.dart';

/// The legend is the Board's filter (spec §5), so it is tested as a control and
/// not as decoration:
///
///  * it must refuse to draw a key over a bus that has no berths, and must drop
///    rows no berth matches — today's chart shows ten colour codes above an
///    empty bus (spec §13);
///  * a tap must report the row's id so the controller can dim everything else;
///  * the ACTIVE row must show its own state, because dim-to-30% on a chart the
///    handler may not be looking at is not an indication (spec §11);
///  * every row must be a 44pt target and must carry its glyph, not only its
///    colour.
///
/// Gujarati throughout: it is the primary language and the longest, so it is
/// the one the wrap has to survive.
void main() {
  Map<String, dynamic> load(String lang) =>
      jsonDecode(File('assets/translations/$lang.json').readAsStringSync())
          as Map<String, dynamic>;

  final en = load('en');
  final gu = load('gu');
  final hi = load('hi');

  setUpAll(() {
    Localization.load(
      const Locale('gu'),
      translations: Translations(gu),
      ignorePluralRules: true,
    );
  });

  const seated = BoardBerth(
    code: 'A1',
    isOccupied: true,
    occupantName: 'Ramesh Patel',
  );
  const lady = BoardBerth(
    code: 'A2',
    isOccupied: true,
    occupantName: 'Priti Patel',
    isLadies: true,
  );
  const vacant = BoardBerth(code: 'A3');

  Future<List<String>> pump(
    WidgetTester tester, {
    required BoardLens lens,
    required List<BoardBerth> berths,
    String? activeId,
  }) async {
    final taps = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BoardLegend(
            lens: lens,
            berths: berths,
            activeId: activeId,
            onToggle: taps.add,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return taps;
  }

  group('never a key over an empty bus (spec §13)', () {
    testWidgets('no berths renders nothing at all', (tester) async {
      await pump(tester, lens: const OccupancyLens(), berths: const []);
      expect(find.byType(Text), findsNothing);
      expect(
        tester.getSize(find.byType(BoardLegend)),
        Size.zero,
        reason: 'an empty bus must not even reserve space for a key',
      );
    });

    testWidgets('rows no berth matches are dropped', (tester) async {
      // A full bus with no ladies aboard: two of the occupancy lens's three
      // rows are real, the third would filter to nothing.
      await pump(
        tester,
        lens: const OccupancyLens(),
        berths: const [seated, vacant],
      );
      expect(find.text(tr('board_lens.state_occupied')), findsOneWidget);
      expect(find.text(tr('board_lens.state_empty')), findsOneWidget);
      expect(find.text(tr('board_lens.state_ladies')), findsNothing);
    });

    testWidgets('a full three-row key renders when all three exist', (
      tester,
    ) async {
      await pump(
        tester,
        lens: const OccupancyLens(),
        berths: const [seated, lady, vacant],
      );
      expect(find.text(tr('board_lens.state_occupied')), findsOneWidget);
      expect(find.text(tr('board_lens.state_ladies')), findsOneWidget);
      expect(find.text(tr('board_lens.state_empty')), findsOneWidget);
    });
  });

  testWidgets('renders on Midnight as well as Daylight', (tester) async {
    // Dark is the app's primary mode, and the swatches are palette colours
    // resolved per theme — this would catch a key that only exists in light.
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(brightness: Brightness.dark),
        home: Scaffold(
          body: BoardLegend(
            lens: const OccupancyLens(),
            berths: const [seated, lady, vacant],
            activeId: 'ladies',
            onToggle: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text(tr('board_lens.state_ladies')), findsOneWidget);
    expect(find.byIcon(Icons.close_rounded), findsOneWidget);
  });

  group('the legend is the filter (spec §5)', () {
    testWidgets('tapping a swatch reports its row id', (tester) async {
      final taps = await pump(
        tester,
        lens: const OccupancyLens(),
        berths: const [seated, lady, vacant],
      );
      await tester.tap(find.text(tr('board_lens.state_ladies')));
      expect(taps, ['ladies']);
    });

    testWidgets('tapping the ACTIVE swatch reports again, so it can clear', (
      tester,
    ) async {
      final taps = await pump(
        tester,
        lens: const OccupancyLens(),
        berths: const [seated, lady, vacant],
        activeId: 'ladies',
      );
      await tester.tap(find.text(tr('board_lens.state_ladies')));
      expect(taps, ['ladies']);
    });

    testWidgets('money rows carry the money lens ids', (tester) async {
      final taps = await pump(
        tester,
        lens: const MoneyLens(),
        berths: const [
          BoardBerth(code: 'B1', isOccupied: true, fareDue: 1000, paid: 1000),
          BoardBerth(code: 'B2', isOccupied: true, fareDue: 1000),
        ],
      );
      await tester.tap(find.text(tr('board_lens.state_due')));
      expect(taps, ['due']);
    });
  });

  group('the active row shows its own state (spec §11)', () {
    testWidgets('it announces as selected and offers a way to clear', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pump(
        tester,
        lens: const OccupancyLens(),
        berths: const [seated, lady, vacant],
        activeId: 'ladies',
      );

      final active = tester.getSemantics(
        find.text(tr('board_lens.state_ladies')),
      );
      expect(active, isSemantics(isSelected: true, isButton: true));
      expect(
        active.label,
        tr(
          'board_legend.a11y_clear',
          namedArgs: {'label': tr('board_lens.state_ladies')},
        ),
      );

      final idle = tester.getSemantics(
        find.text(tr('board_lens.state_occupied')),
      );
      expect(idle, isSemantics(isSelected: false));
      expect(
        idle.label,
        tr(
          'board_legend.a11y_filter',
          namedArgs: {'label': tr('board_lens.state_occupied')},
        ),
      );

      handle.dispose();
    });

    testWidgets('only the active row carries the clear mark', (tester) async {
      await pump(
        tester,
        lens: const OccupancyLens(),
        berths: const [seated, lady, vacant],
        activeId: 'ladies',
      );
      expect(find.byIcon(Icons.close_rounded), findsOneWidget);
    });

    testWidgets('with no filter on, nothing shows a clear mark', (
      tester,
    ) async {
      await pump(
        tester,
        lens: const OccupancyLens(),
        berths: const [seated, lady, vacant],
      );
      expect(find.byIcon(Icons.close_rounded), findsNothing);
    });

    testWidgets('a filter id this lens no longer has activates nothing', (
      tester,
    ) async {
      // The controller keeps the filter across a bus swipe; a coach with no
      // ladies must not end up with a phantom active row.
      await pump(
        tester,
        lens: const OccupancyLens(),
        berths: const [seated, vacant],
        activeId: 'ladies',
      );
      expect(find.byIcon(Icons.close_rounded), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('colour is never the only signal (spec §11)', () {
    testWidgets('each row shows the glyph the chart paints', (tester) async {
      await pump(
        tester,
        lens: const OccupancyLens(),
        berths: const [seated, lady, vacant],
      );
      expect(find.text('●'), findsOneWidget);
      expect(find.text('♀'), findsOneWidget);
      expect(find.text('—'), findsOneWidget);
    });

    testWidgets('the money key uses the money glyphs', (tester) async {
      await pump(
        tester,
        lens: const MoneyLens(),
        berths: const [
          BoardBerth(code: 'B1', isOccupied: true, fareDue: 1000, paid: 1000),
          BoardBerth(code: 'B2', isOccupied: true, fareDue: 1000, paid: 400),
          BoardBerth(code: 'B3', isOccupied: true, fareDue: 1000),
        ],
      );
      expect(find.text('✓'), findsOneWidget);
      expect(find.text('½'), findsOneWidget);
      expect(find.text('₹'), findsOneWidget);
    });
  });

  group('the five-tint cap renders honestly', () {
    /// Seven groups, so the lens keeps five and folds two into "other".
    List<BoardBerth> groupedBus() {
      final berths = <BoardBerth>[];
      for (var g = 1; g <= 7; g++) {
        // Descending sizes so the ranking is unambiguous.
        for (var i = 0; i < 8 - g; i++) {
          berths.add(
            BoardBerth(
              code: 'G$g-$i',
              isOccupied: true,
              groupId: 'g$g',
              groupName: 'Group $g',
            ),
          );
        }
      }
      return berths;
    }

    BoardLens groupLens(List<BoardBerth> berths) {
      final counts = <String, ({String label, int count})>{};
      for (final b in berths) {
        final id = b.groupId!;
        final seen = counts[id];
        counts[id] = (label: b.groupName!, count: (seen?.count ?? 0) + 1);
      }
      return GroupLens(
        BoardTintScale.fromSeeds([
          for (final e in counts.entries)
            BoardTintSeed(id: e.key, label: e.value.label, count: e.value.count),
        ]),
      );
    }

    testWidgets('five tints plus one "other" row, and no more', (tester) async {
      final berths = groupedBus();
      await pump(tester, lens: groupLens(berths), berths: berths);

      for (var g = 1; g <= 5; g++) {
        expect(find.text('Group $g'), findsOneWidget);
      }
      expect(find.text('Group 6'), findsNothing);
      expect(find.text('Group 7'), findsNothing);
      expect(
        find.text(tr('board_lens.other_groups', namedArgs: {'count': '2'})),
        findsOneWidget,
      );
      // A, B, C, D, E for the tints and + for the bucket — six non-colour marks
      // for six rows.
      for (final glyph in kTintGlyphs) {
        expect(find.text(glyph), findsOneWidget);
      }
      expect(find.text(kOtherGlyph), findsOneWidget);
    });

    testWidgets('the "other" bucket filters like any other row', (
      tester,
    ) async {
      final berths = groupedBus();
      final taps = await pump(tester, lens: groupLens(berths), berths: berths);
      await tester.tap(
        find.text(tr('board_lens.other_groups', namedArgs: {'count': '2'})),
      );
      expect(taps, ['other']);
    });

    testWidgets('six Gujarati rows wrap instead of overflowing', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final berths = groupedBus();
      await pump(tester, lens: groupLens(berths), berths: berths);
      expect(tester.takeException(), isNull);
      expect(
        tester.getSize(find.byType(BoardLegend)).width,
        lessThanOrEqualTo(320),
      );
    });
  });

  group('i18n', () {
    Map<String, dynamic> block(Map<String, dynamic> doc) =>
        doc['board_legend'] as Map<String, dynamic>;

    test('every key ships in all three languages', () {
      final keys = block(en).keys.toList();
      expect(keys, isNotEmpty);
      for (final k in keys) {
        expect(block(gu)[k], isA<String>(), reason: 'gu missing $k');
        expect(block(hi)[k], isA<String>(), reason: 'hi missing $k');
        expect((block(gu)[k] as String).trim(), isNotEmpty, reason: 'gu $k');
        expect((block(hi)[k] as String).trim(), isNotEmpty, reason: 'hi $k');
      }
    });

    test('nothing is the English string pasted across', () {
      for (final k in block(en).keys) {
        expect(block(gu)[k], isNot(block(en)[k]), reason: 'gu $k');
        expect(block(hi)[k], isNot(block(en)[k]), reason: 'hi $k');
        expect(block(gu)[k], isNot(block(hi)[k]), reason: '$k gu == hi');
      }
    });

    test('every placeholder survives translation', () {
      for (final k in block(en).keys) {
        final source = block(en)[k] as String;
        for (final token in RegExp(r'\{\w+\}').allMatches(source)) {
          final name = token.group(0)!;
          expect(block(gu)[k], contains(name), reason: 'gu $k lost $name');
          expect(block(hi)[k], contains(name), reason: 'hi $k lost $name');
        }
      }
    });
  });

  group('touch targets', () {
    testWidgets('every row clears 44pt', (tester) async {
      await pump(
        tester,
        lens: const OccupancyLens(),
        berths: const [seated, lady, vacant],
      );
      for (final key in const [
        'board_lens.state_occupied',
        'board_lens.state_ladies',
        'board_lens.state_empty',
      ]) {
        final box = tester.getSize(
          find
              .ancestor(
                of: find.text(tr(key)),
                matching: find.byType(ConstrainedBox),
              )
              .first,
        );
        expect(box.height, greaterThanOrEqualTo(44), reason: key);
      }
    });
  });
}
