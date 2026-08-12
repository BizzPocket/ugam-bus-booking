import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:occubusbooking/controllers/tour_controller.dart';
import 'package:occubusbooking/models/bus_details.dart';
import 'package:occubusbooking/models/bus_type.dart';
import 'package:occubusbooking/models/passenger.dart';
import 'package:occubusbooking/models/request_line.dart';
import 'package:occubusbooking/models/seat_layout.dart';
import 'package:occubusbooking/models/seat_type.dart';
import 'package:occubusbooking/models/tour.dart';
import 'package:occubusbooking/screens/tour_detail_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Regression tests for the Overview "TOOLS" row and the sheet its More tile
/// opens.
///
/// Two reported defects, both on the same row:
///
/// 1. The **More tools sheet nested a second "More tools"**. [_ActionsGrid]
///    kept the expander it needed back when it rendered INLINE on Overview;
///    once it moved into a sheet already titled "More tools", the sheet showed
///    "More tools ▸ More tools" and buried Buses / Groups / Lock behind a
///    second tap — inside the surface opened to reveal exactly those.
///
/// 2. The **Broadcast tile did nothing visible**. It was wired to the
///    clipboard-only `copy` path, so tapping a tile labelled "Broadcast" never
///    opened WhatsApp's broadcast picker the way the Broadcast card's own CTA
///    does.
///
/// A real [EasyLocalization] ancestor is mounted (the header reads
/// `context.locale`), so finders match translated English strings.

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

Bus _bus(String id, String name, {required int seats}) => Bus(
      id: id,
      name: name,
      busType: 'Sleeper',
      layout: BusLayout.generate(busType: BusType.sleeper, totalSeats: seats),
    );

Passenger _passenger(String id) => Passenger(
      id: id,
      tourId: 't1',
      name: 'Rider $id',
      phone: '+910000000000',
      requestLines: [
        RequestLine(seatType: SeatType.doubleSofa, qty: 1),
      ],
    );

/// An open (not locked, no handler) tour with a typed broadcast message, so the
/// broadcast path has real content to put on the clipboard.
Tour _tour() => Tour(
      id: 't1',
      title: 'Dwarka Yatra',
      fromCity: 'Surat',
      toCity: 'Dwarka',
      departureDate: DateTime(2026, 7, 1),
      pricePerSeat: 1200,
      broadcastMessage: 'Dwarka Yatra — seats open!',
      buses: [_bus('b1', 'Bus 1', seats: 30)],
      passengers: [_passenger('p1'), _passenger('p2')],
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

  /// Tall enough that the whole Overview column (header → vitals → tools row)
  /// lays out without scrolling, so the tool tiles are directly tappable.
  void useSurface(WidgetTester tester) {
    tester.view.physicalSize = const Size(600, 2200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  Future<void> mount(WidgetTester tester) async {
    final ctrl = _FakeTourController();
    Get.put<TourController>(ctrl);
    ctrl.tours.assignAll([_tour()]);
    // EasyLocalization reads its JSON off the asset bundle with REAL async
    // I/O, which only makes progress inside runAsync.
    await tester.runAsync(() async {
      await tester.pumpWidget(_harness());
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pumpAndSettle();
  }

  /// The Overview tools row's tile labelled by translation key [key] (exact
  /// match — the card CTAs use longer strings like "Send broadcast on
  /// WhatsApp").
  ///
  /// Resolved through `tr()` rather than spelled as an English literal: these
  /// finders must track the catalogue, not a snapshot of it. The whole English
  /// catalogue was re-cased once already (ALL-CAPS → sentence case, once the
  /// components stopped uppercasing at render), which broke every hardcoded
  /// finder here at the same time.
  Finder toolTile(String key) => find.text(tr(key)).hitTestable();

  group('More tools sheet', () {
    testWidgets('opens flat — every tool is one tap away, no nested expander',
        (tester) async {
      useSurface(tester);
      await mount(tester);

      await tester.tap(toolTile('tour_detail.tool_more'));
      await tester.pumpAndSettle();

      final sheet = find.byType(BottomSheet);
      expect(sheet, findsOneWidget, reason: 'the More tile must open the sheet');

      // THE regression: "More tools" labelled the sheet AND a section inside
      // it. It may appear exactly once — as the sheet's own title.
      expect(
        find.text(tr('tour_detail.more_tools')),
        findsOneWidget,
        reason: 'the sheet must not nest a second "More tools" section',
      );

      // Every tool reachable without a further tap. `.hitTestable()` matters:
      // the old expander kept its collapsed children in the tree behind an
      // IgnorePointer, so a plain find.text would have passed while the rows
      // were untappable.
      for (final key in const [
        'tour_detail.tool_requests',
        'tour_detail.tool_seats',
        'tour_detail.tool_money',
        'tour_detail.tool_buses',
        'tour_detail.tool_groups',
        'tour_detail.tool_lock',
      ]) {
        expect(
          find.descendant(of: sheet, matching: find.text(tr(key))).hitTestable(),
          findsOneWidget,
          reason: '"$key" must be tappable the moment the sheet opens',
        );
      }
    });

    testWidgets('groups the six tools under Actions and Manage eyebrows',
        (tester) async {
      useSurface(tester);
      await mount(tester);

      await tester.tap(toolTile('tour_detail.tool_more'));
      await tester.pumpAndSettle();

      // Sentence case, not caps: the eyebrows render their translated string
      // verbatim, so the catalogue value is the assertion.
      final sheet = find.byType(BottomSheet);
      expect(
          find.descendant(
              of: sheet, matching: find.text(tr('tour_detail.actions_section'))),
          findsOneWidget);
      expect(
          find.descendant(
              of: sheet, matching: find.text(tr('tour_detail.manage'))),
          findsOneWidget);
    });

    testWidgets('scrolls instead of overflowing on a short phone',
        (tester) async {
      // Six always-drawn rows are taller than the sheet's 92%-of-screen cap
      // here, and the shell puts the body in a Flexible — without an internal
      // scroll view the bottom rows would be clipped off, which is the same
      // "you can't reach it" defect the expander had. A RenderFlex overflow
      // fails this test on its own; the scroll proves the rest.
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await mount(tester);

      // The Overview sliver builds all its children eagerly, so the tile is in
      // the tree from the first frame — drag until it is actually TAPPABLE
      // (out from under the sticky header) rather than merely present.
      for (var i = 0;
          i < 12 && toolTile('tour_detail.tool_more').evaluate().isEmpty;
          i++) {
        await tester.drag(find.byType(CustomScrollView), const Offset(0, -160));
        await tester.pumpAndSettle();
      }
      await tester.tap(toolTile('tour_detail.tool_more'));
      await tester.pumpAndSettle();

      final sheet = find.byType(BottomSheet);
      final groups = find.descendant(
          of: sheet, matching: find.text(tr('tour_detail.tool_groups')));
      await tester.scrollUntilVisible(
        groups,
        80,
        scrollable:
            find.descendant(of: sheet, matching: find.byType(Scrollable)).first,
      );
      expect(groups.hitTestable(), findsOneWidget,
          reason: 'the last row must be reachable, not clipped');
    });
  });

  group('Overview Broadcast tile', () {
    /// Records the url_launcher platform calls the tap produces.
    late List<MethodCall> launcherCalls;
    late List<MethodCall> platformCalls;

    setUp(() {
      launcherCalls = [];
      platformCalls = [];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/url_launcher'),
        (call) async {
          launcherCalls.add(call);
          // Report WhatsApp as installed so the send path runs to completion.
          return true;
        },
      );
      // Clipboard.setData + HapticFeedback ride SystemChannels.platform.
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        platformCalls.add(call);
        return null;
      });
    });

    tearDown(() {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/url_launcher'), null);
      messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    });

    testWidgets('opens the WhatsApp broadcast picker, not a silent copy',
        (tester) async {
      useSurface(tester);
      await mount(tester);

      await tester.tap(toolTile('tour_detail.tool_broadcast'));
      await tester.pumpAndSettle();

      // THE regression: the tile ran the clipboard-only `copy` path, so
      // nothing ever launched and the tap read as dead.
      final launched = launcherCalls.where((c) => c.method == 'launch');
      expect(
        launched,
        isNotEmpty,
        reason: 'tapping Broadcast must open WhatsApp, not just copy',
      );
      expect(
        launched.first.arguments['url'] as String,
        contains('whatsapp://send?text='),
        reason: 'it opens WhatsApp\'s own broadcast/group picker',
      );

      // The broadcast message (not the plain announcement) is also copied as
      // the paste-anywhere backup.
      final copies =
          platformCalls.where((c) => c.method == 'Clipboard.setData').toList();
      expect(copies, isNotEmpty, reason: 'the message is copied as a backup');
      expect(
        copies.last.arguments['text'] as String,
        contains('Dwarka Yatra — seats open!'),
        reason: 'the tour\'s typed broadcast message is what goes out',
      );
    });
  });
}
