import 'dart:convert';
import 'dart:io';

// ignore: implementation_imports
import 'package:easy_localization/src/localization.dart';
// ignore: implementation_imports
import 'package:easy_localization/src/translations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/controllers/board_controller.dart';
import 'package:occubusbooking/models/board_lens.dart';
import 'package:occubusbooking/models/seat_layout.dart';
import 'package:occubusbooking/models/seat_type.dart';
import 'package:occubusbooking/utils/aisle_order.dart';
import 'package:occubusbooking/widgets/board/board_canvas.dart';
import 'package:occubusbooking/widgets/board/board_summary_strip.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The canvas is the Board, and everything hard about it is a consequence of a
/// coach being 36-74 berths. So the tests are about scale, not about pixels:
///
///  * the drawn order must equal the WALKING order, or "next outstanding" jumps
///    backwards across the screen (spec §4);
///  * the grid must fit across the phone in both orientations, because it only
///    scrolls one way;
///  * a scroll must never become a drag (spec §7) — the one failure mode that
///    would make the Board dangerous;
///  * the strip must not be inside the scrollable (spec §3);
///  * the legend filter and the search must dim the right berths (spec §5, §10).
void main() {
  Map<String, dynamic> load(String lang) =>
      jsonDecode(File('assets/translations/$lang.json').readAsStringSync())
          as Map<String, dynamic>;

  setUpAll(() {
    Localization.load(
      const Locale('gu'),
      translations: Translations(load('gu')),
      ignorePluralRules: true,
    );
  });

  setUp(() => SharedPreferences.setMockInitialValues({}));

  // ── Fixtures ──────────────────────────────────────────────────────────────

  /// A coach of [rows] full rows (single upper/lower on the left, double
  /// lower/upper on the right), optionally with a back bench that puts an
  /// upper + lower pair in the aisle column.
  BusLayout coach({int rows = 3, bool bench = false}) {
    final grid = <SeatCell>[];
    for (var r = 0; r < rows; r++) {
      grid.addAll([
        SeatCell(
          row: r,
          col: SeatGridCols.singleUpper,
          seatType: SeatType.singleSofa,
          position: SeatPosition.upper,
          seatId: 'SU${r + 1}',
        ),
        SeatCell(
          row: r,
          col: SeatGridCols.singleLower,
          seatType: SeatType.singleSofa,
          position: SeatPosition.lower,
          seatId: 'SL${r + 1}',
        ),
        SeatCell(
          row: r,
          col: SeatGridCols.doubleUpper,
          seatType: SeatType.doubleSofa,
          position: SeatPosition.upper,
          seatId: 'DU${r + 1}',
        ),
        SeatCell(
          row: r,
          col: SeatGridCols.doubleLower,
          seatType: SeatType.doubleSofa,
          position: SeatPosition.lower,
          seatId: 'DL${r + 1}',
        ),
      ]);
    }
    if (bench) {
      grid.addAll([
        SeatCell(
          row: rows,
          col: SeatGridCols.aisle,
          seatType: SeatType.doubleSofa,
          position: SeatPosition.upper,
          seatId: 'BU1',
        ),
        SeatCell(
          row: rows,
          col: SeatGridCols.aisle,
          seatType: SeatType.doubleSofa,
          position: SeatPosition.lower,
          seatId: 'BL1',
        ),
      ]);
    }
    return BusLayout(
      rows: rows + (bench ? 1 : 0),
      cols: SeatGridCols.count,
      grid: grid,
    );
  }

  /// Right-hand lanes only — an all-double minibus. Used to prove the walkway
  /// lane is dropped when there is nothing to sit between.
  BusLayout oneSided() => BusLayout(
    rows: 2,
    cols: SeatGridCols.count,
    grid: [
      for (var r = 0; r < 2; r++) ...[
        SeatCell(
          row: r,
          col: SeatGridCols.doubleUpper,
          seatType: SeatType.doubleSofa,
          position: SeatPosition.upper,
          seatId: 'DU${r + 1}',
        ),
        SeatCell(
          row: r,
          col: SeatGridCols.doubleLower,
          seatType: SeatType.doubleSofa,
          position: SeatPosition.lower,
          seatId: 'DL${r + 1}',
        ),
      ],
    ],
  );

  Map<String, BoardBerth> manifest(BusLayout layout, {int occupy = 0}) {
    final ids = AisleWalk.of(layout).seatIds;
    final out = <String, BoardBerth>{};
    for (var i = 0; i < ids.length; i++) {
      out[ids[i]] = BoardBerth(
        code: ids[i],
        isOccupied: i < occupy,
        occupantName: i < occupy ? 'Rider ${ids[i]}' : null,
        fareDue: i < occupy ? 1000 : 0,
      );
    }
    return out;
  }

  // ── Geometry: pure ────────────────────────────────────────────────────────

  group('lanes', () {
    test('sweep across the bus matches the drawn order', () {
      expect(boardLanes(coach()), const [
        BoardLane(SeatGridCols.singleUpper),
        BoardLane(SeatGridCols.singleLower),
        BoardLane(SeatGridCols.aisle),
        BoardLane(SeatGridCols.doubleLower),
        BoardLane(SeatGridCols.doubleUpper),
      ]);
    });

    test('a back bench splits the aisle into its upper and lower berth', () {
      expect(boardLanes(coach(bench: true)), const [
        BoardLane(SeatGridCols.singleUpper),
        BoardLane(SeatGridCols.singleLower),
        BoardLane(SeatGridCols.aisle, SeatPosition.upper),
        BoardLane(SeatGridCols.aisle, SeatPosition.lower),
        BoardLane(SeatGridCols.doubleLower),
        BoardLane(SeatGridCols.doubleUpper),
      ]);
    });

    test('a one-sided bus keeps no walkway lane to sit beside', () {
      expect(boardLanes(oneSided()), const [
        BoardLane(SeatGridCols.doubleLower),
        BoardLane(SeatGridCols.doubleUpper),
      ]);
    });

    test('no layout is no lanes and no rows', () {
      expect(boardLanes(null), isEmpty);
      expect(boardRows(null), isEmpty);
      expect(boardRows(coach(rows: 4)), [0, 1, 2, 3]);
    });
  });

  group('tile metrics', () {
    test('comfortable never resolves under the 44pt minimum', () {
      for (final landscape in [false, true]) {
        final m = BoardTileMetrics.resolve(
          density: BoardDensity.comfortable,
          landscape: landscape,
          crossExtent: 360,
          laneCount: 5,
        );
        expect(m.width, greaterThanOrEqualTo(44), reason: 'w $landscape');
        expect(m.height, greaterThanOrEqualTo(44), reason: 'h $landscape');
      }
    });

    test('compact is deliberately shorter than the touch minimum', () {
      final m = BoardTileMetrics.resolve(
        density: BoardDensity.compact,
        landscape: false,
        crossExtent: 360,
        laneCount: 5,
      );
      expect(m.rowExtent, 22);
      expect(m.height, lessThan(44));
    });

    test('the grid always fits across, even six lanes on a small phone', () {
      for (final lanes in [2, 5, 6]) {
        for (final density in BoardDensity.values) {
          const cross = 300.0;
          final m = BoardTileMetrics.resolve(
            density: density,
            landscape: false,
            crossExtent: cross,
            laneCount: lanes,
          );
          final used = lanes * (m.laneExtent + m.gap) - m.gap;
          expect(
            used,
            lessThanOrEqualTo(cross + 0.001),
            reason: '$lanes lanes, ${density.name}',
          );
        }
      }
    });

    test('landscape measures the same tile the other way round', () {
      const size = Size(68, 34);
      final portrait = BoardTileMetrics.fixed(size, landscape: false);
      final landscape = BoardTileMetrics.fixed(size, landscape: true);

      expect(portrait.laneExtent, 68);
      expect(portrait.rowExtent, 34);
      expect(landscape.laneExtent, 34);
      expect(landscape.rowExtent, 68);
      // Whatever the orientation, the tile paints at the size it asked for.
      expect(portrait.size, size);
      expect(landscape.size, size);
    });
  });

  group('grid geometry', () {
    BoardGridGeometry geometryFor(BusLayout layout, {bool landscape = false}) =>
        BoardGridGeometry.of(
          layout: layout,
          metrics: BoardTileMetrics.fixed(
            const Size(60, 40),
            landscape: landscape,
          ),
        );

    test('drawn order IS aisle-walking order', () {
      for (final bench in [false, true]) {
        for (final landscape in [false, true]) {
          final layout = coach(rows: 4, bench: bench);
          final drawn = geometryFor(layout, landscape: landscape).cells
              .map((c) => c.cell.seatId)
              .toList();
          expect(
            drawn,
            aisleOrder(layout).map((c) => c.seatId).toList(),
            reason: 'bench: $bench, landscape: $landscape',
          );
        }
      }
    });

    test('portrait runs rows down the screen, landscape runs them across', () {
      // Twelve rows — a real coach, not the four the mockups showed.
      final portrait = geometryFor(coach(rows: 12));
      final landscape = geometryFor(coach(rows: 12), landscape: true);

      final pRow0 = portrait.rectOf('SU1')!;
      final pRow1 = portrait.rectOf('SU2')!;
      expect(pRow1.top, greaterThan(pRow0.top));
      expect(pRow1.left, pRow0.left);

      final lRow0 = landscape.rectOf('SU1')!;
      final lRow1 = landscape.rectOf('SU2')!;
      expect(lRow1.left, greaterThan(lRow0.left));
      expect(lRow1.top, lRow0.top);

      // A coach is long and narrow; rotated it gets wide and short.
      expect(portrait.size.height, greaterThan(portrait.size.width));
      expect(landscape.size.width, greaterThan(landscape.size.height));
    });

    test('a tap in the gap lands on the nearer berth', () {
      final g = geometryFor(coach());
      final su1 = g.rectOf('SU1')!;
      final sl1 = g.rectOf('SL1')!;

      expect(g.nearest(su1.center)!.seatId, 'SU1');
      // Just inside the SL1 side of the seam between the two.
      final seam = Offset((su1.right + sl1.left) / 2 + 1, su1.center.dy);
      expect(g.nearest(seam)!.seatId, 'SL1');
      // Far outside the chart is nobody, not "the closest berth anywhere".
      expect(g.nearest(const Offset(-500, -500)), isNull);
    });

    test('reveal centres a berth and clamps at both ends', () {
      final g = geometryFor(coach(rows: 20));
      const viewport = 400.0;

      // The frontmost berth cannot be centred without scrolling backwards.
      expect(g.offsetToCentre('SU1', viewport), 0);

      final middle = g.offsetToCentre('SU10', viewport)!;
      expect(middle, greaterThan(0));
      expect(middle + viewport / 2, closeTo(g.rectOf('SU10')!.center.dy, 0.01));

      // The last berth clamps to the end of the content.
      final last = g.offsetToCentre('DU20', viewport)!;
      expect(last, closeTo(g.scrollExtent - viewport, 0.01));

      expect(g.offsetToCentre('NOPE', viewport), isNull);
    });

    test('the reveal and the anchor agree, padding included', () {
      final g = geometryFor(coach(rows: 20));
      const viewport = 400.0;
      const pad = 12.0;

      final offset = g.offsetToCentre(
        'SL9',
        viewport,
        leading: pad,
        trailing: pad,
      )!;
      expect(g.centredBerth(offset, viewport, leading: pad), 'SL9');
    });

    test('the anchor breaks a row-wide tie toward the aisle', () {
      // Every berth in a row sits at the same place along the scrolling axis,
      // so four to six of them tie. The winner must be decided by geometry —
      // the lane nearest the middle — and not by the order the grid happens to
      // be iterated in, or the anchor flips between two berths of one row on
      // successive scroll stops and the density restore stops being
      // reproducible.
      final g = geometryFor(coach(rows: 20));
      const viewport = 400.0;

      final offset = g.offsetToCentre('SU9', viewport)!;
      final anchor = g.centredBerth(offset, viewport)!;

      // SU / SL / aisle / DL / DU: the two inner lanes are equidistant from the
      // middle, and either is a legitimate answer — but it must be one of them,
      // and it must round-trip to the same offset the reveal used.
      expect(anchor, anyOf('SL9', 'DL9'));
      expect(g.offsetToCentre(anchor, viewport), closeTo(offset, 0.01));
    });
  });

  group('berth lookup', () {
    test('a cell with no manifest entry is an honest empty berth', () {
      const cell = SeatCell(
        row: 0,
        col: SeatGridCols.singleUpper,
        seatType: SeatType.singleSofa,
        position: SeatPosition.upper,
        seatId: 'SU1',
      );
      final berth = boardBerthFor(cell, const {});

      expect(berth.code, 'SU1');
      expect(berth.isOccupied, isFalse);
      expect(berth.seatTypeLabel, cell.typeLabel);
    });

    test('a held-back cell is blocked, not empty', () {
      const cell = SeatCell(
        row: 0,
        col: SeatGridCols.singleUpper,
        seatType: SeatType.singleSofa,
        position: SeatPosition.upper,
        seatId: 'SU1',
        reserved: true,
      );
      expect(boardBerthFor(cell, const {}).isBlocked, isTrue);
    });

    test('the walk predicate reads the same berths the canvas paints', () {
      final layout = coach(rows: 2);
      final berths = manifest(layout, occupy: 3);
      final needs = boardNeedsAction(const OccupancyLens(), berths);
      final walk = AisleWalk.of(layout);

      // Eight berths, three of them taken: five empty ones left to fill.
      expect(walk.count(needs), 5);
      expect(walk.firstMatching(needs)!.seatId, walk.seatIds[3]);
    });
  });

  // ── The widget ────────────────────────────────────────────────────────────

  group('the canvas', () {
    late BoardController controller;
    late List<BoardBerthSlot> slots;
    late List<BoardBerthSlot> tapped;
    late List<BoardBerthSlot> held;

    setUp(() {
      controller = BoardController();
      slots = [];
      tapped = [];
      held = [];
    });

    BoardBerthSlot slotFor(String code) =>
        slots.lastWhere((s) => s.berth.code == code);

    Widget tile(BuildContext context, BoardBerthSlot slot) {
      slots.add(slot);
      return ColoredBox(
        color: slot.paint.fill,
        child: Center(
          child: Text(
            slot.berth.code,
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.clip,
          ),
        ),
      );
    }

    Future<void> pump(
      WidgetTester tester, {
      List<BoardBusPage>? buses,
      BusLayout? layout,
      int occupy = 0,
      bool Function(BoardBerthSlot)? canDrag,
      bool Function(BoardDragPayload, BoardBerthSlot)? canDrop,
      void Function(BoardDragPayload, BoardBerthSlot)? onDrop,
      void Function(BoardDragPayload, BoardBerthSlot)? onInvalidDrop,
      Size view = const Size(390, 844),
      bool reduceMotion = false,
    }) async {
      tester.view.physicalSize = view * 3;
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);

      final plan = layout ?? coach();
      final pages =
          buses ??
          [
            BoardBusPage(
              busId: 'bus-1',
              layout: plan,
              berths: manifest(plan, occupy: occupy),
            ),
          ];

      final canvas = BoardCanvas(
        controller: controller,
        buses: pages,
        berthTileBuilder: tile,
        onBerthTap: tapped.add,
        onBerthLongPress: held.add,
        canDragBerth: canDrag,
        canDrop: canDrop,
        onDrop: onDrop,
        onInvalidDrop: onInvalidDrop,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => reduceMotion
                  // Copied from the real one so the view size survives.
                  ? MediaQuery(
                      data: MediaQuery.of(
                        context,
                      ).copyWith(disableAnimations: true),
                      child: canvas,
                    )
                  : canvas,
            ),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('draws one tile per berth', (tester) async {
      await pump(tester, layout: coach(rows: 3, bench: true));

      final codes = slots.map((s) => s.berth.code).toSet();
      expect(codes.length, 14); // 3 rows x 4 + the two bench berths
      expect(find.text('SU1'), findsOneWidget);
      expect(find.text('BL1'), findsOneWidget);
    });

    testWidgets('the summary strip is not inside the scrollable', (
      tester,
    ) async {
      await pump(tester, occupy: 4);

      expect(find.byType(BoardSummaryStrip), findsOneWidget);
      expect(
        find.ancestor(
          of: find.byType(BoardSummaryStrip),
          matching: find.byType(Scrollable),
        ),
        findsNothing,
        reason: 'the number must never scroll away (spec §3)',
      );
    });

    testWidgets('the strip shows the active lens metric', (tester) async {
      await pump(tester, occupy: 4);
      // Occupancy lens on a 12-berth coach with four riders.
      expect(find.text('4/12'), findsOneWidget);
    });

    testWidgets('a tap opens the sheet and parks the walk', (tester) async {
      await pump(tester, occupy: 12);

      await tester.tap(find.text('SL2'));
      await tester.pump();

      expect(tapped.single.berth.code, 'SL2');
      expect(controller.cursor.value, 'SL2');
    });

    testWidgets('long-press starts multi-select and the next tap adds to it', (
      tester,
    ) async {
      await pump(tester, occupy: 12);

      await tester.longPress(find.text('SU1'));
      await tester.pump();
      expect(controller.isMultiSelecting, isTrue);
      expect(controller.selection, {'SU1'});

      await tester.tap(find.text('SL1'));
      await tester.pump();

      expect(controller.selection, {'SU1', 'SL1'});
      expect(tapped, isEmpty, reason: 'a tap in select mode selects, not opens');
    });

    testWidgets('a legend swatch dims every berth it does not select', (
      tester,
    ) async {
      await pump(tester, occupy: 4);

      controller.toggleLegendFilter('empty');
      await tester.pump();

      expect(slotFor('SU1').isDimmed, isTrue, reason: 'occupied, filtered out');
      expect(slotFor('DU3').isDimmed, isFalse, reason: 'empty, kept lit');

      controller.clearLegendFilter();
      await tester.pump();
      expect(slotFor('SU1').isDimmed, isFalse);
    });

    testWidgets('search highlights one berth and dims the rest', (
      tester,
    ) async {
      await pump(tester, occupy: 12);

      controller.setSearch('SL2');
      await tester.pump();

      expect(slotFor('SL2').isSearchHit, isTrue);
      expect(slotFor('SL2').isDimmed, isFalse);
      expect(slotFor('SU1').isSearchHit, isFalse);
      expect(slotFor('SU1').isDimmed, isTrue);
    });

    testWidgets('the walk cursor is marked for the tile to ring', (
      tester,
    ) async {
      await pump(tester, occupy: 12);

      controller.setCursor('DL2');
      await tester.pump();

      expect(slotFor('DL2').isCursor, isTrue);
      expect(slotFor('DL1').isCursor, isFalse);
    });

    testWidgets('a bus with no seat plan says so and offers a way out', (
      tester,
    ) async {
      await pump(
        tester,
        buses: const [BoardBusPage(busId: 'bus-1')],
      );

      expect(find.text('આ બસનો સીટ પ્લાન હજી બન્યો નથી'), findsOneWidget);
    });

    testWidgets('multi-bus is a swipe, and the page indicator follows', (
      tester,
    ) async {
      final a = coach(rows: 2);
      final b = coach(rows: 3);
      await pump(
        tester,
        buses: [
          BoardBusPage(busId: 'a', layout: a, berths: manifest(a)),
          BoardBusPage(busId: 'b', layout: b, berths: manifest(b)),
        ],
      );

      expect(find.byType(PageView), findsOneWidget);
      expect(controller.busCount.value, 2);

      await tester.fling(find.byType(PageView), const Offset(-400, 0), 1000);
      await tester.pumpAndSettle();

      expect(controller.busIndex.value, 1);
      // The walk follows the bus you are looking at, or "next outstanding"
      // would advance through a coach that is not on screen.
      expect(controller.walk.value.length, 12);
    });

    testWidgets('density switches without losing the berth being read', (
      tester,
    ) async {
      await pump(tester, layout: coach(rows: 20), occupy: 10);

      expect(controller.isCompact, isTrue, reason: '80 berths opens compact');
      final compactHeight = slotFor('SU1').size.height;

      controller.setDensity(BoardDensity.comfortable);
      await tester.pump();
      await tester.pump();

      expect(slotFor('SU1').size.height, greaterThan(compactHeight));
      expect(tester.takeException(), isNull);
    });

    testWidgets('landscape lays the coach out nose-left', (tester) async {
      await pump(
        tester,
        layout: coach(rows: 12),
        view: const Size(844, 390),
      );

      final scroll = tester.widget<SingleChildScrollView>(
        find.byType(SingleChildScrollView),
      );
      expect(scroll.scrollDirection, Axis.horizontal);
    });

    // ── The gesture that must not misfire ──────────────────────────────────

    testWidgets('scrolling the chart never moves a passenger', (tester) async {
      final drops = <String>[];
      await pump(
        tester,
        layout: coach(rows: 20),
        occupy: 80,
        canDrag: (_) => true,
        canDrop: (_, _) => true,
        onDrop: (payload, target) =>
            drops.add('${payload.fromSeatId}->${target.seatId}'),
      );

      // A finger that moves straight away is scrolling, not dragging: the
      // delayed recognizer rejects before it ever arms.
      final gesture = await tester.startGesture(
        tester.getCenter(find.text('SU1')),
      );
      await tester.pump(const Duration(milliseconds: 20));
      await gesture.moveBy(const Offset(0, -160));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      expect(drops, isEmpty);
      expect(controller.isMultiSelecting, isFalse);
      expect(tapped, isEmpty);
    });

    testWidgets('a hold that goes nowhere selects instead of moving', (
      tester,
    ) async {
      final drops = <String>[];
      await pump(
        tester,
        occupy: 12,
        canDrag: (_) => true,
        canDrop: (_, _) => true,
        onDrop: (payload, target) =>
            drops.add('${payload.fromSeatId}->${target.seatId}'),
      );

      final gesture = await tester.startGesture(
        tester.getCenter(find.text('SU1')),
      );
      await tester.pump(kBoardDragHold + const Duration(milliseconds: 40));
      await gesture.moveBy(const Offset(2, 2));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      expect(drops, isEmpty);
      expect(controller.selection, {'SU1'});
    });

    testWidgets('a hold that travels moves the passenger', (tester) async {
      final drops = <String>[];
      await pump(
        tester,
        occupy: 4,
        canDrag: (slot) => slot.berth.isOccupied,
        canDrop: (_, target) => !target.berth.isOccupied,
        onDrop: (payload, target) =>
            drops.add('${payload.fromSeatId}->${target.seatId}'),
      );

      final from = tester.getCenter(find.text('SU1'));
      final to = tester.getCenter(find.text('DU3'));
      final gesture = await tester.startGesture(from);
      await tester.pump(kBoardDragHold + const Duration(milliseconds: 40));
      await gesture.moveTo(to);
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      expect(drops, ['SU1->DU3']);
      expect(
        controller.isMultiSelecting,
        isFalse,
        reason: 'a real drag is not a long-press',
      );
    });

    testWidgets('a refused drop is reported, never silent', (tester) async {
      final refused = <String>[];
      await pump(
        tester,
        occupy: 12,
        canDrag: (_) => true,
        canDrop: (_, target) => !target.berth.isOccupied,
        onDrop: (_, _) {},
        onInvalidDrop: (payload, target) =>
            refused.add('${payload.fromSeatId}->${target.seatId}'),
      );

      final gesture = await tester.startGesture(
        tester.getCenter(find.text('SU1')),
      );
      await tester.pump(kBoardDragHold + const Duration(milliseconds: 40));
      await gesture.moveTo(tester.getCenter(find.text('SL1')));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      expect(refused, ['SU1->SL1']);
    });

    testWidgets('a settled drag announces one long-press, not two', (
      tester,
    ) async {
      // Flutter fires `onDragEnd` for every finished drag AND
      // `onDraggableCanceled` for a refused one. Listening to both settles a
      // cancelled pick-up twice, and a settle under the travel threshold IS the
      // long-press — so the bulk-action bar would be told about a gesture the
      // handler made once.
      await pump(
        tester,
        occupy: 12,
        canDrag: (_) => true,
        canDrop: (_, _) => true,
        onDrop: (_, _) {},
      );

      final gesture = await tester.startGesture(
        tester.getCenter(find.text('SU1')),
      );
      await tester.pump(kBoardDragHold + const Duration(milliseconds: 40));
      await gesture.up();
      await tester.pumpAndSettle();

      expect(held.map((s) => s.berth.code).toList(), ['SU1']);
      expect(controller.selection, {'SU1'});
    });

    // ── Compact mode: below the touch minimum by design (spec §3) ───────────

    testWidgets('a compact tap in the gutter lands on the nearest berth', (
      tester,
    ) async {
      await pump(tester, layout: coach(rows: 20), occupy: 80);
      expect(controller.isCompact, isTrue);

      final su1 = tester.getCenter(find.text('SU1'));
      final sl1 = tester.getCenter(find.text('SL1'));
      // Dead space between two ~22pt tiles, biased a hair toward SU1.
      await tester.tapAt(Offset((su1.dx + sl1.dx) / 2 - 1, su1.dy));
      await tester.pump();

      expect(tapped.map((s) => s.berth.code).toList(), ['SU1']);
      expect(controller.cursor.value, 'SU1');
    });

    testWidgets('a compact tap on a tile still fires exactly once', (
      tester,
    ) async {
      // The gap-catcher sits UNDER the tiles and is translucent, so both are in
      // the hit path. If it did not lose the arena the handler would open one
      // sheet and immediately open another.
      await pump(tester, layout: coach(rows: 20), occupy: 80);

      await tester.tap(find.text('SL2'));
      await tester.pump();

      expect(tapped.map((s) => s.berth.code).toList(), ['SL2']);
    });

    // ── Search reveal (spec §10) ────────────────────────────────────────────

    testWidgets('the first match is scrolled into view after the pause', (
      tester,
    ) async {
      // 40 rows: a coach taller than the phone, or there is nothing to scroll
      // and the test proves nothing.
      await pump(tester, layout: coach(rows: 40), occupy: 160);
      final position = tester
          .state<ScrollableState>(find.byType(Scrollable))
          .position;
      expect(position.maxScrollExtent, greaterThan(0));
      expect(position.pixels, 0);

      controller.setSearch('DU40');
      await tester.pump();
      // Highlighting is immediate; the scroll waits for the typing to stop.
      expect(position.pixels, 0);

      await tester.pump(kBoardSearchRevealDelay + const Duration(milliseconds: 20));
      await tester.pump(const Duration(milliseconds: 400));

      expect(position.pixels, greaterThan(0));
      // No pumpAndSettle anywhere near a search: the hit pulses forever by
      // design, and settling would wait for an animation that never ends.
    });

    testWidgets('reduced motion turns the reveal into an instant jump', (
      tester,
    ) async {
      // Spec §11: the pulse-on-search and the auto-advance scroll become
      // instant jumps. A handler who has asked the OS to stop animating must
      // not get a 300ms slide every time the collection round advances.
      await pump(
        tester,
        layout: coach(rows: 40),
        occupy: 160,
        reduceMotion: true,
      );
      final position = tester
          .state<ScrollableState>(find.byType(Scrollable))
          .position;

      controller.setSearch('DU40');
      await tester.pump();
      await tester.pump(
        kBoardSearchRevealDelay + const Duration(milliseconds: 20),
      );

      final jumped = position.pixels;
      expect(jumped, greaterThan(0), reason: 'already there, in one frame');

      await tester.pump(const Duration(milliseconds: 400));
      expect(position.pixels, jumped, reason: 'nothing left to animate');

      // And the hit is not pulsing: under normal motion this would spin until
      // the 2s cap, because the search pulse repeats for as long as it matches.
      await tester.pumpAndSettle(
        const Duration(milliseconds: 50),
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 2),
      );
    });

    testWidgets('a search abandoned mid-type leaves no timer behind', (
      tester,
    ) async {
      await pump(tester, layout: coach(rows: 20), occupy: 80);

      controller.setSearch('DU19');
      await tester.pump();
      // Torn down inside the quiet period. A pending reveal would fire at a
      // dead widget, and the test binding fails outright on the leaked timer.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(kBoardSearchRevealDelay * 3);

      expect(tester.takeException(), isNull);
    });
  });
}
