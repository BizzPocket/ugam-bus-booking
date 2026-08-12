import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:occubusbooking/controllers/board_controller.dart';
import 'package:occubusbooking/models/board_lens.dart';
import 'package:occubusbooking/models/handler_phase.dart';
import 'package:occubusbooking/models/seat_layout.dart';
import 'package:occubusbooking/models/seat_type.dart';
import 'package:occubusbooking/utils/aisle_order.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A Board with every lens wired, for the tests that are about the phase
/// table rather than about the staged build. The production default is
/// [kShippedBoardLenses], which is deliberately narrower.
BoardController _allLenses() =>
    BoardController(availableLenses: BoardLensId.values.toSet());

/// A two-row sleeper coach.
///
/// The cells are ADDED in seat-code order (DL1, DL2, DU1 …) — the order
/// `BusLayout._regenerateIds` numbers them in — precisely so the walk tests
/// prove the aisle sort really happens instead of echoing insertion order.
/// Walking order for this bus is row by row, left wall → aisle → right wall:
///
///   row 0: SU1, SL1, DL1, DU1
///   row 1: SU2, SL2, DL2, DU2
BusLayout _coach() {
  SeatCell cell(int row, int col, SeatType type, SeatPosition pos, String id) =>
      SeatCell(row: row, col: col, seatType: type, position: pos, seatId: id);

  return BusLayout(
    rows: 2,
    cols: SeatGridCols.count,
    grid: [
      for (var row = 0; row < 2; row++) ...[
        cell(
          row,
          SeatGridCols.doubleLower,
          SeatType.doubleSofa,
          SeatPosition.lower,
          'DL${row + 1}',
        ),
        cell(
          row,
          SeatGridCols.doubleUpper,
          SeatType.doubleSofa,
          SeatPosition.upper,
          'DU${row + 1}',
        ),
        cell(
          row,
          SeatGridCols.singleLower,
          SeatType.singleSofa,
          SeatPosition.lower,
          'SL${row + 1}',
        ),
        cell(
          row,
          SeatGridCols.singleUpper,
          SeatType.singleSofa,
          SeatPosition.upper,
          'SU${row + 1}',
        ),
      ],
    ],
  );
}

const _walkOrder = ['SU1', 'SL1', 'DL1', 'DU1', 'SU2', 'SL2', 'DL2', 'DU2'];

/// A seater bus of exactly [cells] tiles — the density default's only input.
BusLayout _seaterCoach(int cells) => BusLayout(
  rows: (cells + 3) ~/ 4,
  cols: SeatGridCols.count,
  grid: [
    for (var i = 0; i < cells; i++)
      SeatCell(
        row: i ~/ 4,
        col: SeatGridCols.seaterCols[i % 4],
        seatType: SeatType.seater,
        seatId: 'ST${i + 1}',
      ),
  ],
);

/// "Still owes / still needs doing" for a fixed set of seat ids.
BerthPredicate _needs(Set<String> ids) => (cell) => ids.contains(cell.seatId);

/// A legend row with a real [BoardLegendEntry.selects] predicate. The colours
/// are irrelevant here — this is about which berths a swatch keeps lit.
BoardLegendEntry _legendRow(String id, bool Function(BoardBerth) selects) =>
    BoardLegendEntry(
      id: id,
      label: id,
      swatch: Colors.transparent,
      ink: Colors.transparent,
      glyph: '·',
      selects: selects,
    );

final _moneyLegend = <BoardLegendEntry>[
  _legendRow('paid', (b) => b.isOccupied && b.outstanding == 0),
  _legendRow('due', (b) => b.isOccupied && b.outstanding > 0),
];

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));
  tearDown(Get.reset);

  group('lens', () {
    test('the trip phase drives which lens the Board opens on', () {
      final c = _allLenses();

      // Still filling the bus — no trip state at all.
      expect(c.lens, BoardLensId.occupancy);

      c.setPhase(HandlerPhase.enRouteGo);
      expect(c.lens, BoardLensId.pickup);

      c.setPhase(HandlerPhase.settling);
      expect(c.lens, BoardLensId.money);

      expect(c.lensIsManual, isFalse);
    });

    test('every phase resolves to the model default', () {
      final c = _allLenses();
      for (final phase in <HandlerPhase?>[null, ...HandlerPhase.values]) {
        c.setPhase(phase);
        expect(
          c.lens,
          defaultLensForPhase(phase, available: BoardLensId.values.toSet()),
          reason: '$phase should open on its default lens',
        );
      }
    });

    test('daysUntilDeparture reaches the default', () {
      final c = _allLenses()..setPhase(HandlerPhase.boardingGo);
      expect(c.lens, BoardLensId.boarding);

      // Two days out, un-stamped: the job is chasing balances, not heads.
      c.setDaysUntilDeparture(2);

      expect(c.lens, BoardLensId.money);
      expect(c.phaseDefaultLens, BoardLensId.money);
    });

    test('the default never lands on a lens with no data source yet', () {
      // Production default: only the shipped lenses are available.
      final c = BoardController()..setPhase(HandlerPhase.enRouteGo);

      expect(kShippedBoardLenses.contains(BoardLensId.pickup), isFalse);
      expect(c.lens, BoardLensId.occupancy);
    });

    test('a manual choice is never overridden by a phase change', () {
      final c = _allLenses()..setPhase(HandlerPhase.enRouteGo);
      c.selectLens(BoardLensId.money);
      expect(c.lensIsManual, isTrue);

      // The trip moves on to a phase whose default is a different lens.
      c.setPhase(HandlerPhase.boardingGo);

      expect(
        c.lens,
        BoardLensId.money,
        reason: 'spec §6: a manual choice wins the session',
      );
      expect(c.phaseDefaultLens, BoardLensId.boarding);
    });

    test('a manual choice survives a change of departure date too', () {
      final c = _allLenses()..setPhase(HandlerPhase.boardingGo);
      c.selectLens(BoardLensId.occupancy);

      c.setDaysUntilDeparture(2);

      expect(c.lens, BoardLensId.occupancy);
    });

    test('choosing the lens that already equals the phase default pins it', () {
      final c = _allLenses()..setPhase(HandlerPhase.settling);
      // Same value the default would have given — but the user SAID it, so a
      // later phase change must not move them off it.
      c.selectLens(BoardLensId.money);

      c.setPhase(HandlerPhase.enRouteGo);

      expect(c.lens, BoardLensId.money);
      expect(c.lensIsManual, isTrue);
    });

    test('followPhaseLens hands the phase its default back', () {
      final c = _allLenses()..setPhase(HandlerPhase.enRouteGo);
      c.selectLens(BoardLensId.money);
      expect(c.lens, BoardLensId.money);

      c.followPhaseLens();

      expect(c.lensIsManual, isFalse);
      expect(c.lens, BoardLensId.pickup);
    });

    test('an unavailable lens cannot be selected', () {
      final c = BoardController(); // shipped lenses only

      c.selectLens(BoardLensId.group);

      expect(c.lensIsManual, isFalse);
      expect(c.lens, BoardLensId.occupancy);
    });

    test('setAvailableLenses widens the switcher and ignores an empty set', () {
      final c = BoardController()..setPhase(HandlerPhase.enRouteGo);

      c.setAvailableLenses(BoardLensId.values.toSet());
      expect(c.lens, BoardLensId.pickup);

      c.setAvailableLenses(const <BoardLensId>{});
      expect(c.lens, BoardLensId.pickup);
    });

    test('switching lens clears the legend filter and the walk cursor', () {
      final c = _allLenses()
        ..setLayout(_coach())
        ..toggleLegendFilter('due');
      c.advanceToNextOutstanding((_) => true);
      expect(c.cursor.value, 'SU1');

      c.selectLens(BoardLensId.boarding);

      expect(c.legendFilter.value, isNull);
      expect(c.cursor.value, isNull);
    });

    test('buildLens returns the active lens as an object', () {
      final c = _allLenses()..setPhase(HandlerPhase.settling);
      expect(c.buildLens().id, BoardLensId.money);

      // The tinted lenses build with no tints at all (spec §13: "no stops
      // configured" is a real state, not a crash).
      c.selectLens(BoardLensId.pickup);
      expect(c.buildLens().id, BoardLensId.pickup);
    });
  });

  group('density', () {
    test('40 berths stays comfortable and 41 goes compact', () {
      final c = BoardController()..setLayout(_seaterCoach(40));
      expect(c.berthCount, 40);
      expect(c.density, BoardDensity.comfortable);

      c.setLayout(_seaterCoach(41));

      expect(c.berthCount, 41);
      expect(c.density, BoardDensity.compact);
      expect(c.isCompact, isTrue);
    });

    test('a bus with no seat plan is comfortable, not compact', () {
      final c = BoardController();
      expect(c.berthCount, 0);
      expect(c.density, BoardDensity.comfortable);

      c.setLayout(null);

      expect(c.density, BoardDensity.comfortable);
    });

    test('a manual choice beats the berth-count default', () {
      final c = BoardController()..setLayout(_seaterCoach(74));
      expect(c.density, BoardDensity.compact);

      c.setDensity(BoardDensity.comfortable);

      expect(c.density, BoardDensity.comfortable);
      expect(c.densityIsManual, isTrue);
      // …and swiping to an even bigger bus must not undo it.
      c.setLayout(_seaterCoach(90));
      expect(c.density, BoardDensity.comfortable);
    });

    test('toggleDensity flips the derived default and then the choice', () {
      final c = BoardController()..setLayout(_seaterCoach(60));
      expect(c.density, BoardDensity.compact);

      c.toggleDensity();
      expect(c.density, BoardDensity.comfortable);

      c.toggleDensity();
      expect(c.density, BoardDensity.compact);
    });

    test('the choice is written to shared_preferences', () async {
      final c = BoardController();
      c.setDensity(BoardDensity.compact);
      await pumpEventQueue();

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(BoardController.densityPrefKey), 'compact');
    });

    test('a stored choice is restored on load', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        BoardController.densityPrefKey: 'compact',
      });
      // Nothing about this bus asks for compact — only the remembered choice.
      final c = BoardController()..setLayout(_seaterCoach(10));

      await c.loadDensityPreference();

      expect(c.density, BoardDensity.compact);
      expect(c.densityIsManual, isTrue);
    });

    test('onInit restores the stored choice', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        BoardController.densityPrefKey: 'compact',
      });
      final c = Get.put(BoardController());
      await pumpEventQueue();

      expect(c.density, BoardDensity.compact);
    });

    test('a load in flight never clobbers a choice made meanwhile', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        BoardController.densityPrefKey: 'comfortable',
      });
      final c = BoardController();
      final inFlight = c.loadDensityPreference();
      // The user toggles during the very first frame, before prefs answered.
      c.setDensity(BoardDensity.compact);
      await inFlight;

      expect(c.density, BoardDensity.compact);
    });

    test('an unrecognised stored value falls back to the berth count', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        BoardController.densityPrefKey: 'roomy',
      });
      final c = BoardController()..setLayout(_seaterCoach(74));

      await c.loadDensityPreference();

      expect(c.densityIsManual, isFalse);
      expect(c.density, BoardDensity.compact);
    });
  });

  group('legend filter', () {
    test('tapping a swatch filters, tapping it again clears', () {
      final c = BoardController();
      expect(c.isFiltering, isFalse);

      c.toggleLegendFilter('due');
      expect(c.legendFilter.value, 'due');
      expect(c.isLegendActive('due'), isTrue);
      expect(c.isFiltering, isTrue);

      c.toggleLegendFilter('due');
      expect(c.legendFilter.value, isNull);
      expect(c.isFiltering, isFalse);
    });

    test('tapping a different swatch replaces the filter', () {
      final c = BoardController()..toggleLegendFilter('due');

      c.toggleLegendFilter('paid');

      expect(c.legendFilter.value, 'paid');
      expect(c.isLegendActive('due'), isFalse);
    });

    test('a filter dims every berth outside its bucket', () {
      final c = BoardController()..toggleLegendFilter('due');

      expect(c.isDimmed(legendKey: 'due'), isFalse);
      expect(c.isDimmed(legendKey: 'paid'), isTrue);
      // A berth the lens buckets nowhere is dimmed too.
      expect(c.isDimmed(), isTrue);
    });

    test('nothing is dimmed with no filter and no search', () {
      final c = BoardController();
      expect(c.isDimmed(legendKey: 'paid'), isFalse);
      expect(c.isDimmed(), isFalse);
    });
  });

  group('search', () {
    test('an empty query is not a search and highlights nothing', () {
      final c = BoardController();
      expect(c.isSearching, isFalse);
      expect(c.isSearchHit(['Ramesh']), isFalse);
      // Everything "matches" an empty query so callers need no special case.
      expect(c.matchesSearch(['Ramesh']), isTrue);
    });

    test('whitespace alone is not a search', () {
      final c = BoardController()..setSearch('   ');
      expect(c.isSearching, isFalse);
      expect(c.isDimmed(searchFields: ['Ramesh']), isFalse);
    });

    test('a hit is case-insensitive and spans every field', () {
      final c = BoardController()..setSearch('RAM');
      expect(c.isSearchHit(['ramesh patel', '9876543210']), isTrue);
      expect(c.isSearchHit([null, '', 'Priti']), isFalse);
      expect(c.isSearchHit(['DL3', '9812345670']), isFalse);
    });

    test('search dims the misses and leaves the hits lit', () {
      final c = BoardController()..setSearch('priti');
      expect(c.isDimmed(searchFields: ['Priti Patel']), isFalse);
      expect(c.isDimmed(searchFields: ['Ramesh Shah']), isTrue);
    });

    test('filter and search dim independently', () {
      final c = BoardController()
        ..toggleLegendFilter('due')
        ..setSearch('priti');

      // A hit in the wrong bucket is still dimmed.
      expect(
        c.isDimmed(legendKey: 'paid', searchFields: ['Priti Patel']),
        isTrue,
      );
      // Right bucket, wrong name — also dimmed.
      expect(
        c.isDimmed(legendKey: 'due', searchFields: ['Ramesh Shah']),
        isTrue,
      );
      // Only both together stay lit.
      expect(
        c.isDimmed(legendKey: 'due', searchFields: ['Priti Patel']),
        isFalse,
      );
    });

    test('clearSearch restores everything', () {
      final c = BoardController()..setSearch('priti');

      c.clearSearch();

      expect(c.isSearching, isFalse);
      expect(c.isDimmed(searchFields: ['Ramesh Shah']), isFalse);
    });
  });

  group('berth dimming', () {
    const paid = BoardBerth(
      code: 'DL1',
      isOccupied: true,
      occupantName: 'Priti Patel',
      fareDue: 550,
      paid: 550,
    );
    const due = BoardBerth(
      code: 'DL2',
      isOccupied: true,
      occupantName: 'Ramesh Shah',
      fareDue: 550,
    );

    test('a swatch keeps only the berths its own predicate selects', () {
      final c = BoardController()..toggleLegendFilter('due');

      expect(c.isBerthDimmed(due, _moneyLegend), isFalse);
      expect(c.isBerthDimmed(paid, _moneyLegend), isTrue);
    });

    test('a filter id this legend does not have dims nothing', () {
      // The lens changed under a live filter: black out the swatch, never the
      // whole coach.
      final c = BoardController()..toggleLegendFilter('no-such-row');

      expect(c.isBerthDimmed(due, _moneyLegend), isFalse);
      expect(c.isBerthDimmed(paid, _moneyLegend), isFalse);
    });

    test('search reads the berth code and the occupant name', () {
      final c = BoardController()..setSearch('ramesh');
      expect(c.isBerthSearchHit(due), isTrue);
      expect(c.isBerthSearchHit(paid), isFalse);

      c.setSearch('dl1');
      expect(c.isBerthSearchHit(paid), isTrue);
    });

    test('a filtered-in berth that misses the search still dims', () {
      final c = BoardController()
        ..toggleLegendFilter('due')
        ..setSearch('priti');

      expect(c.isBerthDimmed(due, _moneyLegend), isTrue);
    });
  });

  group('buses', () {
    test('the index is clamped to the bus count', () {
      final c = BoardController()..setBusCount(3);

      c.setBusIndex(9);
      expect(c.busIndex.value, 2);

      c.setBusIndex(-4);
      expect(c.busIndex.value, 0);
    });

    test('a single-bus tour is not multi-bus', () {
      final c = BoardController();
      expect(c.isMultiBus, isFalse);

      c.setBusCount(2);

      expect(c.isMultiBus, isTrue);
    });

    test('losing a bus pulls the index back into range', () {
      final c = BoardController()..setBusCount(3);
      c.setBusIndex(2);

      c.setBusCount(1);

      expect(c.busCount.value, 1);
      expect(c.busIndex.value, 0);
    });

    test('switching bus drops the selection and the walk cursor', () {
      final c = BoardController()
        ..setBusCount(2)
        ..setLayout(_coach())
        ..beginMultiSelect('SU1');
      c.advanceToNextOutstanding((_) => true);
      expect(c.cursor.value, 'SU1');

      c.setBusIndex(1);

      expect(c.selection, isEmpty);
      expect(c.isMultiSelecting, isFalse);
      expect(c.cursor.value, isNull);
    });
  });

  group('multi-select', () {
    test('a long-press enters the mode and takes its berth with it', () {
      final c = BoardController();
      expect(c.isMultiSelecting, isFalse);

      c.beginMultiSelect('DL3');

      expect(c.isMultiSelecting, isTrue);
      expect(c.isSelected('DL3'), isTrue);
      expect(c.selectedCount, 1);
    });

    test('tapping adds and removes berths', () {
      final c = BoardController()..beginMultiSelect('DL3');

      c.toggleSelected('DL4');
      c.toggleSelected('SU1');
      expect(c.selectedCount, 3);

      c.toggleSelected('DL4');
      expect(c.isSelected('DL4'), isFalse);
      expect(c.selectedCount, 2);
    });

    test('deselecting the last berth leaves multi-select mode', () {
      final c = BoardController()..beginMultiSelect('DL3');

      c.toggleSelected('DL3');

      expect(c.selection, isEmpty);
      expect(c.isMultiSelecting, isFalse);
    });

    test('clearSelection exits the mode', () {
      final c = BoardController()..beginMultiSelect('DL3');
      c.toggleSelected('DL4');

      c.clearSelection();

      expect(c.selection, isEmpty);
      expect(c.isMultiSelecting, isFalse);
    });
  });

  group('next outstanding', () {
    test('advances in walking order, not seat-code order', () {
      final c = BoardController()..setLayout(_coach());
      final visited = <String?>[];

      for (var i = 0; i < _walkOrder.length; i++) {
        visited.add(c.advanceToNextOutstanding((_) => true)?.seatId);
      }

      expect(visited, _walkOrder);
      expect(c.cursorIndex, _walkOrder.length - 1);
      expect(c.cursorBerth?.seatId, _walkOrder.last);
    });

    test('the round ends when the last outstanding berth is cleared', () {
      final c = BoardController()..setLayout(_coach());
      final owing = <String>{'SL1', 'DL2'};

      expect(c.advanceToNextOutstanding(_needs(owing))?.seatId, 'SL1');
      owing.remove('SL1'); // collected
      expect(c.advanceToNextOutstanding(_needs(owing))?.seatId, 'DL2');
      owing.remove('DL2'); // collected

      // Round complete: nothing left anywhere on the bus.
      expect(c.advanceToNextOutstanding(_needs(owing)), isNull);
      expect(c.hasNextOutstanding(_needs(owing)), isFalse);
      // The cursor holds so the strip can still say where the walk finished.
      expect(c.cursor.value, 'DL2');
    });

    test('the wrap brings a late starter back to the front of the bus', () {
      final c = BoardController()..setLayout(_coach());
      // Flagged down at the back before the round even started.
      c.setCursor('DL2');

      expect(c.advanceToNextOutstanding(_needs({'SU1'}))?.seatId, 'SU1');
    });

    test('wrap: false stops dead at the back of the bus', () {
      final c = BoardController()..setLayout(_coach());
      c.setCursor('DL2');

      expect(
        c.advanceToNextOutstanding(_needs({'SU1'}), wrap: false),
        isNull,
      );
      expect(c.cursor.value, 'DL2');
    });

    test('the berth under the cursor is never handed back', () {
      final c = BoardController()..setLayout(_coach());
      c.setCursor('DL1');

      // DL1 still owes, but "next" means next — a second tap must move on.
      expect(c.advanceToNextOutstanding(_needs({'DL1'})), isNull);
      expect(c.cursor.value, 'DL1');
    });

    test('a bus with nothing outstanding never starts the walk', () {
      final c = BoardController()..setLayout(_coach());

      expect(c.advanceToNextOutstanding((_) => false), isNull);
      expect(c.cursor.value, isNull);
      expect(c.cursorIndex, isNull);
    });

    test('a bus with no seat plan is safe to advance', () {
      final c = BoardController();

      expect(c.advanceToNextOutstanding((_) => true), isNull);
      expect(c.outstandingCount((_) => true), 0);
      expect(c.cursor.value, isNull);
    });

    test('peek reports the next berth without moving the cursor', () {
      final c = BoardController()..setLayout(_coach());

      expect(c.peekNextOutstanding(_needs({'DU1'}))?.seatId, 'DU1');
      expect(c.hasNextOutstanding(_needs({'DU1'})), isTrue);
      expect(c.cursor.value, isNull);
    });

    test('outstandingCount counts the whole bus, cursor or not', () {
      final c = BoardController()..setLayout(_coach());
      c.advanceToNextOutstanding(_needs({'SU1', 'DL2'}));

      expect(c.outstandingCount(_needs({'SU1', 'DL2'})), 2);
      expect(c.outstandingCount((_) => true), _walkOrder.length);
    });

    test('resetCursor sends the walk back to the front', () {
      final c = BoardController()..setLayout(_coach());
      final owing = {'SL1', 'DL1'};
      c.advanceToNextOutstanding(_needs(owing));
      c.advanceToNextOutstanding(_needs(owing));
      expect(c.cursor.value, 'DL1');

      c.resetCursor();

      expect(c.cursor.value, isNull);
      expect(c.advanceToNextOutstanding(_needs(owing))?.seatId, 'SL1');
    });

    test('rewind steps back up the aisle', () {
      final c = BoardController()..setLayout(_coach());
      final owing = {'SL1', 'DL1'};
      c.advanceToNextOutstanding(_needs(owing));
      c.advanceToNextOutstanding(_needs(owing));
      expect(c.cursor.value, 'DL1');

      expect(c.rewindToPreviousOutstanding(_needs(owing))?.seatId, 'SL1');
      expect(c.cursor.value, 'SL1');
    });

    test('a new chart drops a cursor its berths do not contain', () {
      final c = BoardController()..setLayout(_coach());
      c.advanceToNextOutstanding(_needs({'DL1'}));
      expect(c.cursor.value, 'DL1');

      // Swipe to a bus with a completely different chart.
      c.setLayout(_seaterCoach(3));

      expect(c.cursor.value, isNull);
      expect(c.advanceToNextOutstanding((_) => true)?.seatId, 'ST1');
    });

    test('a re-read of the same chart keeps the walk where it was', () {
      final c = BoardController()..setLayout(_coach());
      c.advanceToNextOutstanding(_needs({'DL1'}));

      c.setLayout(_coach());

      expect(c.cursor.value, 'DL1');
    });

    test('setCursor ignores a berth this bus does not have', () {
      final c = BoardController()..setLayout(_coach());
      c.setCursor('SL1');

      c.setCursor('ST9');

      expect(c.cursor.value, 'SL1');
    });
  });
}
