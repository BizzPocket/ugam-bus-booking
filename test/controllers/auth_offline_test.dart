import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:occubusbooking/controllers/auth_controller.dart';
import 'package:occubusbooking/models/admin.dart';
import 'package:occubusbooking/models/profile.dart';
import 'package:occubusbooking/services/admin_auth_service.dart';
import 'package:occubusbooking/services/sync_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Sync extends SyncService {
  @override
  // ignore: must_call_super
  void onInit() {}
}

/// The admin lookup fails while the phone has no signal, then succeeds.
class _FlakyLookup extends AdminAuthService {
  _FlakyLookup() : super.internal();
  bool online = false;
  int calls = 0;

  @override
  Future<Admin?> findByPhone(String phone) async {
    calls++;
    if (!online) throw const SocketException('no route to host');
    return Admin(id: 'a1', phone: phone, name: 'Zee', pushEnabled: false);
  }
}

class _Ctrl extends AuthController {
  @override
  // ignore: must_call_super
  void onInit() {}
}

void main() {
  setUp(() {
    Get.reset();
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(Get.reset);

  group('logout on a dead link', () {
    final original = AuthController.logoutStepTimeout;
    tearDown(() => AuthController.logoutStepTimeout = original);

    test('a network step that never answers is cut off, not awaited forever',
        () async {
      AuthController.logoutStepTimeout = const Duration(milliseconds: 20);
      final sw = Stopwatch()..start();
      await AuthController.runBoundedLogoutStep(
        () => Completer<void>().future,
      );
      expect(sw.elapsed, lessThan(const Duration(seconds: 2)));
    });

    test('a network step that fails does not abort the local sign-out',
        () async {
      await expectLater(
        AuthController.runBoundedLogoutStep(
          () async => throw const SocketException('offline'),
        ),
        completes,
      );
    });
  });

  test('an offline cold start resolves the admin once signal returns',
      () async {
    final sync = _Sync();
    Get.put<SyncService>(sync);
    final lookup = _FlakyLookup();
    final auth = _Ctrl()
      ..adminAuth = lookup
      ..isLoggedIn.value = true
      ..userRole.value = UserRole.admin
      ..userPhone.value = '9876543210';

    await auth.debugLookupRestoredAdmin('9876543210');
    expect(auth.currentAdmin.value, isNull);

    lookup.online = true;
    sync.isOnline.value = false;
    sync.isOnline.value = true;
    await pumpEventQueue();

    expect(auth.currentAdmin.value?.id, 'a1');
    final calls = lookup.calls;

    // Resolved: later flaps do not keep looking it up.
    sync.isOnline.value = false;
    sync.isOnline.value = true;
    await pumpEventQueue();
    expect(lookup.calls, calls);
  });
}
