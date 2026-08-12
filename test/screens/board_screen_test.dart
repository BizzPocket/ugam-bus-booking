import 'dart:convert';
import 'dart:io';

// The top-level `tr()`, so the integration group asserts on the SAME string the
// Board renders rather than on a hand-copied literal.
import 'package:easy_localization/easy_localization.dart' hide TextDirection;
// ignore: implementation_imports
import 'package:easy_localization/src/localization.dart';
// ignore: implementation_imports
import 'package:easy_localization/src/translations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart' hide Translations;
import 'package:occubusbooking/controllers/board_controller.dart';
import 'package:occubusbooking/controllers/money_controller.dart';
import 'package:occubusbooking/controllers/tour_controller.dart';
import 'package:occubusbooking/design/components/ugam_button.dart';
import 'package:occubusbooking/design/tokens.dart';
import 'package:occubusbooking/models/board_lens.dart';
import 'package:occubusbooking/models/bus_details.dart';
import 'package:occubusbooking/models/bus_type.dart';
import 'package:occubusbooking/models/collection.dart';
import 'package:occubusbooking/models/handler_phase.dart';
import 'package:occubusbooking/models/passenger.dart';
import 'package:occubusbooking/models/passenger_group.dart';
import 'package:occubusbooking/models/seat_assignment.dart';
import 'package:occubusbooking/models/seat_layout.dart';
import 'package:occubusbooking/models/seat_type.dart';
import 'package:occubusbooking/models/tour.dart';
import 'package:occubusbooking/models/tour_status.dart';
import 'package:occubusbooking/models/trip_type.dart';
import 'package:occubusbooking/screens/board/board_screen.dart';
import 'package:occubusbooking/utils/aisle_order.dart';
import 'package:occubusbooking/utils/formatters.dart';
import 'package:occubusbooking/widgets/board/berth_tile.dart';
import 'package:occubusbooking/widgets/board/board_canvas.dart';
import 'package:occubusbooking/widgets/board/board_empty_states.dart';
import 'package:occubusbooking/widgets/board/board_legend.dart';
import 'package:occubusbooking/widgets/board/board_summary_strip.dart';
import 'package:occubusbooking/widgets/board/lens_switcher.dart';
import 'package:occubusbooking/widgets/board/passenger_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The Board's assembly layer.
///
/// Everything the screen MOUNTS is tested next door (the canvas, the strip, the
/// switcher, the legend, the tile, the lens model, the aisle walk). What is
/// only testable here is what the screen itself invents: the tour → Board
/// mapping, the phase/day inputs the default lens is derived from, and the
/// wiring that makes "next outstanding" walk a real bus in real aisle order.
void main() {
  Map<String, dynamic> load(String lang) =>
      jsonDecode(File('assets/translations/$lang.json').readAsStringSync())
          as Map<String, dynamic>;

  final en = load('en');
  final gu = load('gu');
  final hi = load('hi');

  setUpAll(() {
    Localization.load(
      const Locale('en'),
      translations: Translations(en),
      ignorePluralRules: true,
    );
  });

  // ── i18n ──────────────────────────────────────────────────

  group('board_screen copy exists in all three locales', () {
    test('same keys, and none of them is English pasted across', () {
      final keys = (en['board_screen'] as Map).keys.toSet();
      expect(keys, isNotEmpty);
      expect((gu['board_screen'] as Map).keys.toSet(), keys);
      expect((hi['board_screen'] as Map).keys.toSet(), keys);
      for (final k in keys) {
        expect(
          gu['board_screen'][k],
          isNot(equals(en['board_screen'][k])),
          reason: 'gu/board_screen.$k is still English',
        );
        expect(
          hi['board_screen'][k],
          isNot(equals(en['board_screen'][k])),
          reason: 'hi/board_screen.$k is still English',
        );
      }
    });

    test('every placeholder survives translation', () {
      final source = en['board_screen'] as Map;
      for (final k in source.keys) {
        final holders = RegExp(r'\{\w+\}')
            .allMatches(source[k] as String)
            .map((m) => m.group(0))
            .toSet();
        for (final locale in [gu, hi]) {
          final translated = locale['board_screen'][k] as String;
          for (final h in holders) {
            expect(
              translated,
              contains(h!),
              reason: 'board_screen.$k lost $h',
            );
          }
        }
      }
    });
  });

  // ── Pure inputs to the phase default (spec §6) ────────────

  group('boardDaysUntilDeparture', () {
    test('counts calendar days, not elapsed hours', () {
      // 23:00 tonight is still ONE sleep from a 06:00 departure tomorrow.
      expect(
        boardDaysUntilDeparture(
          DateTime(2026, 8, 13, 6),
          DateTime(2026, 8, 12, 23),
        ),
        1,
      );
      // …and so is 07:00 this morning.
      expect(
        boardDaysUntilDeparture(
          DateTime(2026, 8, 13, 6),
          DateTime(2026, 8, 12, 7),
        ),
        1,
      );
    });

    test('departure day is zero and a past tour is negative', () {
      expect(
        boardDaysUntilDeparture(
          DateTime(2026, 8, 12, 5),
          DateTime(2026, 8, 12, 22),
        ),
        0,
      );
      expect(
        boardDaysUntilDeparture(
          DateTime(2026, 8, 10),
          DateTime(2026, 8, 12),
        ),
        -2,
      );
    });

    test('feeds the T-2d money chase of spec §6', () {
      // The rule the Board actually depends on: inside two days the default
      // lens becomes Money, outside it stays Occupancy.
      BoardLensId lensAt(int days) => defaultLensForPhase(
        null,
        daysUntilDeparture: days,
        available: kShippedBoardLenses,
      );
      expect(lensAt(9), BoardLensId.occupancy);
      expect(lensAt(3), BoardLensId.occupancy);
      expect(lensAt(2), BoardLensId.money);
      expect(lensAt(0), BoardLensId.money);
    });
  });

  group('boardPhaseForTour', () {
    test('a completed tour is closed; everything else is unknown', () {
      expect(boardPhaseForTour(_tour()), isNull);
      expect(
        boardPhaseForTour(_tour(status: TourStatus.assigning)),
        isNull,
      );
      expect(
        boardPhaseForTour(_tour(status: TourStatus.completed)),
        HandlerPhase.closed,
      );
    });

    test('closed opens on the roster, not on a chase', () {
      expect(
        defaultLensForPhase(
          HandlerPhase.closed,
          daysUntilDeparture: -4,
          available: kShippedBoardLenses,
        ),
        BoardLensId.occupancy,
      );
    });
  });

  // ── Tour → Board mapping ──────────────────────────────────

  group('boardBerthsForBus', () {
    test('emits occupied berths only — the canvas draws the rest', () {
      final bus = _bus();
      final seats = _seatIds(bus, 3);
      final riders = [
        _rider('p1', 'Ramesh', bus.id, seats[0]),
        _rider('p2', 'Priti', bus.id, seats[2]),
      ];

      final berths = boardBerthsForBus(bus: bus, passengers: riders);

      expect(berths.keys.toSet(), {seats[0], seats[2]});
      expect(berths[seats[1]], isNull);
      expect(berths[seats[0]]!.isOccupied, isTrue);
      expect(berths[seats[0]]!.occupantName, 'Ramesh');
    });

    test('carries the code, the seat type and the pickup stop', () {
      final bus = _bus();
      final seat = _seatIds(bus, 1).single;
      final berths = boardBerthsForBus(
        bus: bus,
        passengers: [
          _rider(
            'p1',
            'Ramesh',
            bus.id,
            seat,
            stopId: 's-adajan',
            stopName: 'Adajan',
          ),
        ],
      );

      final berth = berths[seat]!;
      expect(berth.code, seat);
      expect(berth.seatTypeLabel, isNotNull);
      expect(berth.pickupStopId, 's-adajan');
      expect(berth.pickupStopName, 'Adajan');
    });

    test('resolves the group NAME, not just its id', () {
      final bus = _bus();
      final seat = _seatIds(bus, 1).single;
      final berths = boardBerthsForBus(
        bus: bus,
        passengers: [_rider('p1', 'Ramesh', bus.id, seat, groupId: 'g1')],
        groupNames: {'g1': 'Patel family'},
      );
      expect(berths[seat]!.groupId, 'g1');
      expect(berths[seat]!.groupName, 'Patel family');
    });

    test('money comes from the collection row, not from the passenger', () {
      final bus = _bus();
      final seat = _seatIds(bus, 1).single;
      final rider = _rider('p1', 'Ramesh', bus.id, seat);
      final fare = bus.amountDueForSeat(rider, seat);
      expect(fare, greaterThan(0), reason: 'the fixture must be priced');

      final berths = boardBerthsForBus(
        bus: bus,
        passengers: [rider],
        collectionFor: (p, s) => Collection(
          tourId: 't1',
          busId: bus.id,
          passengerId: p.id,
          seatId: s,
          amountDue: fare,
          amountReceived: 200,
        ),
      );

      final berth = berths[seat]!;
      expect(berth.fareDue, fare);
      expect(berth.paid, 200);
      expect(berth.money, BerthMoney.half);
    });

    test('a refund is netted off what the rider has paid', () {
      final bus = _bus();
      final seat = _seatIds(bus, 1).single;
      final rider = _rider('p1', 'Ramesh', bus.id, seat);
      final berths = boardBerthsForBus(
        bus: bus,
        passengers: [rider],
        collectionFor: (p, s) => Collection(
          tourId: 't1',
          busId: bus.id,
          passengerId: p.id,
          seatId: s,
          amountReceived: 500,
          amountRefunded: 200,
        ),
      );
      expect(berths[seat]!.paid, 300);
    });

    test('a shared berth sums BOTH riders and shows the lead name', () {
      final bus = _bus();
      final seat = _sharedSeatId(bus);
      final go = _rider('p1', 'Ramesh', bus.id, seat, leg: TripType.outboundOnly);
      final ret = _rider('p2', 'Priti', bus.id, seat, leg: TripType.returnOnly);

      final berths = boardBerthsForBus(bus: bus, passengers: [go, ret]);
      final berth = berths[seat]!;

      expect(
        berth.fareDue,
        bus.amountDueForSeat(go, seat) + bus.amountDueForSeat(ret, seat),
      );
      expect(berth.occupantName, 'Ramesh');
    });

    test('a bus with no seat plan maps to nothing at all', () {
      final bus = Bus(id: 'b1', name: 'Bus 1', busType: 'Sleeper');
      expect(
        boardBerthsForBus(
          bus: bus,
          passengers: [_rider('p1', 'Ramesh', 'b1', 'DL1')],
        ),
        isEmpty,
      );
    });
  });

  // ── The five-tint cap (spec §5) ───────────────────────────

  group('tint scales', () {
    BoardBerth seated(String code, {String? stopId, String? groupId}) =>
        BoardBerth(
          code: code,
          isOccupied: true,
          pickupStopId: stopId,
          pickupStopName: stopId == null ? null : 'Stop $stopId',
          groupId: groupId,
          groupName: groupId == null ? null : 'Group $groupId',
        );

    test('keeps the five biggest stops and folds the rest into "other"', () {
      final berths = <BoardBerth>[
        for (var i = 0; i < 6; i++) seated('a$i', stopId: 'a'),
        for (var i = 0; i < 5; i++) seated('b$i', stopId: 'b'),
        for (var i = 0; i < 4; i++) seated('c$i', stopId: 'c'),
        for (var i = 0; i < 3; i++) seated('d$i', stopId: 'd'),
        for (var i = 0; i < 2; i++) seated('e$i', stopId: 'e'),
        seated('f0', stopId: 'f'),
        seated('g0', stopId: 'g'),
      ];

      final tints = boardStopTints(berths);
      expect(tints.tinted.map((b) => b.id), ['a', 'b', 'c', 'd', 'e']);
      expect(tints.otherBuckets, 2);
      expect(tints.otherBerths, 2);
    });

    test('buckets on the id the lens asks a berth for', () {
      // A tint keyed on anything but `pickupStopId` would paint a berth the
      // legend's own predicate could never select, and the swatch would filter
      // the whole bus away.
      final berths = [seated('x', stopId: 's1'), seated('y', stopId: 's1')];
      final lens = PickupLens(boardStopTints(berths));
      final legend = lens.legendFor(berths, _palette);
      expect(legend, hasLength(1));
      expect(legend.single.selects(berths.first), isTrue);
    });

    test('an unbucketed bus produces an empty scale, never a fake row', () {
      expect(boardStopTints([seated('x')]).isEmpty, isTrue);
      expect(boardGroupTints([seated('x')]).isEmpty, isTrue);
    });

    test('groups tint on groupId', () {
      final berths = [
        seated('x', groupId: 'g1'),
        seated('y', groupId: 'g1'),
        seated('z', groupId: 'g2'),
      ];
      final tints = boardGroupTints(berths);
      expect(tints.tinted.map((b) => b.id), ['g1', 'g2']);
      expect(tints.tinted.first.count, 2);
    });
  });

  // ── The interaction the Board exists for (spec §4) ────────

  group('aisle-order walk', () {
    late Bus bus;
    late BoardController board;
    late Map<String, BoardBerth> berths;

    setUp(() {
      bus = _bus();
      board = BoardController();
      board.setLayout(bus.layout);

      // Every third berth along the walk still owes money; the rest are square.
      final walk = aisleOrder(bus.layout);
      berths = <String, BoardBerth>{
        for (var i = 0; i < walk.length; i++)
          if (walk[i].seatId != null)
            walk[i].seatId!: BoardBerth(
              code: walk[i].seatId!,
              isOccupied: true,
              occupantName: 'Rider $i',
              fareDue: 1000,
              paid: i % 3 == 0 ? 0 : 1000,
            ),
      };
    });

    List<String> outstandingInWalkOrder() => [
      for (final cell in aisleOrder(bus.layout))
        if (const MoneyLens().needsAction(
          boardBerthFor(cell, berths),
        ))
          cell.seatId!,
    ];

    test('visits every outstanding berth once, front to back', () {
      final needsAction = boardNeedsAction(const MoneyLens(), berths);
      final expected = outstandingInWalkOrder();
      expect(expected.length, greaterThan(3));

      final visited = <String>[];
      for (var i = 0; i < expected.length; i++) {
        final cell = board.advanceToNextOutstanding(
          needsAction,
          wrap: false,
        );
        expect(cell, isNotNull, reason: 'stopped after ${visited.length}');
        visited.add(cell!.seatId!);
      }

      expect(visited, expected);
      expect(
        board.advanceToNextOutstanding(needsAction, wrap: false),
        isNull,
        reason: 'the round is over, so the control must go quiet',
      );
    });

    test('the running count is what the strip shows, and it falls', () {
      final needsAction = boardNeedsAction(const MoneyLens(), berths);
      final before = board.outstandingCount(needsAction);
      expect(before, outstandingInWalkOrder().length);

      // Collect from the frontmost outstanding berth.
      final first = board.advanceToNextOutstanding(needsAction)!;
      berths[first.seatId!] = berths[first.seatId!]!.copyWith(paid: 1000);

      final after = board.outstandingCount(
        boardNeedsAction(const MoneyLens(), berths),
      );
      expect(after, before - 1);
    });

    test('the walk is aisle order, not seat-code order', () {
      // The whole point of spec §4: the app's every other ordered view is by
      // generated seat code (lane by lane), which walks the bus four times.
      final walk = aisleOrder(bus.layout).map((c) => c.seatId!).toList();
      final byCode = [...walk]..sort();
      expect(walk, isNot(equals(byCode)));
    });

    test('a paid berth is never stopped at', () {
      final needsAction = boardNeedsAction(const MoneyLens(), berths);
      final paid = berths.entries.firstWhere((e) => e.value.paid > 0).key;
      final visited = <String>{};
      for (var i = 0; i < 200; i++) {
        final cell = board.advanceToNextOutstanding(needsAction, wrap: false);
        if (cell == null) break;
        visited.add(cell.seatId!);
      }
      expect(visited, isNot(contains(paid)));
    });

    test('an empty-berth walk is what the occupancy lens asks for', () {
      final sparse = <String, BoardBerth>{
        for (final e in berths.entries.take(2)) e.key: e.value,
      };
      final cell = board.advanceToNextOutstanding(
        boardNeedsAction(const OccupancyLens(), sparse),
      );
      // The first berth along the walk that nobody holds.
      expect(cell, isNotNull);
      expect(sparse.containsKey(cell!.seatId), isFalse);
    });
  });

  // ── Smoke ─────────────────────────────────────────────────

  group('BoardScreen', () {
    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{});
    });

    tearDown(Get.reset);

    testWidgets('mounts a real bus, its lenses and its walk control', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1170, 2532);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);

      final bus = _bus();
      final seats = _seatIds(bus, 4);
      final tour = _tour(
        buses: [bus],
        passengers: [
          for (var i = 0; i < seats.length; i++)
            _rider('p$i', 'Rider $i', bus.id, seats[i]),
        ],
        groups: [PassengerGroup(id: 'g1', tourId: 't1', label: 'Patel family')],
      );

      Get.put<TourController>(_FakeTourController()..tours.add(tour));
      Get.put<MoneyController>(_FakeMoneyController());

      await tester.pumpWidget(
        const MaterialApp(home: BoardScreen(tourId: 't1')),
      );
      await tester.pumpAndSettle();

      // The canvas is on screen with real berths…
      expect(find.byType(BoardCanvas), findsOneWidget);
      expect(find.byType(BerthTile), findsWidgets);
      // …the lens switcher offers exactly the lenses that have data…
      expect(find.byType(BoardLensSwitcher), findsOneWidget);
      // …and "next outstanding" is mounted and reachable.
      expect(find.byKey(const Key('board_screen.next_outstanding')),
          findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('"next outstanding" parks the walk on a berth (spec §4)', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1170, 2532);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);

      final bus = _bus();
      final seats = _seatIds(bus, 3);
      Get.put<TourController>(
        _FakeTourController()
          ..tours.add(
            _tour(
              buses: [bus],
              passengers: [
                for (var i = 0; i < seats.length; i++)
                  _rider('p$i', 'Rider $i', bus.id, seats[i]),
              ],
            ),
          ),
      );
      Get.put<MoneyController>(_FakeMoneyController());

      await tester.pumpWidget(
        const MaterialApp(home: BoardScreen(tourId: 't1')),
      );
      await tester.pumpAndSettle();

      Iterable<BerthTile> cursored() => tester
          .widgetList<BerthTile>(find.byType(BerthTile))
          .where((t) => t.isCurrent);

      expect(cursored(), isEmpty, reason: 'the walk has not started');

      await tester.tap(find.byKey(const Key('board_screen.next_outstanding')));
      await tester.pumpAndSettle();

      // Exactly one berth now carries the "this is yours" ring: the walk moved,
      // in aisle order, and the canvas painted where it landed.
      expect(cursored(), hasLength(1));
      expect(tester.takeException(), isNull);
    });

    testWidgets('a tour that is not loaded says so instead of blanking', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1170, 2532);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        const MaterialApp(home: BoardScreen(tourId: 'nope')),
      );
      await tester.pumpAndSettle();

      expect(find.text(en['board_screen']['no_tour_title'] as String),
          findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a tour with no bus offers the way out', (tester) async {
      tester.view.physicalSize = const Size(1170, 2532);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);

      Get.put<TourController>(_FakeTourController()..tours.add(_tour()));

      await tester.pumpWidget(
        const MaterialApp(home: BoardScreen(tourId: 't1')),
      );
      await tester.pumpAndSettle();

      expect(find.text(en['board_screen']['no_bus_title'] as String),
          findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('reserves the floating dock band under the legend', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1170, 2532);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);

      final bus = _bus();
      final seats = _seatIds(bus, 2);
      Get.put<TourController>(
        _FakeTourController()
          ..tours.add(
            _tour(
              buses: [bus],
              passengers: [
                for (var i = 0; i < seats.length; i++)
                  _rider('p$i', 'Rider $i', bus.id, seats[i]),
              ],
            ),
          ),
      );
      Get.put<MoneyController>(_FakeMoneyController());

      await tester.pumpWidget(
        const MaterialApp(home: BoardScreen(tourId: 't1')),
      );
      await tester.pumpAndSettle();

      // No berth may sit in the bottom 140pt: that band belongs to the shell's
      // floating dock, which never shows up in this screen's own metrics.
      final screen = tester.getSize(find.byType(BoardScreen));
      final dockTop = screen.height - 140;
      final tiles = find.byType(BerthTile).evaluate();
      expect(tiles, isNotEmpty, reason: 'nothing to be trapped behind it');
      for (final tile in tiles) {
        final box = tile.renderObject! as RenderBox;
        final bottom =
            box.localToGlobal(Offset.zero).dy + box.size.height;
        expect(
          bottom,
          lessThanOrEqualTo(dockTop + 0.5),
          reason: 'a berth is trapped behind the dock',
        );
      }
    });
  });

  // ── The assembled Board ───────────────────────────────────
  //
  // Every part above is tested on its own, and all of them pass while the Board
  // is still broken: a Board is not six widgets, it is six widgets sharing ONE
  // controller, and every interesting failure lives in that sharing. One lens
  // tap has to recolour the chart AND rebuild the legend AND change the number
  // in the strip; a legend swatch has to dim berths it does not own; the walk
  // has to move the highlight down the REAL bus; a phase change must not yank
  // the lens out from under a handler who chose one. Nothing below reaches into
  // the screen — every assertion is on what is rendered and what a thumb can
  // reach.

  group('the assembled Board', () {
    setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));
    tearDown(Get.reset);

    late _FakeMoneyController money;

    Tour tourWith(
      Bus bus,
      List<Passenger> riders, {
      DateTime? departure,
      TourStatus status = TourStatus.assigning,
      List<PassengerGroup> groups = const [],
    }) => Tour(
      id: 't1',
      title: 'Dwarka Yatra',
      fromCity: 'Surat',
      toCity: 'Dwarka',
      // Ten days out unless a test says otherwise: outside the T-2d window, so
      // the Board opens on Occupancy and a money test has to say so explicitly.
      departureDate: departure ?? DateTime.now().add(const Duration(days: 10)),
      pricePerSeat: 1000,
      status: status,
      buses: [bus],
      passengers: riders,
      groups: groups,
    );

    Future<_FakeTourController> mount(
      WidgetTester tester,
      Tour tour, {
      List<Collection> Function(Tour tour)? collections,
    }) async {
      tester.view.physicalSize = const Size(1170, 2532);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);

      final tours = _FakeTourController()..tours.add(tour);
      Get.put<TourController>(tours);
      money = Get.put<MoneyController>(_FakeMoneyController())
          as _FakeMoneyController;
      if (collections != null) money.collections.addAll(collections(tour));

      await tester.pumpWidget(
        const MaterialApp(home: BoardScreen(tourId: 't1')),
      );
      await tester.pumpAndSettle();
      return tours;
    }

    List<BerthTile> tiles(WidgetTester tester) =>
        tester.widgetList<BerthTile>(find.byType(BerthTile)).toList();

    BerthTile tileFor(WidgetTester tester, String code) =>
        tiles(tester).firstWhere((t) => t.berth.code == code);

    /// The berth the walk is parked on, read off the CHART rather than off the
    /// controller — the highlight is the thing a handler actually follows.
    String? highlighted(WidgetTester tester) {
      for (final t in tiles(tester)) {
        if (t.isCurrent) return t.berth.code;
      }
      return null;
    }

    /// A state glyph ON THE CHART. Scoped, because the legend repeats every
    /// glyph it explains — which is the point of the legend and a trap for a
    /// bare `find.text`.
    Finder glyph(String g) =>
        find.descendant(of: find.byType(BoardCanvas), matching: find.text(g));

    Finder legendRow(String label) => find.descendant(
      of: find.byType(BoardLegend),
      matching: find.text(label),
    );

    BoardLensId shownLens(WidgetTester tester) => tester
        .widget<BoardLensSwitcher>(find.byType(BoardLensSwitcher))
        .current;

    /// The switcher scrolls the ACTIVE pill into view, so the pill you want can
    /// be off the near edge. A handler would flick it into reach; so does this.
    Future<void> tapLens(WidgetTester tester, BoardLensId id) async {
      final pill = find.text(id.label);
      await tester.ensureVisible(pill);
      await tester.pumpAndSettle();
      await tester.tap(pill);
      await tester.pumpAndSettle();
    }

    Future<void> dismissSheet(WidgetTester tester) async {
      Navigator.of(
        tester.element(find.byType(BoardScreen)),
        rootNavigator: true,
      ).pop();
      await tester.pumpAndSettle();
    }

    /// The sheet's one primary button — the only thing a lens changes there.
    UgamButton sheetPrimary(WidgetTester tester) => tester.widget<UgamButton>(
      find.descendant(
        of: find.byType(PassengerSheet),
        matching: find.byType(UgamButton),
      ),
    );

    /// Riders on the first [count] berths IN WALKING ORDER, so the fixture and
    /// the walk under test agree about what "the front of the bus" means.
    (Bus, List<Passenger>, List<String>) loaded({int count = 4, int seats = 30}) {
      final bus = _bus();
      final ids = _seatIds(bus, count);
      return (
        bus,
        [for (var i = 0; i < ids.length; i++) _rider('p$i', 'Rider $i', bus.id, ids[i])],
        ids,
      );
    }

    // ── One tap, three widgets ──────────────────────────────

    testWidgets('switching lens recolours the chart, rebuilds the legend and '
        'changes the number in the strip', (tester) async {
      final (bus, riders, ids) = loaded();
      await mount(
        tester,
        tourWith(bus, riders),
        // Two of the four have paid in full; two still owe.
        collections: (tour) => [
          for (var i = 0; i < 2; i++)
            Collection(
              tourId: tour.id,
              busId: bus.id,
              passengerId: 'p$i',
              seatId: ids[i],
              amountDue: bus.amountDueForSeat(riders[i], ids[i]),
              amountReceived: bus.amountDueForSeat(riders[i], ids[i]),
            ),
        ],
      );

      // Occupancy: four riders aboard, and a legend that names only the states
      // this bus actually has (spec §13).
      expect(shownLens(tester), BoardLensId.occupancy);
      expect(glyph('●'), findsNWidgets(4));
      expect(legendRow(tr('board_lens.state_occupied')), findsOneWidget);
      expect(legendRow(tr('board_lens.state_empty')), findsOneWidget);
      expect(legendRow(tr('board_lens.state_paid')), findsNothing);
      expect(find.byType(BoardSummaryStrip), findsOneWidget);

      await tapLens(tester, BoardLensId.money);

      // Colour function: two square, two owing.
      expect(glyph('✓'), findsNWidgets(2));
      expect(
        glyph('●'),
        findsNothing,
        reason: 'the occupancy glyph must not survive a lens switch',
      );

      // Legend: the money key, and the occupancy key is gone.
      expect(legendRow(tr('board_lens.state_paid')), findsOneWidget);
      expect(legendRow(tr('board_lens.state_due')), findsOneWidget);
      expect(legendRow(tr('board_lens.state_occupied')), findsNothing);

      // Strip: the METRIC changed, not just its value.
      final owed =
          bus.amountDueForSeat(riders[2], ids[2]) +
          bus.amountDueForSeat(riders[3], ids[3]);
      expect(
        find.text(
          tr(
            'board_strip.money_due',
            namedArgs: {'amount': Formatters.formatMoneyInr(owed)},
          ),
        ),
        findsOneWidget,
      );
    });

    // ── The legend IS the filter ────────────────────────────

    testWidgets('a legend swatch dims every berth it does not select, and '
        'tapping it again clears', (tester) async {
      final (bus, riders, ids) = loaded();
      await mount(
        tester,
        tourWith(bus, riders),
        collections: (tour) => [
          for (var i = 0; i < 2; i++)
            Collection(
              tourId: tour.id,
              busId: bus.id,
              passengerId: 'p$i',
              seatId: ids[i],
              amountDue: bus.amountDueForSeat(riders[i], ids[i]),
              amountReceived: bus.amountDueForSeat(riders[i], ids[i]),
            ),
        ],
      );
      await tapLens(tester, BoardLensId.money);

      await tester.tap(legendRow(tr('board_lens.state_due')));
      await tester.pumpAndSettle();

      expect(tileFor(tester, ids[2]).isDimmed, isFalse, reason: '${ids[2]} owes');
      expect(tileFor(tester, ids[3]).isDimmed, isFalse, reason: '${ids[3]} owes');
      expect(tileFor(tester, ids[0]).isDimmed, isTrue, reason: 'square');
      expect(tileFor(tester, ids[1]).isDimmed, isTrue, reason: 'square');

      await tester.tap(legendRow(tr('board_lens.state_due')));
      await tester.pumpAndSettle();

      for (final id in ids) {
        expect(tileFor(tester, id).isDimmed, isFalse, reason: id);
      }
    });

    testWidgets('a lens change drops a filter whose id it cannot mean', (
      tester,
    ) async {
      final (bus, riders, ids) = loaded();
      await mount(tester, tourWith(bus, riders));
      await tapLens(tester, BoardLensId.money);

      await tester.tap(legendRow(tr('board_lens.state_due')));
      await tester.pumpAndSettle();
      expect(tileFor(tester, ids[0]).isDimmed, isFalse);

      await tapLens(tester, BoardLensId.occupancy);

      // "due" means nothing under occupancy; carrying it would black out the
      // whole coach against an id no berth can match.
      for (final id in ids) {
        expect(tileFor(tester, id).isDimmed, isFalse, reason: id);
      }
    });

    // ── The sheet, and the action the lens puts under the thumb ──

    testWidgets('tapping a berth opens the sheet with the occupancy action', (
      tester,
    ) async {
      final (bus, riders, ids) = loaded();
      await mount(tester, tourWith(bus, riders));

      await tester.tap(find.text(ids[0]));
      await tester.pumpAndSettle();

      expect(find.byType(PassengerSheet), findsOneWidget);
      expect(sheetPrimary(tester).label, tr('board_lens.action_call'));
      // A lens re-ranks the actions; it never removes one.
      expect(find.text(tr('board_lens.action_collect')), findsOneWidget);

      await dismissSheet(tester);
      // The tap parked the walk, so "next outstanding" carries on from where
      // the handler actually is (spec §4).
      expect(highlighted(tester), ids[0]);
    });

    testWidgets('the same berth, under the money lens, offers Collect', (
      tester,
    ) async {
      final (bus, riders, ids) = loaded();
      await mount(tester, tourWith(bus, riders));
      await tapLens(tester, BoardLensId.money);

      await tester.tap(find.text(ids[0]));
      await tester.pumpAndSettle();

      final primary = sheetPrimary(tester);
      expect(primary.label, tr('board_lens.action_collect'));
      expect(
        primary.onPressed,
        isNotNull,
        reason: 'the whole fare is outstanding, so Collect has to be live',
      );
      expect(find.text(tr('board_lens.action_call')), findsOneWidget);
    });

    testWidgets('a square berth cannot be collected from', (tester) async {
      final (bus, riders, ids) = loaded(count: 1);
      await mount(
        tester,
        tourWith(bus, riders),
        collections: (tour) => [
          Collection(
            tourId: tour.id,
            busId: bus.id,
            passengerId: 'p0',
            seatId: ids[0],
            amountDue: bus.amountDueForSeat(riders[0], ids[0]),
            amountReceived: bus.amountDueForSeat(riders[0], ids[0]),
          ),
        ],
      );
      await tapLens(tester, BoardLensId.money);

      await tester.tap(find.text(ids[0]));
      await tester.pumpAndSettle();

      expect(sheetPrimary(tester).label, tr('board_lens.action_collect'));
      expect(sheetPrimary(tester).onPressed, isNull);
    });

    // ── The interaction most likely to be subtly wrong ──────

    testWidgets('"next outstanding" walks the aisle, not the alphabet', (
      tester,
    ) async {
      final (bus, riders, ids) = loaded();
      await mount(tester, tourWith(bus, riders));
      await tapLens(tester, BoardLensId.money);

      // Berth ids are generated LANE BY LANE, so an alphabetical list walks the
      // left lane to the back, returns to the front for the right lane, and
      // does it twice more for the uppers. These four are the front of the bus
      // in walking order, and they are NOT in code order.
      final byCode = [...ids]..sort();
      expect(
        ids,
        isNot(byCode),
        reason: 'the fixture has to disagree or the test proves nothing',
      );

      final visited = <String>[];
      for (var i = 0; i < ids.length; i++) {
        await tester.tap(
          find.byKey(const Key('board_screen.next_outstanding')),
        );
        await tester.pumpAndSettle();
        expect(
          find.byType(PassengerSheet),
          findsOneWidget,
          reason: 'the advance opens the berth it walked to (spec §4)',
        );
        visited.add(highlighted(tester)!);
        // Dismissed without acting: the round stops rather than dragging the
        // handler onward.
        await dismissSheet(tester);
      }

      expect(visited, ids);
      expect(visited, isNot(byCode));
    });

    testWidgets('the highlight moves down the bus, never back up it', (
      tester,
    ) async {
      final (bus, riders, ids) = loaded();
      await mount(tester, tourWith(bus, riders));
      await tapLens(tester, BoardLensId.money);

      Offset? previous;
      for (var i = 0; i < ids.length; i++) {
        await tester.tap(
          find.byKey(const Key('board_screen.next_outstanding')),
        );
        await tester.pumpAndSettle();
        await dismissSheet(tester);

        final at = tester.getCenter(
          find.ancestor(
            of: find.text(highlighted(tester)!),
            matching: find.byType(BerthTile),
          ),
        );
        if (previous != null) {
          expect(
            at.dy > previous.dy - 0.5,
            isTrue,
            reason: 'step $i jumped backwards up the coach',
          );
          if ((at.dy - previous.dy).abs() < 0.5) {
            expect(at.dx, greaterThan(previous.dx), reason: 'step $i, same row');
          }
        }
        previous = at;
      }
    });

    testWidgets('the control goes quiet when the round is done', (
      tester,
    ) async {
      final (bus, riders, ids) = loaded(count: 1);
      await mount(
        tester,
        tourWith(bus, riders),
        collections: (tour) => [
          Collection(
            tourId: tour.id,
            busId: bus.id,
            passengerId: 'p0',
            seatId: ids[0],
            amountDue: bus.amountDueForSeat(riders[0], ids[0]),
            amountReceived: bus.amountDueForSeat(riders[0], ids[0]),
          ),
        ],
      );
      await tapLens(tester, BoardLensId.money);

      // Nobody owes anything, so the control must not go dead under the thumb —
      // it says the round is complete instead.
      expect(
        find.bySemanticsLabel(tr('board_screen.round_done_a11y')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('board_screen.next_outstanding')));
      await tester.pumpAndSettle();
      expect(find.byType(PassengerSheet), findsNothing);
      expect(highlighted(tester), isNull);
    });

    // ── Search highlights; it does not navigate ─────────────

    testWidgets('search lights the match, dims the rest, and stays here', (
      tester,
    ) async {
      final (bus, riders, ids) = loaded();
      await mount(tester, tourWith(bus, riders));

      await tester.tap(find.byTooltip(tr('board_screen.search_open')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Rider 2');
      await tester.pump(
        kBoardSearchRevealDelay + const Duration(milliseconds: 40),
      );
      // Fixed pumps, NOT pumpAndSettle: a search hit pulses (spec §10) and the
      // pulse repeats forever by design, so there is no settled frame to wait
      // for. Long enough to cover the reveal scroll (`UgamMotion.sheet`).
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump(const Duration(milliseconds: 200));

      expect(tileFor(tester, ids[2]).isDimmed, isFalse);
      expect(tileFor(tester, ids[0]).isDimmed, isTrue);
      expect(tileFor(tester, ids[1]).isDimmed, isTrue);

      // Leaving the chart for a list screen is the exact pattern the Board
      // exists to eliminate.
      expect(find.byType(BoardCanvas), findsOneWidget);
      expect(find.byType(BoardLensSwitcher), findsOneWidget);
      expect(find.byType(PassengerSheet), findsNothing);

      // Closing the search box restores the whole bus.
      await tester.tap(find.byTooltip(tr('board_screen.search_close')));
      await tester.pumpAndSettle();
      for (final id in ids) {
        expect(tileFor(tester, id).isDimmed, isFalse, reason: id);
      }
    });

    // ── Two densities ───────────────────────────────────────

    testWidgets('the density toggle trades names for the whole coach', (
      tester,
    ) async {
      final (bus, riders, _) = loaded();
      await mount(tester, tourWith(bus, riders));

      // A 30-berth coach is under the threshold, so it opens in the working
      // mode — with names, which is the reason the Board replaces a chart you
      // can only look at.
      expect(find.text('Rider 0'), findsOneWidget);

      await tester.tap(find.byTooltip(tr('board_screen.density_compact')));
      await tester.pumpAndSettle();

      expect(find.text('Rider 0'), findsNothing);
      expect(find.byType(BerthTile), findsWidgets);
      expect(tester.takeException(), isNull);

      await tester.tap(find.byTooltip(tr('board_screen.density_comfortable')));
      await tester.pumpAndSettle();
      expect(find.text('Rider 0'), findsOneWidget);
    });

    // ── The phase opens the Board; the human keeps it ───────

    testWidgets('the opening lens follows the trip, and a manual choice '
        'survives the trip moving on', (tester) async {
      final (bus, riders, _) = loaded();
      final tours = await mount(tester, tourWith(bus, riders));

      // Ten days out: you are still placing people.
      expect(shownLens(tester), BoardLensId.occupancy);

      // Inside the T-2d window the job becomes chasing balances.
      tours.tours[0] = tourWith(bus, riders, departure: DateTime.now());
      await tester.pumpAndSettle();
      expect(shownLens(tester), BoardLensId.money);

      // Back out again, to prove the phase really is driving it.
      tours.tours[0] = tourWith(bus, riders);
      await tester.pumpAndSettle();
      expect(shownLens(tester), BoardLensId.occupancy);

      // Now the handler says "money" out loud.
      await tapLens(tester, BoardLensId.money);
      expect(shownLens(tester), BoardLensId.money);

      // …and the trip moves on to a phase whose default is Occupancy. Spec §6:
      // never override an explicit manual choice within the same session.
      tours.tours[0] = tourWith(
        bus,
        riders,
        status: TourStatus.completed,
        departure: DateTime.now().subtract(const Duration(days: 4)),
      );
      await tester.pumpAndSettle();

      expect(
        boardPhaseForTour(tours.tours.first),
        HandlerPhase.closed,
        reason: 'the phase really did change',
      );
      expect(shownLens(tester), BoardLensId.money);
    });

    // ── A bus with no seat plan (spec §13) ──────────────────

    testWidgets('a bus with no seat plan says so, offers the way out, and '
        'renders no legend', (tester) async {
      final bus = Bus(id: 'b1', name: 'Bus 1', busType: 'Sleeper');
      await mount(tester, tourWith(bus, const []));

      expect(find.text(tr('board_canvas.no_layout_title')), findsOneWidget);
      expect(find.text(tr('board_canvas.no_layout_body')), findsOneWidget);
      expect(find.text(tr('add_bus.title')), findsOneWidget);

      // Never a legend for berths that do not exist, and no number to pin.
      expect(legendRow(tr('board_lens.state_occupied')), findsNothing);
      expect(legendRow(tr('board_lens.state_empty')), findsNothing);
      expect(find.byType(BoardSummaryStrip), findsNothing);
      expect(find.byType(BerthTile), findsNothing);
      expect(tester.takeException(), isNull);
    });

    // ── The per-LENS empty states (spec §13) ────────────────
    //
    // The no-seat-plan case above is the canvas's own, because it lives inside
    // the multi-bus pager. These are the other half of §13 — a lens that has a
    // plan and riders to draw but still has nothing to SAY — and they reach the
    // screen through `BoardEmptyStates`.

    testWidgets('the money lens on a bus nobody is on yet asks for riders '
        'instead of charting thirty empty berths', (tester) async {
      // A real seat plan, so this is NOT the no-layout case — the bus is fine,
      // the LENS is the thing with nothing to say.
      await mount(tester, tourWith(_bus(), const []));
      await tapLens(tester, BoardLensId.money);

      // The panel REPLACES the chart and takes the chrome with it: a colour key
      // and a running total over a bus with nobody on it are exactly the
      // "names a problem, offers no way out" shape §13 exists to kill.
      expect(find.byType(BoardEmptyPanel), findsOneWidget);
      expect(find.byType(BerthTile), findsNothing);
      expect(find.byType(BoardLegend), findsNothing);
      expect(find.byType(BoardSummaryStrip), findsNothing);

      // And it is a way OUT, not just a sentence.
      expect(find.text(tr('board_empty.action_place_riders')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a fully collected bus reads as a finished job, and keeps the '
        'chart that proves it', (tester) async {
      final (bus, riders, ids) = loaded();
      await mount(
        tester,
        tourWith(bus, riders),
        // Every rider square, so outstanding is genuinely nil.
        collections: (tour) => [
          for (var i = 0; i < riders.length; i++)
            Collection(
              tourId: tour.id,
              busId: bus.id,
              passengerId: 'p$i',
              seatId: ids[i],
              amountDue: bus.amountDueForSeat(riders[i], ids[i]),
              amountReceived: bus.amountDueForSeat(riders[i], ids[i]),
            ),
        ],
      );
      await tapLens(tester, BoardLensId.money);

      // ₹0 outstanding because the round is DONE is a different situation from
      // ₹0 because nobody set a fare, and the two must not render the same. So
      // this one is a note ABOVE a canvas that still draws — the bus of paid
      // berths is the evidence, and taking it away would lose the proof.
      expect(find.byType(BoardZeroNote), findsOneWidget);
      expect(find.byType(BoardEmptyPanel), findsNothing);
      expect(find.byType(BoardCanvas), findsOneWidget);
      expect(find.byType(BerthTile), findsWidgets);
      expect(find.byType(BoardLegend), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// Fixtures
// ─────────────────────────────────────────────────────────────────────────────

const UgamColorSet _palette = UgamColorSet(
  bg: Color(0xFF12100E),
  card: Color(0xFF1C1917),
  cardElev: Color(0xFF272220),
  border: Color(0x1AFFFFFF),
  ink: Color(0xFFF7F3EE),
  ink2: Color(0xFFA19A93),
  ink3: Color(0xFF6E655E),
  accent: Color(0xFFFFC24B),
  accentFill: Color(0x24FFC24B),
  action: Color(0xFFF7F3EE),
  onAction: Color(0xFF12100E),
  glow: Color(0x4DFFC24B),
  good: Color(0xFF4ADE9A),
  goodFill: Color(0x224ADE9A),
  warm: Color(0xFFF58BB8),
  warmFill: Color(0x29F58BB8),
  danger: Color(0xFFFF6B60),
  dangerFill: Color(0x29FF6B60),
  onAccent: Color(0xFF1A1200),
);

Bus _bus() => Bus(
  id: 'b1',
  name: 'Bus 1',
  busType: 'Sleeper',
  pricePerSeat: 1000,
  layout: BusLayout.generate(busType: BusType.sleeper, totalSeats: 30),
);

/// The first [count] berths in WALKING order — the same order the Board's
/// cursor moves in, so a fixture and the thing under test agree.
List<String> _seatIds(Bus bus, int count) => [
  for (final cell in aisleOrder(bus.layout).take(count)) cell.seatId!,
];

/// A double-sofa berth, i.e. one two riders can genuinely share.
String _sharedSeatId(Bus bus) => aisleOrder(bus.layout)
    .firstWhere((c) => c.seatType == SeatType.doubleSofa)
    .seatId!;

Passenger _rider(
  String id,
  String name,
  String busId,
  String seatId, {
  String? stopId,
  String? stopName,
  String? groupId,
  TripType leg = TripType.roundTrip,
}) => Passenger(
  id: id,
  tourId: 't1',
  name: name,
  phone: '90000000${id.hashCode.abs() % 90 + 10}',
  tripType: leg,
  groupId: groupId,
  pickupLocationId: stopId,
  pickupLocationName: stopName,
  assignedSeats: [SeatAssignment(busId: busId, seatId: seatId, leg: leg)],
);

Tour _tour({
  TourStatus status = TourStatus.assigning,
  List<Bus> buses = const [],
  List<Passenger> passengers = const [],
  List<PassengerGroup> groups = const [],
}) => Tour(
  id: 't1',
  title: 'Dwarka Yatra',
  fromCity: 'Surat',
  toCity: 'Dwarka',
  departureDate: DateTime(2026, 9, 1),
  pricePerSeat: 1000,
  status: status,
  buses: buses,
  passengers: passengers,
  groups: groups,
);

/// Skips the real network load, the realtime wiring and the lazy layout fetch,
/// so the Board can read `tours` with no live Supabase graph behind it. Same
/// shape as `tour_money_board_screen_test`'s double.
class _FakeTourController extends TourController {
  @override
  // ignore: must_call_super
  void onInit() {}

  @override
  Future<void> ensureTourReadyForSeating(String tourId) async {}
}

class _FakeMoneyController extends MoneyController {
  @override
  Future<void> loadForTour(String tourId) async {}
}
