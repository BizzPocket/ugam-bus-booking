import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:occubusbooking/controllers/auth_controller.dart';
import 'package:occubusbooking/routes/app_routes.dart';
import 'package:occubusbooking/screens/splash_screen.dart';

/// Test double for [AuthController] — skips the real session-restore network
/// hop and reports "restored" instantly, so the splash's route-when-ready
/// wait resolves on the 950ms minimum-hold timer alone. It never flips
/// isLoggedIn/isAdmin, so the splash routes to the customer home.
class _FakeAuth extends AuthController {
  @override
  // ignore: must_call_super
  void onInit() {
    // Intentionally empty: no _restoreSession / Supabase lookup.
  }

  @override
  Future<void> get whenRestored => Future.value();
}

Widget _harness() => GetMaterialApp(
      theme: ThemeData(brightness: Brightness.dark),
      home: const SplashScreen(),
      getPages: [
        // The splash routes here once the wait resolves; a bare page keeps
        // Get.offAllNamed from throwing on an unknown route at cleanup.
        GetPage(name: AppRoutes.customerHome, page: () => const SizedBox()),
      ],
    );

void main() {
  tearDown(Get.reset);

  // EasyLocalization is not initialised in tests, so every tr() renders as its
  // RAW KEY — the wordmark is the literal 'splash.brand_name' and the tagline
  // 'splash.tagline'. We read the Opacity each Text sits under to watch the
  // dawn-bloom stages drive in.
  double opacityOf(WidgetTester tester, String key) {
    final finder = find.ancestor(
      of: find.text(key),
      matching: find.byType(Opacity),
    );
    return tester.widget<Opacity>(finder.first).opacity;
  }

  testWidgets('dawn-bloom entrance stages the wordmark in before the tagline',
      (tester) async {
    Get.put<AuthController>(_FakeAuth());

    await tester.pumpWidget(_harness());
    // t≈0 — the entrance has not begun to reveal the text yet. This is what
    // separates the staged bloom from the old single flat fade: the wordmark
    // and tagline start fully transparent, not at the logo's opacity.
    expect(opacityOf(tester, 'splash.brand_name'), 0.0);
    expect(opacityOf(tester, 'splash.tagline'), 0.0);

    // t=500ms — the wordmark (stage 0.40–0.80 of a 900ms run) is rising, but
    // the tagline (stage 0.62–1.0, i.e. it starts at 558ms) has not begun.
    await tester.pump(const Duration(milliseconds: 500));
    expect(opacityOf(tester, 'splash.brand_name'), greaterThan(0.0));
    expect(opacityOf(tester, 'splash.tagline'), 0.0);

    // t=900ms — the entrance has completed; both are fully opaque. Still
    // before the 950ms route, so the splash is intact and assertable.
    await tester.pump(const Duration(milliseconds: 400));
    expect(opacityOf(tester, 'splash.brand_name'), 1.0);
    expect(opacityOf(tester, 'splash.tagline'), 1.0);

    // Let the minimum-hold timer fire so routing tears the splash down and no
    // timer is left pending at test end.
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();
  });
}
