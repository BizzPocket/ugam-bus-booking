import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/services/location_tracker_service.dart';
import 'package:occubusbooking/widgets/tracking_status_card.dart';

Widget wrap(Widget child) =>
    MaterialApp(home: Scaffold(body: SingleChildScrollView(child: child)));

void main() {
  Future<void> pump(
    WidgetTester tester,
    TrackingStatus s, {
    DateTime? lastUploadAt,
    VoidCallback? onStop,
    VoidCallback? onFix,
  }) async {
    await tester.pumpWidget(
      wrap(
        TrackingStatusCard(
          status: s,
          lastUploadAt: lastUploadAt,
          onStop: onStop ?? () {},
          onFix: onFix ?? () {},
        ),
      ),
    );
  }

  testWidgets('idle renders nothing at all', (tester) async {
    await pump(tester, TrackingStatus.idle);
    expect(find.byType(Text), findsNothing);
  });

  testWidgets('live offers a stop control', (tester) async {
    await pump(tester, TrackingStatus.live, lastUploadAt: DateTime.now());
    expect(find.text(tr('tracking.card_stop')), findsOneWidget);
  });

  testWidgets('live names the sharing state', (tester) async {
    await pump(
      tester,
      TrackingStatus.live,
      lastUploadAt: DateTime.now().subtract(const Duration(minutes: 1)),
    );
    expect(find.textContaining(tr('tracking.card_live')), findsOneWidget);
  });

  testWidgets('denied offers a recovery action, not a stop', (tester) async {
    await pump(tester, TrackingStatus.denied);
    expect(find.text(tr('tracking.card_denied_cta')), findsOneWidget);
    expect(find.text(tr('tracking.card_stop')), findsNothing);
  });

  testWidgets('deniedForever sends the handler to settings', (tester) async {
    await pump(tester, TrackingStatus.deniedForever);
    expect(find.text(tr('tracking.card_settings_cta')), findsOneWidget);
  });

  testWidgets('serviceDisabled asks to turn location on', (tester) async {
    await pump(tester, TrackingStatus.serviceDisabled);
    expect(find.text(tr('tracking.card_service_off_cta')), findsOneWidget);
  });

  testWidgets('foregroundOnly says so plainly', (tester) async {
    await pump(tester, TrackingStatus.foregroundOnly);
    expect(find.text(tr('tracking.card_foreground_only')), findsOneWidget);
  });

  testWidgets('windowClosed reports the trip is over', (tester) async {
    await pump(tester, TrackingStatus.windowClosed);
    expect(find.text(tr('tracking.card_window_closed')), findsOneWidget);
  });

  testWidgets('forbidden leaks no security detail', (tester) async {
    await pump(tester, TrackingStatus.forbidden);
    expect(find.text(tr('tracking.card_unavailable')), findsOneWidget);
    expect(find.textContaining('forbidden'), findsNothing);
    expect(find.textContaining('permission'), findsNothing);
  });

  testWidgets('awaitingPermission shows progress, no actions', (tester) async {
    await pump(tester, TrackingStatus.awaitingPermission);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text(tr('tracking.card_stop')), findsNothing);
  });

  testWidgets('stop fires its callback', (tester) async {
    var stopped = false;
    await pump(
      tester,
      TrackingStatus.live,
      lastUploadAt: DateTime.now(),
      onStop: () => stopped = true,
    );
    await tester.tap(find.text(tr('tracking.card_stop')));
    await tester.pump();
    expect(stopped, isTrue);
  });

  testWidgets('fix fires its callback', (tester) async {
    var fixed = false;
    await pump(tester, TrackingStatus.denied, onFix: () => fixed = true);
    await tester.tap(find.text(tr('tracking.card_denied_cta')));
    await tester.pump();
    expect(fixed, isTrue);
  });

  testWidgets('every status renders without throwing', (tester) async {
    for (final s in TrackingStatus.values) {
      await pump(tester, s, lastUploadAt: DateTime.now());
      expect(tester.takeException(), isNull, reason: 'status $s threw');
    }
  });
}
