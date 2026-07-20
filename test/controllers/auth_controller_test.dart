import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:occubusbooking/controllers/auth_controller.dart';
import 'package:occubusbooking/models/admin.dart';
import 'package:occubusbooking/services/admin_auth_service.dart';

class _ThrowingAuth extends AdminAuthService {
  // AdminAuthService()'s unnamed constructor is a factory (singleton), so a
  // subclass can't rely on the implicit default constructor — it must call
  // the generative `.internal()` constructor explicitly.
  _ThrowingAuth() : super.internal();

  @override
  Future<Admin> signIn({required String phone, required String password}) async {
    throw const AuthException('Invalid login credentials');
  }
}

class _TestAuthController extends AuthController {
  @override
  // ignore: must_call_super
  void onInit() {}
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('wrong password sets inline passwordError, no throw', () async {
    final ctrl = _TestAuthController()..adminAuth = _ThrowingAuth();
    ctrl.pendingAdmin.value =
        Admin(id: 'a1', phone: '9876543210', name: 'Test');
    ctrl.awaitingAdminPassword.value = true;
    ctrl.passwordController.text = 'wrong';

    await ctrl.verifyAdminPassword();

    expect(ctrl.passwordError.value, 'login.password_incorrect');
    expect(ctrl.isLoading.value, isFalse);
  });

  test('cancelAdminPassword clears a stale passwordError', () {
    final ctrl = _TestAuthController();
    ctrl.passwordError.value = 'login.password_incorrect';
    ctrl.awaitingAdminPassword.value = true;
    ctrl.cancelAdminPassword();
    expect(ctrl.passwordError.value, isNull);
  });

  test('prepareLoginScreen prefills last phone', () async {
    SharedPreferences.setMockInitialValues({'auth_last_phone': '9876543210'});
    final ctrl = _TestAuthController();
    await ctrl.prepareLoginScreen();
    expect(ctrl.phoneController.text, '9876543210');
  });
}
