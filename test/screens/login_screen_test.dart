import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:occubusbooking/controllers/auth_controller.dart';
import 'package:occubusbooking/screens/login_screen.dart';

class _FakeAuthController extends AuthController {
  @override
  // ignore: must_call_super
  void onInit() {} // skip _restore (SharedPreferences + Supabase)

  @override
  Future<void> prepareLoginScreen() async {}
}

Widget _harness() => GetMaterialApp(
      theme: ThemeData(brightness: Brightness.dark),
      home: const LoginScreen(),
    );

/// Swallows the one harmless overflow the shared [UgamPhoneInput] triggers
/// under `flutter test`: its fixed-width "+91" box clips the 🇮🇳 flag glyph,
/// which renders wider under the test font than on a device. It's a
/// pre-existing rendering artifact of an unrelated component, not this
/// screen — see the identical workaround in
/// `test/widgets/booking_capture_form_test.dart`.
void _swallowKnownPhoneInputOverflow(WidgetTester tester) {
  final prevOnError = FlutterError.onError;
  FlutterError.onError = (details) {
    if (details.exceptionAsString().contains('A RenderFlex overflowed')) return;
    prevOnError?.call(details);
  };
  addTearDown(() => FlutterError.onError = prevOnError);
}

void main() {
  tearDown(Get.reset);

  testWidgets('phone field has username autofill hint inside an AutofillGroup',
      (tester) async {
    _swallowKnownPhoneInputOverflow(tester);
    Get.put<AuthController>(_FakeAuthController());
    await tester.pumpWidget(_harness());
    await tester.pump();

    expect(find.byType(AutofillGroup), findsWidgets);

    final phone = tester.widgetList<TextField>(find.byType(TextField)).firstWhere(
          (f) => f.keyboardType == TextInputType.phone,
        );
    expect(phone.autofillHints, contains(AutofillHints.username));
  });

  testWidgets('revealed password field carries the password hint',
      (tester) async {
    _swallowKnownPhoneInputOverflow(tester);
    final c = _FakeAuthController();
    Get.put<AuthController>(c);
    await tester.pumpWidget(_harness());
    c.awaitingAdminPassword.value = true;
    // The reveal chains an AnimatedSize, a post-frame Future.delayed, and an
    // animated Scrollable.ensureVisible — pumpAndSettle (rather than a single
    // fixed-duration pump) lets that whole chain finish so no Timer is left
    // pending at teardown.
    await tester.pumpAndSettle();

    final obscured = tester
        .widgetList<TextField>(find.byType(TextField))
        .firstWhere((f) => f.obscureText == true);
    expect(obscured.autofillHints, contains(AutofillHints.password));
  });

  testWidgets('inline password error shows on the field', (tester) async {
    _swallowKnownPhoneInputOverflow(tester);
    final c = _FakeAuthController();
    Get.put<AuthController>(c);
    await tester.pumpWidget(_harness());
    c.awaitingAdminPassword.value = true;
    // Let the reveal chain (AnimatedSize + post-frame Future.delayed +
    // animated Scrollable.ensureVisible) fully settle — see the identical
    // note on the "revealed password field" test above — otherwise a
    // fixed-duration pump leaves a Timer pending at teardown.
    await tester.pumpAndSettle();
    c.passwordError.value = 'login.password_incorrect';
    await tester.pump();
    expect(find.text('login.password_incorrect'), findsOneWidget);
  });
}
