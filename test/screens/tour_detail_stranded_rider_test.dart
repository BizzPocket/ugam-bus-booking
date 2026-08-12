import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:occubusbooking/controllers/tour_controller.dart';
import 'package:occubusbooking/models/bus_details.dart';
import 'package:occubusbooking/models/bus_type.dart';
import 'package:occubusbooking/models/passenger.dart';
import 'package:occubusbooking/models/request_line.dart';
import 'package:occubusbooking/models/seat_assignment.dart';
import 'package:occubusbooking/models/seat_layout.dart';
import 'package:occubusbooking/models/seat_type.dart';
import 'package:occubusbooking/models/tour.dart';
import 'package:occubusbooking/models/tour_status.dart';
import 'package:occubusbooking/models/trip_type.dart';
import 'package:occubusbooking/screens/tour_detail_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The STRANDED RIDER on the tour-detail admin prompts.
///
/// *** THE BUG ***
/// An organiser removes a rider's seat after the tour is locked. That rider has
/// already been sent "you have seat DL3" on WhatsApp, and it is now false.
/// [Passenger.seatsChangedSinceNotified] is deliberately FALSE once a rider
/// holds no seat, and every admin prompt here filtered on
/// `assignedSeats.isNotEmpty && seatsChangedSinceNotified` — so the one person
/// holding a wrong confirmation was invisible on every surface that could have
/// corrected it. They turn up on the day expecting a berth.
///
/// The prompts now ask [Passenger.notifiedSeatsAreStale] instead.
///
/// *** WHY THE PROMPT ALSO HAD TO BE RE-RANKED, NOT JUST RE-PREDICATED ***
/// Taking the seat back also makes that rider's berths unassigned again, so
/// `tour.pendingSeatsToAssign` goes up and the higher-ranked "N seats to place"
/// branch answered first — the stale-notification check below it was
/// unreachable for a withdrawal, and swapping its predicate alone would have
/// been dead code. The withdrawal now outranks the seat count it creates,
/// because silently re-seating the rider does not undo the wrong seat number
/// already in their hand.
///
/// *** WHY THE COPY DIFFERS FROM "re-notify" ***
/// There is no approved WhatsApp template for a withdrawal, so Notify cannot
/// send these riders anything — it shows their phone number and an "I've told
/// them" acknowledgement. A prompt reading "seats changed — re-notify" would
/// promise a send that the destination refuses to offer.

/// Test double for [TourController] that needs no live Supabase / GetX service
/// graph — same shape as the sibling tour-detail tests.
class _FakeTourController extends TourController {
  @override
  // ignore: must_call_super
  void onInit() {
    // Intentionally empty — skip the real network load + realtime wiring.
  }

  @override
  Future<void> ensureTourReadyForSeating(String tourId) async {
    // Intentionally empty — the fixture tour is already "hydrated".
  }
}

Bus _bus() => Bus(
      id: 'b1',
      name: 'Bus 1',
      busType: 'Sleeper',
      layout: BusLayout.generate(busType: BusType.sleeper, totalSeats: 30),
    );

SeatAssignment _seat(String id) =>
    SeatAssignment(busId: 'b1', seatId: id, leg: TripType.roundTrip);

/// A rider holding [seats], last notified about [notifiedSig].
Passenger _rider(
  String id, {
  List<SeatAssignment> seats = const [],
  String? notifiedSig,
}) =>
    Passenger(
      id: id,
      tourId: 't1',
      name: 'Rider $id',
      phone: '+919900000000',
      requestLines: [RequestLine(seatType: SeatType.singleSofa, qty: 1)],
      assignedSeats: seats,
      seatsNotifiedSig: notifiedSig,
      tripType: TripType.roundTrip,
    );

/// The signature a rider seated on DL3 would have been notified with.
String get _dl3Sig => _rider('sig', seats: [_seat('DL3')]).seatSignature;

Tour _tour({
  required TourStatus status,
  required List<Passenger> passengers,
}) =>
    Tour(
      id: 't1',
      title: 'Dwarka Yatra',
      fromCity: 'Surat',
      toCity: 'Dwarka',
      departureDate: DateTime(2026, 9, 1),
      pricePerSeat: 1200,
      status: status,
      handlerId: 'h1',
      buses: [_bus()],
      passengers: passengers,
    );

Widget _harness() => EasyLocalization(
      supportedLocales: const [Locale('en')],
      path: 'assets/translations',
      fallbackLocale: const Locale('en'),
      startLocale: const Locale('en'),
      child: Builder(
        builder: (context) => GetMaterialApp(
          theme: ThemeData(brightness: Brightness.dark),
          localizationsDelegates: context.localizationDelegates,
          supportedLocales: context.supportedLocales,
          locale: context.locale,
          home: const TourDetailScreen(tourId: 't1'),
        ),
      ),
    );

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await EasyLocalization.ensureInitialized();
  });

  tearDown(Get.reset);

  void useSurface(WidgetTester tester) {
    tester.view.physicalSize = const Size(600, 2200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  Future<void> mount(WidgetTester tester, Tour tour) async {
    final ctrl = _FakeTourController();
    Get.put<TourController>(ctrl);
    ctrl.tours.assignAll([tour]);
    // EasyLocalization reads its JSON off the asset bundle with REAL async
    // I/O, which only makes progress inside runAsync.
    await tester.runAsync(() async {
      await tester.pumpWidget(_harness());
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pumpAndSettle();
  }

  /// Resolved through `tr()` rather than spelled as an English literal, so the
  /// finders track the catalogue rather than a snapshot of it.
  Finder text(String key, {Map<String, String>? args}) =>
      find.text(tr(key, namedArgs: args));

  group('a rider whose seat was withdrawn after being notified', () {
    testWidgets('is surfaced by the Overview next-action card', (tester) async {
      useSurface(tester);
      await mount(
        tester,
        _tour(
          status: TourStatus.locked,
          // Told they had DL3, then the seat was taken back entirely.
          passengers: [_rider('p1', seats: const [], notifiedSig: _dl3Sig)],
        ),
      );

      // THE regression. Before the fix the card said "1 seat to place"
      // (`action_assign_title_one`) and nothing anywhere named the rider who
      // is holding a confirmation for a seat that no longer exists.
      expect(
        text('tour_detail.action_seat_removed_title', args: {'n': '1'}),
        findsOneWidget,
        reason: 'the stranded rider must be named, not hidden behind the '
            'unassigned-seat count their withdrawal created',
      );
      // And the prompt must not promise a WhatsApp re-send: no template exists
      // for a withdrawal, so the copy asks for a phone call instead.
      // (`_NextActionCard` renders title + subtitle; the primary ctaLabel is
      // carried on the model but not drawn, so the subtitle is the copy the
      // organiser actually reads.)
      expect(
        text('tour_detail.action_renotify_title'),
        findsNothing,
        reason: 'a withdrawal cannot be re-notified — it is a phone call',
      );
      expect(
        text('tour_detail.action_seat_removed_subtitle'),
        findsOneWidget,
        reason: 'the copy must say why there is no message to send',
      );
    });

    testWidgets('relabels the More tools Lock/Send row as a call, not a resend',
        (tester) async {
      useSurface(tester);
      await mount(
        tester,
        _tour(
          status: TourStatus.locked,
          passengers: [
            // One rider seated and told; one stranded.
            _rider('p1',
                seats: [_seat('DL1')],
                notifiedSig: _rider('x', seats: [_seat('DL1')]).seatSignature),
            _rider('p2', seats: const [], notifiedSig: _dl3Sig),
          ],
        ),
      );

      await tester.tap(find.text(tr('tour_detail.tool_more')).hitTestable());
      await tester.pumpAndSettle();

      final sheet = find.byType(BottomSheet);
      expect(
        find
            .descendant(
                of: sheet,
                matching: find.text(tr('tour_detail.action_seat_removed_cta')))
            .hitTestable(),
        findsOneWidget,
        reason: 'the milestone row must light up for the stranded rider and '
            'name the action Notify will actually offer',
      );
    });

    testWidgets('leaves the ordinary seat-MOVE prompt alone', (tester) async {
      useSurface(tester);
      await mount(
        tester,
        _tour(
          status: TourStatus.locked,
          // Told DL3, moved to DL4 — still seated, still WhatsApp-able.
          passengers: [_rider('p1', seats: [_seat('DL4')], notifiedSig: _dl3Sig)],
        ),
      );

      expect(
        text('tour_detail.action_renotify_title'),
        findsOneWidget,
        reason: 'a seat move has an approved template and keeps its own copy',
      );
      expect(text('tour_detail.action_seat_removed_cta'), findsNothing);
    });
  });

  group('a completed tour', () {
    testWidgets('does not offer Lock / Send in More tools', (tester) async {
      useSurface(tester);
      await mount(
        tester,
        _tour(
          status: TourStatus.completed,
          passengers: [
            _rider('p1',
                seats: [_seat('DL1')],
                notifiedSig: _rider('x', seats: [_seat('DL1')]).seatSignature),
          ],
        ),
      );

      await tester.tap(find.text(tr('tour_detail.tool_more')).hitTestable());
      await tester.pumpAndSettle();

      final sheet = find.byType(BottomSheet);
      // `locked` is false for a completed tour, so this row used to render as
      // a HIGHLIGHTED "Lock" — the next step on a trip that is already over —
      // and pushed a Notify screen that can only answer "Tour is completed".
      for (final key in const [
        'tour_detail.tool_lock',
        'notify.title',
        'tour_detail.action_renotify_cta',
        'tour_detail.action_seat_removed_cta',
      ]) {
        expect(
          find.descendant(of: sheet, matching: find.text(tr(key))),
          findsNothing,
          reason: '"$key" is a dead end once the trip is over',
        );
      }
      // The rest of the group is untouched — this is a hidden row, not a
      // hidden section.
      expect(
        find.descendant(
            of: sheet, matching: find.text(tr('tour_detail.tool_money'))),
        findsOneWidget,
      );
      expect(
        find.descendant(
            of: sheet, matching: find.text(tr('tour_detail.tool_groups'))),
        findsOneWidget,
      );
    });
  });
}
