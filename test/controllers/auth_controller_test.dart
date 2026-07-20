import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:occubusbooking/controllers/auth_controller.dart';
import 'package:occubusbooking/models/admin.dart';
import 'package:occubusbooking/services/admin_auth_service.dart';
import 'package:occubusbooking/services/biometric_credential_store.dart';

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

/// Same factory-constructor caveat as `_ThrowingAuth` above — the brief's
/// version relies on an implicit default super call, which doesn't compile
/// since `AdminAuthService()` is a factory.
class _RecordingAuth extends AdminAuthService {
  _RecordingAuth(this.log) : super.internal();
  final List<String> log;
  @override
  Future<Admin> signIn({required String phone, required String password}) async {
    log.add(phone);
    return Admin(id: 'a1', phone: phone, name: 'Test');
  }
}

class _FakeStore extends BiometricCredentialStore {
  _FakeStore({this.available = true, this.pass = true, this.enrolled});
  bool available;
  bool pass;
  ({String phone, String password})? enrolled;
  @override
  Future<bool> isAvailable() async => available;
  @override
  Future<bool> hasCredential(String phone) async => enrolled != null;
  @override
  Future<void> enroll({required String phone, required String password}) async =>
      enrolled = (phone: phone, password: password);
  @override
  Future<({String phone, String password})?> unlock(String phone) async =>
      pass ? enrolled : null;
  @override
  Future<void> clear() async => enrolled = null;
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

  test('prepareLoginScreen enables biometric when a credential exists', () async {
    SharedPreferences.setMockInitialValues({'auth_last_phone': '9876543210'});
    final ctrl = _TestAuthController()
      ..biometric = _FakeStore(enrolled: (phone: '9876543210', password: 'pw'));
    await ctrl.prepareLoginScreen();
    expect(ctrl.canBiometricUnlock.value, isTrue);
  });

  test('unlockWithBiometric replays signIn on success', () async {
    final store = _FakeStore(enrolled: (phone: '9876543210', password: 'pw'), pass: true);
    final signedIn = <String>[];
    final ctrl = _TestAuthController()
      ..biometric = store
      ..adminAuth = _RecordingAuth(signedIn);
    ctrl.phoneController.text = '9876543210';
    try {
      await ctrl.unlockWithBiometric();
    } catch (_) {
      // _completeLogin's Get.offAllNamed('/') has no router to work with in
      // a pure controller test (no GetMaterialApp) and throws — signIn is
      // recorded before navigation runs, so the assertion below still holds.
    }
    expect(signedIn, contains('9876543210'));
  });

  test('submitPhone clears a stale passwordError', () async {
    final ctrl = _TestAuthController()..adminAuth = _ThrowingAuth();
    ctrl.passwordError.value = 'login.password_incorrect';
    ctrl.phoneController.text = '9876543210';
    try {
      await ctrl.submitPhone();
    } catch (_) {
      // _ThrowingAuth only overrides signIn — findByPhone falls through to
      // the real AdminAuthService, which has no Supabase client in a pure
      // controller test and throws. passwordError.value = null runs at the
      // TOP of submitPhone, before findByPhone, so the assertion below still
      // holds regardless of this downstream failure.
    }
    expect(ctrl.passwordError.value, isNull);
  });
}
