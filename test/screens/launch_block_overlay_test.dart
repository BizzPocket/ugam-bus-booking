import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:occubusbooking/config/app_info.dart';
import 'package:occubusbooking/screens/launch_block_overlay.dart';
import 'package:occubusbooking/services/remote_flags_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The overlay has exactly two jobs: cover the app when told to, and never
/// cover it otherwise. The third test is the load-bearing one — a route-based
/// gate would fail it, which is the whole reason this lives in
/// GetMaterialApp.builder.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    Get.reset();
    // AppInfo.load() never runs in a widget test, leaving buildNumber ''. The
    // service deliberately fails open on an unreadable identity, so without a
    // real value here no version gate could ever fire — the block tests would
    // pass vacuously.
    AppInfo.buildNumber = '25';
  });
  tearDown(() {
    Get.reset();
    AppInfo.buildNumber = '';
  });

  const homeKey = Key('the-real-app');
  const otherKey = Key('some-other-route');

  RemoteFlagsService register(RemoteFlags flags) {
    final s = RemoteFlagsService();
    s.flags.value = flags;
    return Get.put<RemoteFlagsService>(s, permanent: true);
  }

  Widget host() => GetMaterialApp(
        builder: (context, child) =>
            LaunchBlockOverlay(child: child ?? const SizedBox.shrink()),
        initialRoute: '/',
        getPages: [
          GetPage(name: '/', page: () => const Scaffold(key: homeKey)),
          GetPage(name: '/other', page: () => const Scaffold(key: otherKey)),
        ],
      );

  testWidgets('proceed shows the app untouched', (tester) async {
    register(const RemoteFlags());
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    expect(find.byKey(homeKey), findsOneWidget);
  });

  /// The app stays MOUNTED under the block (so background navigation does not
  /// hit a dead Navigator) but must be unreachable.
  void expectAppSealedOff(WidgetTester tester) {
    final absorber = tester.widget<AbsorbPointer>(
      find.byType(AbsorbPointer).first,
    );
    expect(absorber.absorbing, isTrue,
        reason: 'the app must not accept input while blocked');
  }

  testWidgets('updateRequired covers and seals the app', (tester) async {
    register(const RemoteFlags(minSupportedBuild: 999));
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    expect(find.text('launch_block.update_required_title'), findsOneWidget);
    expectAppSealedOff(tester);
  });

  testWidgets('maintenance covers the app and offers no store button',
      (tester) async {
    register(const RemoteFlags(maintenanceMode: true));
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    expect(find.text('launch_block.maintenance_title'), findsOneWidget);
    expectAppSealedOff(tester);
    // Sending a user to the store during an outage would be a lie — the new
    // build cannot reach the backend either.
    expect(find.text('launch_block.update_action'), findsNothing);
  });

  testWidgets('Get.offAllNamed cannot escape the block', (tester) async {
    // This is exactly how PushService handles a notification tap from a killed
    // state, and how AuthController lands after login. A GetPage-based gate is
    // destroyed by this call; an overlay in builder is not.
    register(const RemoteFlags(minSupportedBuild: 999));
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    Get.offAllNamed('/other');
    await tester.pumpAndSettle();

    // The navigation lands harmlessly underneath — still blocked, still sealed.
    expect(find.text('launch_block.update_required_title'), findsOneWidget);
    expectAppSealedOff(tester);
  });

  testWidgets('background navigation under a block does not throw',
      (tester) async {
    // Replacing the child instead of covering it would unmount the Navigator
    // and make this call fire at a dead route tree.
    register(const RemoteFlags(maintenanceMode: true));
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    expect(() => Get.offAllNamed('/other'), returnsNormally);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('lifting the block reveals the app without a restart',
      (tester) async {
    final s = register(const RemoteFlags(maintenanceMode: true));
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();
    expect(find.text('launch_block.maintenance_title'), findsOneWidget);

    // Maintenance ending must not require the user to relaunch.
    s.flags.value = const RemoteFlags();
    await tester.pumpAndSettle();

    expect(find.text('launch_block.maintenance_title'), findsNothing);
    expect(find.byKey(homeKey), findsOneWidget);
    final absorber = tester.widget<AbsorbPointer>(
      find.byType(AbsorbPointer).first,
    );
    expect(absorber.absorbing, isFalse);
  });

  testWidgets('an unregistered service shows the app, never a block',
      (tester) async {
    // No AppBinding runs in most of this suite. Failing open here is the same
    // rule the service itself follows.
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    expect(find.byKey(homeKey), findsOneWidget);
  });

  testWidgets('the soft nudge overlays the app and can be dismissed',
      (tester) async {
    register(const RemoteFlags(recommendedBuild: 999));
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    // The app stays usable underneath — an optional update must not interrupt
    // an agent mid-booking.
    expect(find.byKey(homeKey), findsOneWidget);
    expect(find.text('launch_block.recommended_title'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.close_rounded));
    await tester.pumpAndSettle();

    expect(find.text('launch_block.recommended_title'), findsNothing);
    expect(find.byKey(homeKey), findsOneWidget);
  });
}
