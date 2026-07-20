import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:occubusbooking/controllers/auth_controller.dart';
import 'package:occubusbooking/services/biometric_credential_store.dart';
import 'package:occubusbooking/screens/settings_screen.dart';

class _FakeStore extends BiometricCredentialStore {
  _FakeStore({this.available = true, this.enrolled = false});
  bool available;
  bool enrolled;
  @override
  Future<bool> isAvailable() async => available;
  @override
  Future<bool> hasCredential(String phone) async => enrolled;
  @override
  Future<void> clear() async => enrolled = false;
}

class _FakeAuth extends AuthController {
  @override
  // ignore: must_call_super
  void onInit() {}
}

void main() {
  tearDown(Get.reset);

  testWidgets('shows enrolled state as on', (tester) async {
    final ctrl = _FakeAuth()..biometric = _FakeStore(enrolled: true);
    ctrl.userPhone.value = '9876543210';
    Get.put<AuthController>(ctrl);
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(brightness: Brightness.dark),
      home: Scaffold(body: BiometricToggle(authCtrl: ctrl)),
    ));
    await tester.pump();
    expect(find.byType(Switch), findsOneWidget);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
  });
}
