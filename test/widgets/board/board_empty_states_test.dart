import 'dart:convert';
import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
// ignore: implementation_imports
import 'package:easy_localization/src/localization.dart';
// ignore: implementation_imports
import 'package:easy_localization/src/translations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:occubusbooking/design/components/ugam_button.dart';
import 'package:occubusbooking/models/board_lens.dart';
import 'package:occubusbooking/widgets/board/board_empty_states.dart';

/// Spec §13. The audit's finding was that this app's empty states name a
/// problem and offer no way out, and that "no data yet" and "genuinely zero"
/// render identically. Both are behavioural claims, so both are tested here:
///
///  * EVERY resolved state carries an action — enforced across the whole
///    decision table, not spot-checked.
///  * a missing prerequisite REPLACES the chart (and so must take the legend
///    with it); a genuine zero does NOT, because the chart is the evidence.
///  * the occupancy lens on an empty bus is not an empty state at all — the
///    grid of empty berths is the tool that fixes it.
///
/// Gujarati throughout: primary language, ~30% longer, so it is the one the
/// layouts have to survive.
void main() {
  Map<String, dynamic> load(String lang) =>
      jsonDecode(File('assets/translations/$lang.json').readAsStringSync())
          as Map<String, dynamic>;

  final en = load('en');
  final gu = load('gu');
  final hi = load('hi');

  setUpAll(() {
    // `main()` calls this; the resolver formats "14 Aug" in the app locale and
    // would otherwise fall back for want of month names.
    initializeDateFormatting();
    Localization.load(
      const Locale('gu'),
      translations: Translations(gu),
      ignorePluralRules: true,
    );
  });

  BoardBerth rider(
    String code, {
    double fare = 0,
    double paid = 0,
    String? stopId,
    String? groupId,
    BerthBoarding boarding = BerthBoarding.expected,
  }) => BoardBerth(
    code: code,
    isOccupied: true,
    occupantName: 'Ramesh $code',
    fareDue: fare,
    paid: paid,
    pickupStopId: stopId,
    pickupStopName: stopId == null ? null : 'Adajan',
    groupId: groupId,
    groupName: groupId == null ? null : 'Patel family',
    boarding: boarding,
  );

  const empty = BoardBerth(code: 'A9');

  // ───────────────────────────────────────────────────────────────────────
  // The decision table.
  // ───────────────────────────────────────────────────────────────────────

  group('nothing is claimed while the layout is still in flight', () {
    test('an unloaded bus resolves to no state at all', () {
      for (final lens in BoardLensId.values) {
        expect(
          resolveBoardEmptyState(
            lens: lens,
            facts: const BoardEmptyFacts(loaded: false, hasLayout: false),
          ),
          isNull,
          reason: '${lens.name} claimed "no seat plan" mid-load',
        );
      }
    });
  });

  group('no seat plan (spec §13)', () {
    test('every lens gets the same answer, with a way to create one', () {
      for (final lens in BoardLensId.values) {
        final state = resolveBoardEmptyState(
          lens: lens,
          facts: const BoardEmptyFacts(hasLayout: false),
        );
        expect(state, isNotNull, reason: lens.name);
        expect(state!.id, 'no_layout');
        expect(state.kind, BoardEmptyKind.missing);
        expect(state.action, BoardEmptyAction.createSeatPlan);
        expect(state.replacesChart, isTrue);
      }
    });

    test('a layout with zero berths is the same dead end', () {
      final state = resolveBoardEmptyState(
        lens: BoardLensId.money,
        facts: const BoardEmptyFacts(berths: []),
      );
      expect(state?.id, 'no_layout');
    });
  });

  group('occupancy is never empty while a plan exists', () {
    test('a bus with only empty berths still draws the chart', () {
      expect(
        resolveBoardEmptyState(
          lens: BoardLensId.occupancy,
          facts: const BoardEmptyFacts(berths: [empty, empty]),
        ),
        isNull,
        reason: 'the empty grid IS the tool that fixes an empty bus',
      );
    });

    test('but the other lenses say there is nobody to describe', () {
      for (final lens in const [
        BoardLensId.money,
        BoardLensId.pickup,
        BoardLensId.group,
        BoardLensId.boarding,
      ]) {
        final state = resolveBoardEmptyState(
          lens: lens,
          facts: const BoardEmptyFacts(berths: [empty]),
        );
        expect(state?.id, 'no_riders', reason: lens.name);
        expect(state?.action, BoardEmptyAction.placeRiders);
      }
    });
  });

  group('money lens', () {
    test('riders with no fare set asks for fares, not for ₹0 everywhere', () {
      final state = resolveBoardEmptyState(
        lens: BoardLensId.money,
        facts: BoardEmptyFacts(berths: [rider('A1'), rider('A2')]),
      );
      expect(state?.id, 'no_fares');
      expect(state?.kind, BoardEmptyKind.missing);
      expect(state?.action, BoardEmptyAction.setFares);
      expect(state?.replacesChart, isTrue);
    });

    test('partial pricing is NOT an empty state — the chart is truer', () {
      final state = resolveBoardEmptyState(
        lens: BoardLensId.money,
        facts: BoardEmptyFacts(
          berths: [rider('A1', fare: 1200), rider('A2')],
        ),
      );
      expect(state, isNull);
    });

    test('money still owed just draws the chart', () {
      final state = resolveBoardEmptyState(
        lens: BoardLensId.money,
        facts: BoardEmptyFacts(
          berths: [rider('A1', fare: 1200, paid: 400)],
        ),
      );
      expect(state, isNull);
    });

    test('everything collected is a GENUINE zero and keeps the chart', () {
      final state = resolveBoardEmptyState(
        lens: BoardLensId.money,
        facts: BoardEmptyFacts(
          berths: [
            rider('A1', fare: 1200, paid: 1200),
            rider('A2', fare: 800, paid: 800),
          ],
        ),
      );
      expect(state?.id, 'all_collected');
      expect(state?.kind, BoardEmptyKind.allClear);
      expect(state?.replacesChart, isFalse);
      expect(state?.action, BoardEmptyAction.reviewCollection);
    });

    test('the two ₹0 situations do not resolve to the same state', () {
      final noFares = resolveBoardEmptyState(
        lens: BoardLensId.money,
        facts: BoardEmptyFacts(berths: [rider('A1')]),
      );
      final allIn = resolveBoardEmptyState(
        lens: BoardLensId.money,
        facts: BoardEmptyFacts(berths: [rider('A1', fare: 500, paid: 500)]),
      );
      expect(noFares!.id, isNot(allIn!.id));
      expect(noFares.kind, isNot(allIn.kind));
      expect(noFares.replacesChart, isNot(allIn.replacesChart));
      expect(noFares.title, isNot(allIn.title));
    });

    test('over-collection does not re-open the round', () {
      final state = resolveBoardEmptyState(
        lens: BoardLensId.money,
        facts: BoardEmptyFacts(
          berths: [rider('A1', fare: 500, paid: 600)],
        ),
      );
      expect(state?.id, 'all_collected');
    });
  });

  group('boarding lens', () {
    test('before departure day it says when, and previews the headcount', () {
      final state = resolveBoardEmptyState(
        lens: BoardLensId.boarding,
        facts: BoardEmptyFacts(
          berths: [
            rider('A1', stopId: 's1'),
            rider('A2', stopId: 's1'),
            rider('A3', stopId: 's2'),
          ],
          daysUntilDeparture: 2,
          departureDate: DateTime(2026, 8, 14),
          locale: 'gu',
        ),
      );
      expect(state?.id, 'boarding_not_open');
      expect(state?.kind, BoardEmptyKind.notYet);
      expect(state?.replacesChart, isTrue);
      expect(state?.action, BoardEmptyAction.previewExpected);
      expect(state?.facts.length, 2);
      expect(state!.facts.first.value, '3');
      expect(state.facts.last.value, '2');
    });

    test('with no departure date it does not invent one', () {
      final state = resolveBoardEmptyState(
        lens: BoardLensId.boarding,
        facts: BoardEmptyFacts(
          berths: [rider('A1')],
          daysUntilDeparture: 3,
        ),
      );
      expect(state?.id, 'boarding_not_open');
      expect(state?.title, tr('board_empty.boarding_not_open_title_no_date'));
    });

    test('no stops recorded means no stop fact, but still a headcount', () {
      final state = resolveBoardEmptyState(
        lens: BoardLensId.boarding,
        facts: BoardEmptyFacts(
          berths: [rider('A1')],
          daysUntilDeparture: 1,
        ),
      );
      expect(state!.facts.length, 1);
      expect(state.facts.single.label, tr('board_empty.preview_expected'));
    });

    test('on the day, a part-boarded bus draws the chart', () {
      final state = resolveBoardEmptyState(
        lens: BoardLensId.boarding,
        facts: BoardEmptyFacts(
          berths: [
            rider('A1', boarding: BerthBoarding.boarded),
            rider('A2'),
          ],
          daysUntilDeparture: 0,
        ),
      );
      expect(state, isNull);
    });

    test('everyone aboard is a genuine zero, note over a live chart', () {
      final state = resolveBoardEmptyState(
        lens: BoardLensId.boarding,
        facts: BoardEmptyFacts(
          berths: [
            rider('A1', boarding: BerthBoarding.boarded),
            rider('A2', boarding: BerthBoarding.boarded),
          ],
          daysUntilDeparture: 0,
        ),
      );
      expect(state?.id, 'all_boarded');
      expect(state?.kind, BoardEmptyKind.allClear);
      expect(state?.replacesChart, isFalse);
    });
  });

  group('pickup and group lenses', () {
    test('no stops recorded offers the pickup-point manager', () {
      final state = resolveBoardEmptyState(
        lens: BoardLensId.pickup,
        facts: BoardEmptyFacts(berths: [rider('A1'), rider('A2')]),
      );
      expect(state?.id, 'no_stops');
      expect(state?.action, BoardEmptyAction.addPickupPoints);
      expect(state?.replacesChart, isTrue);
    });

    test('one stop is enough to colour by', () {
      final state = resolveBoardEmptyState(
        lens: BoardLensId.pickup,
        facts: BoardEmptyFacts(berths: [rider('A1', stopId: 's1')]),
      );
      expect(state, isNull);
    });

    test('no groups offers a way to make one', () {
      final state = resolveBoardEmptyState(
        lens: BoardLensId.group,
        facts: BoardEmptyFacts(berths: [rider('A1')]),
      );
      expect(state?.id, 'no_groups');
      expect(state?.action, BoardEmptyAction.createGroup);
    });

    test('an existing group draws the chart', () {
      final state = resolveBoardEmptyState(
        lens: BoardLensId.group,
        facts: BoardEmptyFacts(berths: [rider('A1', groupId: 'g1')]),
      );
      expect(state, isNull);
    });
  });

  group('the rule the file exists for', () {
    test('every reachable state names a title, a body AND an action', () {
      final scenarios = <BoardEmptyFacts>[
        const BoardEmptyFacts(hasLayout: false),
        const BoardEmptyFacts(berths: [empty]),
        BoardEmptyFacts(berths: [rider('A1')]),
        BoardEmptyFacts(berths: [rider('A1', fare: 900, paid: 900)]),
        BoardEmptyFacts(
          berths: [rider('A1', boarding: BerthBoarding.boarded)],
          daysUntilDeparture: 0,
        ),
        BoardEmptyFacts(
          berths: [rider('A1')],
          daysUntilDeparture: 4,
          departureDate: DateTime(2026, 8, 14),
        ),
      ];

      var seen = 0;
      for (final lens in BoardLensId.values) {
        for (final facts in scenarios) {
          final state = resolveBoardEmptyState(lens: lens, facts: facts);
          if (state == null) continue;
          seen++;
          expect(state.title.trim(), isNotEmpty, reason: state.id);
          expect(state.body.trim(), isNotEmpty, reason: state.id);
          expect(state.action.label.trim(), isNotEmpty, reason: state.id);
          expect(
            state.replacesChart,
            state.kind != BoardEmptyKind.allClear,
            reason: state.id,
          );
        }
      }
      expect(seen, greaterThan(10), reason: 'the table barely fired');
    });

    test('boardEmptyReplacesChart agrees with the resolved state', () {
      expect(
        boardEmptyReplacesChart(
          lens: BoardLensId.money,
          facts: BoardEmptyFacts(berths: [rider('A1')]),
        ),
        isTrue,
      );
      expect(
        boardEmptyReplacesChart(
          lens: BoardLensId.money,
          facts: BoardEmptyFacts(berths: [rider('A1', fare: 500, paid: 500)]),
        ),
        isFalse,
        reason: 'a genuine zero must keep the legend and the chart',
      );
      expect(
        boardEmptyReplacesChart(
          lens: BoardLensId.occupancy,
          facts: BoardEmptyFacts(berths: [rider('A1')]),
        ),
        isFalse,
      );
    });
  });

  // ───────────────────────────────────────────────────────────────────────
  // Widgets.
  // ───────────────────────────────────────────────────────────────────────

  Future<List<BoardEmptyAction>> pumpPanel(
    WidgetTester tester,
    BoardEmptyState state, {
    Brightness brightness = Brightness.dark,
  }) async {
    final fired = <BoardEmptyAction>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(brightness: brightness),
        home: Scaffold(
          body: BoardEmptyPanel(state: state, onAction: fired.add),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return fired;
  }

  group('BoardEmptyPanel', () {
    testWidgets('shows the kind, the message and a working way out', (
      tester,
    ) async {
      final state = resolveBoardEmptyState(
        lens: BoardLensId.money,
        facts: BoardEmptyFacts(berths: [rider('A1')]),
      )!;
      final fired = await pumpPanel(tester, state);

      expect(find.text(tr('board_empty.kind_missing')), findsOneWidget);
      expect(find.text(tr('board_empty.no_fares_title')), findsOneWidget);
      expect(find.text(tr('board_empty.no_fares_body')), findsOneWidget);
      expect(find.text(tr('board_empty.action_set_fares')), findsOneWidget);

      await tester.tap(find.text(tr('board_empty.action_set_fares')));
      expect(fired, [BoardEmptyAction.setFares]);
    });

    testWidgets('renders on Daylight as well as Midnight', (tester) async {
      final state = resolveBoardEmptyState(
        lens: BoardLensId.pickup,
        facts: BoardEmptyFacts(berths: [rider('A1')]),
      )!;
      await pumpPanel(tester, state, brightness: Brightness.light);
      expect(tester.takeException(), isNull);
      expect(find.text(tr('board_empty.no_stops_title')), findsOneWidget);
    });

    testWidgets('the boarding preview renders its numbers', (tester) async {
      final state = resolveBoardEmptyState(
        lens: BoardLensId.boarding,
        facts: BoardEmptyFacts(
          berths: [
            rider('A1', stopId: 's1'),
            rider('A2', stopId: 's2'),
          ],
          daysUntilDeparture: 2,
          departureDate: DateTime(2026, 8, 14),
          locale: 'gu',
        ),
      )!;
      await pumpPanel(tester, state);

      expect(find.text(tr('board_empty.kind_not_yet')), findsOneWidget);
      expect(find.text(tr('board_empty.preview_expected')), findsOneWidget);
      expect(find.text(tr('board_empty.preview_stops')), findsOneWidget);
      // Two riders, two distinct stops.
      expect(find.text('2'), findsNWidgets(2));
    });

    testWidgets('the action clears the 44pt touch minimum', (tester) async {
      final state = resolveBoardEmptyState(
        lens: BoardLensId.group,
        facts: BoardEmptyFacts(berths: [rider('A1')]),
      )!;
      await pumpPanel(tester, state);
      final size = tester.getSize(find.byType(UgamButton));
      expect(size.height, greaterThanOrEqualTo(44));
    });

    testWidgets('the message reads as one node to a screen reader', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final state = resolveBoardEmptyState(
        lens: BoardLensId.money,
        facts: BoardEmptyFacts(berths: [rider('A1')]),
      )!;
      await pumpPanel(tester, state);

      final node = tester.getSemantics(
        find.text(tr('board_empty.no_fares_title')),
      );
      expect(node.label, contains(tr('board_empty.no_fares_title')));
      expect(node.label, contains(tr('board_empty.no_fares_body')));
      handle.dispose();
    });

    testWidgets('survives a very narrow phone without overflowing', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320 * 3, 640 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);

      final state = resolveBoardEmptyState(
        lens: BoardLensId.boarding,
        facts: BoardEmptyFacts(
          berths: [rider('A1', stopId: 's1')],
          daysUntilDeparture: 2,
          departureDate: DateTime(2026, 8, 14),
          locale: 'gu',
        ),
      )!;
      await pumpPanel(tester, state);
      expect(tester.takeException(), isNull);
    });
  });

  group('BoardZeroNote', () {
    testWidgets('says the zero is the good kind and offers a next step', (
      tester,
    ) async {
      final state = resolveBoardEmptyState(
        lens: BoardLensId.money,
        facts: BoardEmptyFacts(
          berths: [rider('A1', fare: 500, paid: 500)],
        ),
      )!;
      final fired = <BoardEmptyAction>[];
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(brightness: Brightness.dark),
          home: Scaffold(
            body: BoardZeroNote(state: state, onAction: fired.add),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text(tr('board_empty.all_collected_title')), findsOneWidget);
      expect(find.text(state.body), findsOneWidget);
      await tester.tap(find.text(tr('board_empty.action_review_collection')));
      expect(fired, [BoardEmptyAction.reviewCollection]);
    });
  });

  group('BoardEmptyStates', () {
    Future<void> pumpWrapper(
      WidgetTester tester, {
      required BoardLensId lens,
      required BoardEmptyFacts facts,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(brightness: Brightness.dark),
          home: Scaffold(
            body: BoardEmptyStates(
              lens: lens,
              facts: facts,
              onAction: (_) {},
              child: const Text('THE CHART'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('draws the chart when there is nothing to report', (
      tester,
    ) async {
      await pumpWrapper(
        tester,
        lens: BoardLensId.money,
        facts: BoardEmptyFacts(berths: [rider('A1', fare: 900, paid: 100)]),
      );
      expect(find.text('THE CHART'), findsOneWidget);
      expect(find.byType(BoardEmptyPanel), findsNothing);
    });

    testWidgets('replaces the chart for a missing prerequisite', (
      tester,
    ) async {
      await pumpWrapper(
        tester,
        lens: BoardLensId.money,
        facts: BoardEmptyFacts(berths: [rider('A1')]),
      );
      expect(find.text('THE CHART'), findsNothing);
      expect(find.byType(BoardEmptyPanel), findsOneWidget);
    });

    testWidgets('keeps the chart under a genuine zero', (tester) async {
      await pumpWrapper(
        tester,
        lens: BoardLensId.money,
        facts: BoardEmptyFacts(berths: [rider('A1', fare: 500, paid: 500)]),
      );
      expect(find.text('THE CHART'), findsOneWidget);
      expect(find.byType(BoardZeroNote), findsOneWidget);
      expect(find.byType(BoardEmptyPanel), findsNothing);
    });
  });

  // ───────────────────────────────────────────────────────────────────────
  // i18n.
  // ───────────────────────────────────────────────────────────────────────

  group('i18n', () {
    Map<String, dynamic> block(Map<String, dynamic> doc) =>
        doc['board_empty'] as Map<String, dynamic>;

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

    test('every enum label and eyebrow resolves to real copy', () {
      for (final action in BoardEmptyAction.values) {
        expect(action.label, isNotEmpty);
        expect(action.label, isNot(contains('board_empty.')));
      }
      for (final kind in BoardEmptyKind.values) {
        expect(kind.eyebrow, isNot(contains('board_empty.')));
      }
    });
  });
}
