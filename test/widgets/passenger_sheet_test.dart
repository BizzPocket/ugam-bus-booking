import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:occubusbooking/controllers/tour_controller.dart';
import 'package:occubusbooking/design/components/ugam_button.dart';
import 'package:occubusbooking/design/components/ugam_snackbar.dart';
import 'package:occubusbooking/models/board_lens.dart';
import 'package:occubusbooking/models/bus_details.dart';
import 'package:occubusbooking/models/bus_type.dart';
import 'package:occubusbooking/models/passenger.dart';
import 'package:occubusbooking/models/request_line.dart';
import 'package:occubusbooking/models/seat_layout.dart';
import 'package:occubusbooking/models/seat_type.dart';
import 'package:occubusbooking/models/tour.dart';
import 'package:occubusbooking/models/trip_type.dart';
import 'package:occubusbooking/widgets/board/passenger_sheet.dart';

/// Skips the real `onInit`, which reaches for Supabase.
class _FakeTourController extends TourController {
  @override
  // ignore: must_call_super
  void onInit() {}
}

/// The Board's one passenger sheet (interaction spec §5, §8, §11).
///
/// Three things are load-bearing and therefore pinned here:
///
///  1. **The primary action swaps by lens.** That single mechanism is what lets
///     one sheet replace what `occupant_action_sheet`, `seating_exceptions`
///     and part of `requests_screen` each do differently today. If Collect ever
///     stops being primary under the money lens, the Board is five sheets
///     again.
///  2. **Every field renders.** Losing a field here is a regression against a
///     screen that already showed it.
///  3. **Money confirms first** (spec §8) — a collection cannot be silently
///     reversed downstream, so it must never fire straight off the tap.
///
/// EasyLocalization is not initialised under `flutter test`, so `tr()` returns
/// the raw key and `namedArgs` are not substituted. Assertions therefore use
/// the stable un-localized keys for copy, and real values (names, berth codes,
/// rupee figures) wherever the sheet renders data rather than copy.
Passenger _passenger({
  String id = 'p1',
  String name = 'Priti Patel',
  String phone = '9876543210',
  TripType leg = TripType.roundTrip,
  String? note,
}) => Passenger(
  id: id,
  tourId: 't1',
  name: name,
  phone: phone,
  note: note,
  requestLines: [RequestLine(seatType: SeatType.doubleSofa, qty: 1, leg: leg)],
);

BoardBerth _berth({
  String code = 'DL3',
  double fare = 1200,
  double paid = 650,
  BerthBoarding boarding = BerthBoarding.expected,
  String? pickup = 'Adajan',
  String? group = 'Patel family',
  bool ladies = false,
}) => BoardBerth(
  code: code,
  isOccupied: true,
  occupantName: 'Priti Patel',
  isLadies: ladies,
  fareDue: fare,
  paid: paid,
  pickupStopId: 'stop-1',
  pickupStopName: pickup,
  groupId: 'grp-1',
  groupName: group,
  boarding: boarding,
  seatTypeLabel: 'Double Sofa',
);

/// Pumps the sheet body directly — no bottom-sheet host — so the whole tree is
/// readable. A `MaterialApp` still supplies the Navigator + Overlay the confirm
/// dialog and the undo toast need.
///
/// Width is pinned at 390 (the [UgamScale] baseline) so the two-column fact
/// grid is exercised; height is left to the 600pt test surface, and the sheet's
/// own scroll view carries the overflow — which is why every tap below the fold
/// goes through [_tapRow].
Widget _host(Widget sheet) => MaterialApp(
  theme: ThemeData(brightness: Brightness.dark),
  home: Scaffold(body: Center(child: SizedBox(width: 390, child: sheet))),
);

/// Taps a secondary action row, scrolling the sheet to it first. A real sheet
/// is a scrollable column and the rows below the fold are reached by scrolling,
/// not by a bigger window.
Future<void> _tapRow(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

/// Waits out the toast's own dwell — which both keeps its timer from outliving
/// the test and proves the toast takes itself off screen. [actionDuration] is
/// the longer of the two dwells, so this covers a plain confirmation too.
Future<void> _letToastExpire(WidgetTester tester) async {
  await tester.pump(UgamSnackbar.actionDuration + const Duration(seconds: 1));
  await tester.pumpAndSettle();
  expect(find.byType(UgamSnackbar), findsNothing);
}

PassengerSheet _sheet({
  required BoardLens lens,
  BoardBerth? berth,
  Passenger? passenger,
  List<PassengerSheetOccupant>? occupants,
  Future<PassengerSheetUndo?> Function(double amount)? onCollect,
  Future<PassengerSheetUndo?> Function(bool boarded)? onCheckIn,
  Future<PassengerSheetUndo?> Function(double amount)? onReturnChange,
}) => PassengerSheet(
  occupants:
      occupants ??
      [
        PassengerSheetOccupant(
          berth: berth ?? _berth(),
          passenger: passenger ?? _passenger(),
        ),
      ],
  lens: lens,
  tourId: 't1',
  busId: 'b1',
  busName: 'Bus 1',
  seatId: 'DL3',
  onCollect: onCollect,
  onCheckIn: onCheckIn,
  onReturnChange: onReturnChange,
);

/// The label inside the ONE primary [UgamButton] — the lens's action.
Finder _primaryLabel(String key) => find.descendant(
  of: find.byType(UgamButton),
  matching: find.text(key),
);

void main() {
  tearDown(() {
    BoardUndoToast.dismiss();
    Get.reset();
  });

  group('the primary action swaps by lens (spec §5)', () {
    // Occupancy → Call · Money → Collect · Boarding → Check in · Group → Move.
    final cases = <String, (BoardLens, String)>{
      'occupancy': (const OccupancyLens(), 'board_lens.action_call'),
      'money': (const MoneyLens(), 'board_lens.action_collect'),
      'boarding': (const BoardingLens(), 'board_lens.action_check_in'),
      'group': (const GroupLens(), 'board_lens.action_move'),
      'pickup': (const PickupLens(), 'board_lens.action_call'),
    };

    for (final entry in cases.entries) {
      testWidgets('${entry.key} lens puts ${entry.value.$2} under the thumb', (
        tester,
      ) async {
        final (lens, expected) = entry.value;
        await tester.pumpWidget(
          _host(
            _sheet(
              lens: lens,
              onCollect: (_) async => null,
              onCheckIn: (_) async => null,
            ),
          ),
        );
        await tester.pump();

        // Exactly one button, carrying this lens's action.
        expect(find.byType(UgamButton), findsOneWidget);
        expect(_primaryLabel(expected), findsOneWidget);

        // Every OTHER action is still reachable — the sheet re-ranks
        // capabilities, it never removes them.
        for (final other in BoardAction.values) {
          if (other.label == expected) continue;
          expect(
            find.text(other.label),
            findsOneWidget,
            reason: '${other.name} must stay available as a secondary row',
          );
          expect(
            _primaryLabel(other.label),
            findsNothing,
            reason: '${other.name} is not primary under ${entry.key}',
          );
        }

        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('a primary whose capability is missing renders disabled', (
      tester,
    ) async {
      // Money lens with no collect handler wired: the button is still the
      // money action (the lens decides that), but it cannot be pressed.
      await tester.pumpWidget(_host(_sheet(lens: const MoneyLens())));
      await tester.pump();

      expect(_primaryLabel('board_lens.action_collect'), findsOneWidget);
      final button = tester.widget<UgamButton>(find.byType(UgamButton));
      expect(button.onPressed, isNull);
    });

    testWidgets('a fully paid berth cannot be collected from again', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          _sheet(
            lens: const MoneyLens(),
            berth: _berth(fare: 1200, paid: 1200),
            onCollect: (_) async => null,
          ),
        ),
      );
      await tester.pump();

      expect(
        tester.widget<UgamButton>(find.byType(UgamButton)).onPressed,
        isNull,
      );
    });
  });

  group('every passenger field renders', () {
    testWidgets('name, berth code and type, leg, payment, phone, '
        'pickup, group and fare are all on screen', (tester) async {
      await tester.pumpWidget(
        _host(_sheet(lens: const OccupancyLens(), onCollect: (_) async => null)),
      );
      await tester.pump();

      // Identity.
      expect(find.text('Priti Patel'), findsOneWidget);
      // Berth code — a chip of its own, not only inside a translated sentence.
      expect(find.text('DL3'), findsOneWidget);
      expect(find.text('Double Sofa'), findsOneWidget);

      // Leg — read from the request lines, not the raw tripType column.
      expect(find.text('seat_detail.indicator.round_trip'), findsOneWidget);

      // Payment state, in words, under a NON-money lens: the fact belongs to
      // the passenger, not to how you happen to be looking at them.
      expect(find.text('board_lens.state_half_amount'), findsOneWidget);

      // Phone — visible, so it can be read out, and one tap to dial.
      expect(find.text('9876543210'), findsOneWidget);

      // Pickup point and group.
      expect(find.text('Adajan'), findsOneWidget);
      expect(find.text('Patel family'), findsOneWidget);

      // Money: fare, what is in, what is left.
      expect(find.text('₹1,200'), findsOneWidget);
      expect(find.text('₹650'), findsWidgets);
      expect(find.text('₹550'), findsWidgets);

      expect(tester.takeException(), isNull);
    });

    testWidgets('a berth with no pickup and no group says so rather than '
        'rendering a blank', (tester) async {
      await tester.pumpWidget(
        _host(
          _sheet(
            lens: const OccupancyLens(),
            berth: _berth(pickup: null, group: null),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('board_lens.state_no_stop'), findsOneWidget);
      expect(find.text('board_lens.state_no_group'), findsOneWidget);
    });

    testWidgets('a shared sofa surfaces BOTH occupants and retargets the '
        'sheet to whoever is selected', (tester) async {
      await tester.pumpWidget(
        _host(
          _sheet(
            lens: const OccupancyLens(),
            occupants: [
              PassengerSheetOccupant(
                berth: _berth(code: 'DS1'),
                passenger: _passenger(id: 'go', name: 'Asha'),
              ),
              PassengerSheetOccupant(
                berth: _berth(code: 'DS1', fare: 900, paid: 0),
                passenger: _passenger(
                  id: 'ret',
                  name: 'Bina',
                  phone: '9000000001',
                ),
              ),
            ],
          ),
        ),
      );
      await tester.pump();

      // Both names are offered; Asha's number is showing.
      expect(find.text('Asha'), findsWidgets);
      expect(find.text('Bina'), findsWidgets);
      expect(find.text('9876543210'), findsOneWidget);

      await tester.tap(find.text('Bina').last);
      await tester.pumpAndSettle();

      // The whole sheet now describes Bina.
      expect(find.text('9000000001'), findsOneWidget);
      expect(find.text('₹900'), findsWidgets);
    });

    testWidgets('the header carries one full spec §11 semantic label', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(_host(_sheet(lens: const MoneyLens())));
      await tester.pump();

      // "DL3, Priti Patel, <state>, Double Sofa, <at stop>, Bus 1" — never
      // just "DL3", and never four disconnected fragments.
      final expected = const MoneyLens().semanticLabel(_berth());
      expect(find.bySemanticsLabel('$expected, Bus 1'), findsOneWidget);

      handle.dispose();
    });

    testWidgets('the rider\'s own note is carried over from the requests '
        'roster — the handler at the door is who needs it', (tester) async {
      await tester.pumpWidget(
        _host(
          _sheet(
            lens: const BoardingLens(),
            passenger: _passenger(note: 'Boarding at Kim, not Adajan'),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('"Boarding at Kim, not Adajan"'), findsOneWidget);
    });

    testWidgets('a rider with no note gets no empty quote box', (tester) async {
      await tester.pumpWidget(_host(_sheet(lens: const BoardingLens())));
      await tester.pump();

      expect(find.byIcon(Icons.chat_bubble_outline_rounded), findsNothing);
    });

    testWidgets('a ladies berth still says so on a lens that does not '
        'colour by it (spec §11)', (tester) async {
      // Only the occupancy lens paints the rose fill. On money, the fact would
      // otherwise vanish with the colour that was carrying it.
      await tester.pumpWidget(
        _host(_sheet(lens: const MoneyLens(), berth: _berth(ladies: true))),
      );
      await tester.pump();

      expect(find.text('BOARD_LENS.STATE_LADIES'), findsOneWidget);
    });

    testWidgets('the occupancy lens does not say ladies twice', (tester) async {
      // Its own state chip already reads "ladies", so the extra chip is
      // suppressed — without that gate this finds two.
      await tester.pumpWidget(
        _host(_sheet(lens: const OccupancyLens(), berth: _berth(ladies: true))),
      );
      await tester.pump();

      expect(find.text('BOARD_LENS.STATE_LADIES'), findsOneWidget);
    });

    testWidgets('ladies reaches the screen reader too, not just the chip', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        _host(_sheet(lens: const MoneyLens(), berth: _berth(ladies: true))),
      );
      await tester.pump();

      expect(
        find.bySemanticsLabel(RegExp('board_lens.state_ladies')),
        findsOneWidget,
      );
      handle.dispose();
    });

    testWidgets('the phone row is one tap and announces what it dials', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(_host(_sheet(lens: const OccupancyLens())));
      await tester.pump();

      expect(find.bySemanticsLabel('seat_detail.call_a11y'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('a passenger with no phone on file says so instead of '
        'offering a dead call row', (tester) async {
      await tester.pumpWidget(
        _host(
          _sheet(
            lens: const OccupancyLens(),
            passenger: _passenger(phone: ''),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('seat_detail.roster.no_mobile'), findsOneWidget);
      // Call is the occupancy lens's primary, and it must be disabled.
      expect(
        tester.widget<UgamButton>(find.byType(UgamButton)).onPressed,
        isNull,
      );
    });
  });

  group('money actions require confirmation (spec §8)', () {
    testWidgets('tapping Collect opens a confirm and writes nothing yet', (
      tester,
    ) async {
      var collected = 0;
      await tester.pumpWidget(
        _host(
          _sheet(
            lens: const MoneyLens(),
            onCollect: (amount) async {
              collected++;
              return null;
            },
          ),
        ),
      );
      await tester.pump();

      await tester.tap(_primaryLabel('board_lens.action_collect'));
      await tester.pumpAndSettle();

      expect(find.text('passenger_sheet.confirm_collect_title'), findsOneWidget);
      expect(collected, 0, reason: 'cash must never move off a single tap');
    });

    testWidgets('cancelling the confirm leaves the money alone', (
      tester,
    ) async {
      var collected = 0;
      await tester.pumpWidget(
        _host(
          _sheet(
            lens: const MoneyLens(),
            onCollect: (amount) async {
              collected++;
              return null;
            },
          ),
        ),
      );
      await tester.pump();

      await tester.tap(_primaryLabel('board_lens.action_collect'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('app.action.cancel'));
      await tester.pumpAndSettle();

      expect(collected, 0);
      expect(find.text('passenger_sheet.confirm_collect_title'), findsNothing);
    });

    testWidgets('confirming collects exactly the outstanding amount and '
        'raises an undo (spec §8)', (tester) async {
      double? collectedAmount;
      var undone = 0;

      await tester.pumpWidget(
        _host(
          _sheet(
            lens: const MoneyLens(),
            onCollect: (amount) async {
              collectedAmount = amount;
              return PassengerSheetUndo(
                message: 'Collected ₹550 from Priti Patel',
                undo: () => undone++,
              );
            },
          ),
        ),
      );
      await tester.pump();

      await tester.tap(_primaryLabel('board_lens.action_collect'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('passenger_sheet.confirm_collect_action'));
      await tester.pumpAndSettle();

      // 1200 billed - 650 in = 550 outstanding, never the whole fare.
      expect(collectedAmount, 550);

      // The toast is the only place the write can be caught before it syncs.
      expect(find.byType(UgamSnackbar), findsOneWidget);
      expect(find.text('Collected ₹550 from Priti Patel'), findsOneWidget);
      expect(find.text('actions.undo'), findsOneWidget);

      await tester.tap(find.text('actions.undo'));
      await tester.pumpAndSettle();

      expect(undone, 1);
      expect(find.byType(UgamSnackbar), findsNothing);
    });

    testWidgets('returning change confirms too, and hands back only the '
        'over-collected amount', (tester) async {
      double? returned;
      await tester.pumpWidget(
        _host(
          _sheet(
            lens: const MoneyLens(),
            berth: _berth(fare: 1000, paid: 1200),
            onReturnChange: (amount) async {
              returned = amount;
              return null;
            },
          ),
        ),
      );
      await tester.pump();

      await _tapRow(
        tester,
        find.text('passenger_sheet.action_return_change'),
      );

      expect(find.text('passenger_sheet.confirm_return_title'), findsOneWidget);
      expect(returned, isNull);

      await tester.tap(find.text('passenger_sheet.confirm_return_action'));
      await tester.pumpAndSettle();

      expect(returned, 200);
      // No undo handed back → a plain confirmation, not a lying undo button.
      expect(find.byType(UgamSnackbar), findsOneWidget);
      expect(find.text('actions.undo'), findsNothing);

      await _letToastExpire(tester);
    });
  });

  // Everything the occupant action sheet offers today has to survive the move
  // to the Board, or the collapse is a downgrade. These rows need the live
  // roster, so they appear only once a TourController is registered — which is
  // also why the sheet degrades instead of throwing without one.
  group('no capability is lost from the occupant action sheet', () {
    testWidgets('with a live tour, move/edit/priority/handler/free are all '
        'still reachable', (tester) async {
      final ctrl = _FakeTourController();
      Get.put<TourController>(ctrl);
      final rider = _passenger();
      ctrl.tours.assignAll([
        Tour(
          id: 't1',
          title: 'test',
          fromCity: 'A',
          toCity: 'B',
          departureDate: DateTime(2026, 8, 20),
          pricePerSeat: 1200,
          buses: [
            Bus(
              id: 'b1',
              name: 'Bus 1',
              busType: 'Sleeper',
              layout: BusLayout.generate(
                busType: BusType.sleeper,
                totalSeats: 10,
              ),
            ),
          ],
          passengers: [rider],
        ),
      ]);

      await tester.pumpWidget(
        _host(_sheet(lens: const OccupancyLens(), passenger: rider)),
      );
      await tester.pump();

      expect(find.text('board_lens.action_move'), findsOneWidget);
      expect(find.text('occupant_sheet.edit_request'), findsOneWidget);
      expect(find.text('occupant.make_priority'), findsOneWidget);
      expect(find.text('occupant.make_handler'), findsOneWidget);
      expect(find.text('occupant_sheet.free'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('without a controller the roster rows are dropped rather '
        'than thrown', (tester) async {
      await tester.pumpWidget(_host(_sheet(lens: const OccupancyLens())));
      await tester.pump();

      expect(find.text('occupant_sheet.edit_request'), findsNothing);
      expect(find.text('occupant.make_priority'), findsNothing);
      // Move needs the controller too, so it is present but inert.
      expect(find.text('board_lens.action_move'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('presentation', () {
    testWidgets('show() opens on UgamSheet and pops the completed action so '
        'the Board can auto-advance the aisle walk (spec §4)', (tester) async {
      PassengerSheetResult? result;

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(brightness: Brightness.dark),
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: ElevatedButton(
                  onPressed: () async {
                    result = await PassengerSheet.show(
                      context,
                      occupants: [
                        PassengerSheetOccupant(
                          berth: _berth(),
                          passenger: _passenger(),
                        ),
                      ],
                      lens: const BoardingLens(),
                      tourId: 't1',
                      busId: 'b1',
                      busName: 'Bus 1',
                      seatId: 'DL3',
                      onCheckIn: (_) async => null,
                    );
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.byType(PassengerSheet), findsOneWidget);
      expect(find.text('Priti Patel'), findsOneWidget);

      await tester.tap(_primaryLabel('board_lens.action_check_in'));
      await tester.pumpAndSettle();

      expect(find.byType(PassengerSheet), findsNothing);
      expect(result?.action, BoardAction.checkIn);
      expect(result?.completed, isTrue);

      // The toast outlives the sheet that raised it — that is the whole point
      // of hosting it in the ROOT overlay.
      expect(find.byType(UgamSnackbar), findsOneWidget);
      await _letToastExpire(tester);
    });

    testWidgets('show() with nobody on the berth presents nothing', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () => PassengerSheet.show(
                  context,
                  occupants: const [],
                  lens: const OccupancyLens(),
                  tourId: 't1',
                  busId: 'b1',
                  busName: 'Bus 1',
                  seatId: 'DL3',
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.byType(PassengerSheet), findsNothing);
    });
  });

  group('check-in', () {
    testWidgets('check-in fires straight off the tap — it is not money', (
      tester,
    ) async {
      bool? boarded;
      await tester.pumpWidget(
        _host(
          _sheet(
            lens: const BoardingLens(),
            onCheckIn: (value) async {
              boarded = value;
              return PassengerSheetUndo(message: 'aboard', undo: () {});
            },
          ),
        ),
      );
      await tester.pump();

      await tester.tap(_primaryLabel('board_lens.action_check_in'));
      await tester.pumpAndSettle();

      expect(boarded, isTrue);
      expect(find.text('actions.undo'), findsOneWidget);

      await _letToastExpire(tester);
    });

    testWidgets('an already-boarded rider offers the correction instead', (
      tester,
    ) async {
      bool? boarded;
      await tester.pumpWidget(
        _host(
          _sheet(
            lens: const BoardingLens(),
            berth: _berth(boarding: BerthBoarding.boarded),
            onCheckIn: (value) async {
              boarded = value;
              return null;
            },
          ),
        ),
      );
      await tester.pump();

      // The lens still names the primary, but there is nothing left to do.
      expect(
        tester.widget<UgamButton>(find.byType(UgamButton)).onPressed,
        isNull,
      );

      await _tapRow(tester, find.text('passenger_sheet.action_undo_check_in'));

      expect(boarded, isFalse);

      await _letToastExpire(tester);
    });
  });
}
