import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:occubusbooking/controllers/tour_controller.dart';
import 'package:occubusbooking/design/ugam.dart';
import 'package:occubusbooking/models/bus_details.dart';
import 'package:occubusbooking/models/bus_type.dart';
import 'package:occubusbooking/models/passenger.dart';
import 'package:occubusbooking/models/request_line.dart';
import 'package:occubusbooking/models/seat_layout.dart';
import 'package:occubusbooking/models/seat_type.dart';
import 'package:occubusbooking/models/tour.dart';
import 'package:occubusbooking/screens/tour_detail_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Regression tests for the tour detail header.
///
/// The screen used to render THREE different headers for one tour: a 200pt
/// broadcast-photo hero on Overview, a compact header on the work tabs
/// (`forceCompact`), and a generated backdrop when the photo failed to load.
/// Switching tabs therefore changed the screen's identity, moved the title by
/// ~100pt, restyled it (titleL → titleM), and left no back button once a roster
/// had scrolled.
///
/// These tests pin the fix: ONE header, same place, same style, on every tab —
/// with the poster demoted to Overview body content.
///
/// Unlike the sibling screen tests this one mounts a REAL [EasyLocalization]
/// ancestor: the header's duration label reads `context.locale`, which throws a
/// null-check error without the provider. Labels are therefore the translated
/// English strings, not raw keys.
const String _posterUrl = 'https://example.test/broadcasts/poster.jpg';
const String _title = 'Dwarka Yatra';

/// Test double for [TourController] that needs no live Supabase / GetX service
/// graph. Both [onInit] and [ensureTourReadyForSeating] are stubbed so mounting
/// the screen does not kick off `_loadTours`, realtime wiring, or the
/// post-frame hydrate fetch.
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

Passenger _passenger(String id, String tourId) => Passenger(
      id: id,
      tourId: tourId,
      name: 'Rider $id',
      phone: '+910000000000',
      requestLines: [
        RequestLine(seatType: SeatType.doubleSofa, qty: 1),
      ],
    );

/// A tour WITH a broadcast poster — the exact case that used to fork the
/// header. `riders` is large enough that the Travelers roster scrolls.
Tour _tourWithPoster({int riders = 40}) => Tour(
      id: 't1',
      title: _title,
      fromCity: 'Surat',
      toCity: 'Dwarka',
      departureDate: DateTime(2026, 7, 1),
      pricePerSeat: 1200,
      broadcastImageUrl: _posterUrl,
      buses: [_bus('b1', 'Bus 1', seats: 30), _bus('b2', 'Bus 2', seats: 30)],
      passengers: [
        for (var i = 0; i < riders; i++) _passenger('p$i', 't1'),
      ],
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

/// The title as drawn by the identity header, matched on its `titleL` size so
/// it can't be confused with the sticky mini bar's `titleS` copy (which is in
/// the tree at opacity 0 whenever the header is at rest).
Finder _headerTitle() => find.byWidgetPredicate(
      (w) =>
          w is Text &&
          w.data == _title &&
          w.style?.fontSize == UgamText.titleL.fontSize,
    );

/// True for the poster's provider. `cacheWidth` wraps it in a [ResizeImage],
/// so the [NetworkImage] is one level down.
bool _isPoster(ImageProvider provider) => switch (provider) {
      ResizeImage(:final imageProvider) => _isPoster(imageProvider),
      NetworkImage(:final url) => url == _posterUrl,
      _ => false,
    };

/// The broadcast poster, matched by URL so no unrelated [Image] can satisfy it.
Finder _poster() =>
    find.byWidgetPredicate((w) => w is Image && _isPoster(w.image));

/// The tappable copy of a tab pill.
///
/// The strip exists twice once the page is scrolled — in place (off-screen) and
/// inside the sticky bar — so match on hit-testability rather than tree order:
/// exactly one of the two can receive a tap at any moment.
Finder _tab(String label) => find
    .descendant(
      of: find.byType(UgamTabPills),
      matching: find.text(label),
    )
    .hitTestable();

/// The screen's own vertical scroll view. Scoped explicitly because the tab
/// pills contribute a second, horizontal [Scrollable] to the same tree.
Finder _vScroll() => find
    .descendant(
      of: find.byType(CustomScrollView),
      matching: find.byType(Scrollable),
    )
    .first;

Future<void> _switchTab(WidgetTester tester, String label) async {
  await tester.tap(_tab(label));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 250));
}

/// Current offset of the screen's vertical scroll view.
double _scrollOffset(WidgetTester tester) =>
    tester.state<ScrollableState>(_vScroll()).position.pixels;

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    // EasyLocalization.ensureInitialized() persists the saved locale through
    // shared_preferences, whose platform channel has no implementation in a
    // widget test.
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await EasyLocalization.ensureInitialized();
  });

  tearDown(Get.reset);

  /// Wide enough that all five tab pills fit without the strip scrolling, so a
  /// tab tap needs no `ensureVisible` — which would scroll the page under the
  /// sticky bar and swallow the tap.
  void useSurface(WidgetTester tester) {
    tester.view.physicalSize = const Size(600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  Future<void> mount(WidgetTester tester, {int riders = 40}) async {
    final ctrl = _FakeTourController();
    Get.put<TourController>(ctrl);
    ctrl.tours.assignAll([_tourWithPoster(riders: riders)]);
    // EasyLocalization reads its JSON off the asset bundle with REAL async
    // I/O, which only makes progress inside runAsync — without this the
    // provider never finishes loading and the app subtree stays empty.
    await tester.runAsync(() async {
      await tester.pumpWidget(_harness());
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pumpAndSettle();
  }

  testWidgets('header keeps the same position and style across every tab',
      (tester) async {
    useSurface(tester);
    await mount(tester);

    expect(_headerTitle(), findsOneWidget,
        reason: 'Overview must use the one identity header, not a photo hero');
    final overviewDy = tester.getTopLeft(_headerTitle()).dy;

    for (final tab in const ['Passengers', 'Buses', 'Money', 'Activity']) {
      await _switchTab(tester, tab);
      expect(_headerTitle(), findsOneWidget, reason: '$tab lost the header');
      expect(
        tester.getTopLeft(_headerTitle()).dy,
        overviewDy,
        reason: '$tab moved the title — the header must not shift per tab',
      );
    }
  });

  testWidgets('broadcast poster is Overview content, never header chrome',
      (tester) async {
    useSurface(tester);
    await mount(tester);

    expect(_poster(), findsOneWidget);

    // THE regression: the poster used to be painted as a 200pt hero ABOVE the
    // tabs, on this tab only. It must now sit below them, as body content.
    // `.first` is the in-place strip — the sticky copy is the later Stack child.
    final stripBottom =
        tester.getBottomLeft(find.byType(UgamTabPills).first).dy;
    expect(
      tester.getTopLeft(_poster()).dy,
      greaterThan(stripBottom),
      reason: 'the poster must be body content, not header chrome',
    );

    // And it never leaks onto the work tabs.
    await _switchTab(tester, 'Passengers');
    expect(_poster(), findsNothing);
  });

  testWidgets('back and every tab stay reachable at any scroll depth',
      (tester) async {
    useSurface(tester);
    await mount(tester);
    await _switchTab(tester, 'Passengers');

    // Drive the roster well past the header. The list is lazy, so its max
    // scroll extent only grows as it is walked — hence repeated drags.
    for (var i = 0; i < 4; i++) {
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -300));
      await tester.pumpAndSettle();
    }
    // At this depth the viewport has disposed the in-place chrome outright —
    // identity header gone, and only one tab strip left in the tree.
    expect(_headerTitle(), findsNothing);
    expect(find.byType(UgamTabPills), findsOneWidget);

    // The sticky bar has taken over: exactly one back button is tappable...
    expect(find.byIcon(Icons.arrow_back_rounded).hitTestable(), findsOneWidget);
    // ...and all five tabs are still one tap away. Before the fix the roster
    // scrolled its chrome away with nothing to replace it.
    for (final tab in const [
      'Overview',
      'Passengers',
      'Buses',
      'Money',
      'Activity',
    ]) {
      expect(_tab(tab), findsOneWidget, reason: '$tab unreachable while deep');
    }
  });

  testWidgets('switching tabs rewinds the shared scroll view to the top',
      (tester) async {
    useSurface(tester);
    await mount(tester);

    await _switchTab(tester, 'Passengers');
    expect(_scrollOffset(tester), 0);

    await tester.drag(find.byType(CustomScrollView), const Offset(0, -200));
    await tester.pumpAndSettle();
    expect(
      _scrollOffset(tester),
      greaterThan(0),
      reason: 'the roster should have scrolled',
    );

    // One scroll view serves all five tabs, so the offset must not survive a
    // tab switch — otherwise Overview opens scrolled past its own content.
    await _switchTab(tester, 'Overview');
    expect(_scrollOffset(tester), 0);
  });
}
