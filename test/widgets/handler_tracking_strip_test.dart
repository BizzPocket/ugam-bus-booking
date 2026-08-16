import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/services/location_tracker_service.dart';
import 'package:occubusbooking/widgets/handler/handler_tracking_strip.dart';

/// The shell-level tracking strip: the line that tells a handler their bus has
/// stopped being visible to the office, from whichever tab they are standing on.
///
/// Its whole value is being SILENT most of the time — a strip that is always
/// there is chrome, and chrome is what stops being read. So the states it hides
/// for matter as much as the ones it speaks up for.
void main() {
  Future<void> pump(
    WidgetTester tester,
    TrackingStatus status, {
    VoidCallback? onFix,
  }) => tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(brightness: Brightness.dark),
      home: Scaffold(
        body: HandlerTrackingStrip(status: status, onFix: onFix ?? () {}),
      ),
    ),
  );

  for (final quiet in const [
    TrackingStatus.idle,
    TrackingStatus.awaitingPermission,
    TrackingStatus.live,
    TrackingStatus.foregroundOnly,
  ]) {
    testWidgets('$quiet says nothing', (tester) async {
      await pump(tester, quiet);
      expect(find.byType(Text), findsNothing);
    });
  }

  testWidgets('denied names the problem and the way out', (tester) async {
    await pump(tester, TrackingStatus.denied);
    expect(find.text(tr('tracking.card_denied_title')), findsOneWidget);
    expect(find.text(tr('tracking.card_denied_cta')), findsOneWidget);
  });

  testWidgets('deniedForever sends the handler to settings', (tester) async {
    await pump(tester, TrackingStatus.deniedForever);
    expect(find.text(tr('tracking.card_settings_cta')), findsOneWidget);
  });

  testWidgets('serviceDisabled asks for the location switch', (tester) async {
    await pump(tester, TrackingStatus.serviceDisabled);
    expect(find.text(tr('tracking.card_service_off_title')), findsOneWidget);
    expect(find.text(tr('tracking.card_service_off_cta')), findsOneWidget);
  });

  testWidgets('windowClosed is stated, not alarmed about', (tester) async {
    await pump(tester, TrackingStatus.windowClosed);
    expect(find.text(tr('tracking.card_window_closed')), findsOneWidget);
    expect(HandlerTrackingStrip.copyFor(TrackingStatus.windowClosed)!.actionable,
        isFalse);
  });

  testWidgets('forbidden leaks no security detail', (tester) async {
    await pump(tester, TrackingStatus.forbidden);
    expect(find.text(tr('tracking.card_unavailable')), findsOneWidget);
    expect(find.textContaining('forbidden'), findsNothing);
    expect(find.textContaining('permission'), findsNothing);
  });

  testWidgets('the whole strip is the tap target', (tester) async {
    var fixed = false;
    await pump(tester, TrackingStatus.forbidden, onFix: () => fixed = true);
    // Tapped on the label, not on a small trailing button: a handler reaching
    // for this is on a moving bus.
    await tester.tap(find.text(tr('tracking.card_unavailable')));
    await tester.pump();
    expect(fixed, isTrue);
  });

  testWidgets('every status renders without throwing', (tester) async {
    for (final s in TrackingStatus.values) {
      await pump(tester, s);
      expect(tester.takeException(), isNull, reason: 'status $s threw');
    }
  });
}
