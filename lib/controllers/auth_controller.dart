import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/admin.dart';
import '../models/profile.dart';
import '../services/admin_auth_service.dart';
import '../services/biometric_credential_store.dart';
import '../services/push_service.dart';
import '../services/tour_cache_store.dart';
import '../utils/app_snackbar.dart';
import 'tour_controller.dart';
import 'user_controller.dart';
import 'customer_memory_controller.dart';

/// Phone+password admin auth backed by Supabase Auth (synthetic-email mapping).
/// Non-admin phones drop straight into a passenger session (no auth) so
/// first-time customers can browse without friction.
class AuthController extends GetxController {
  static const _keyPhone = 'auth_phone';
  static const _keyRole = 'auth_role';
  static const _keyName = 'auth_name';
  static const _keyLastPhone = 'auth_last_phone';
  static const _keyBiometricOffered = 'auth_biometric_offered';

  /// The admin's row id, persisted alongside the session.
  ///
  /// [currentAdmin] is only populated by a NETWORK lookup (`findByPhone`), so on
  /// an offline cold start the app knows it is logged in as an admin but not
  /// WHICH admin — and the offline tour cache is keyed by exactly that id. Kept
  /// in prefs so the cache can be scoped with no network, and cleared with the
  /// rest of the session so it can never scope a cache read for a signed-out
  /// admin.
  static const _keyAdminId = 'auth_admin_id';

  final phoneController = TextEditingController();
  final passwordController = TextEditingController();

  final isLoading = false.obs;
  final phoneNumber = ''.obs;

  final awaitingAdminPassword = false.obs;
  final Rxn<Admin> pendingAdmin = Rxn<Admin>();

  /// Inline error shown on the password field (instead of a toast).
  final RxnString passwordError = RxnString();

  final isLoggedIn = false.obs;
  final userName = ''.obs;
  final userPhone = ''.obs;
  final userRole = UserRole.passenger.obs;
  final Rxn<Profile> currentProfile = Rxn<Profile>();
  final Rxn<Admin> currentAdmin = Rxn<Admin>();

  /// Injectable so tests can supply a throwing/fake service.
  AdminAuthService adminAuth = AdminAuthService();

  /// Injectable so tests can supply a fake biometric store.
  BiometricCredentialStore biometric = BiometricCredentialStore();

  /// Whether the login screen should offer the "Unlock with fingerprint"
  /// affordance for the currently-prefilled phone number.
  final RxBool canBiometricUnlock = false.obs;

  SupabaseClient get _client => Supabase.instance.client;

  bool get isAdmin => userRole.value == UserRole.admin;
  bool get isPassenger => userRole.value == UserRole.passenger;

  /// Completes once [_restoreSession] has finished (success, early-return, or
  /// error). The splash awaits this before deciding admin-home vs customer-home
  /// — previously it raced a hard-coded 500 ms timer against an async
  /// SharedPreferences/Supabase read, so on a slow cold start a logged-in admin
  /// could be routed to the customer home ("the app opens on a random screen").
  final Completer<void> _restored = Completer<void>();
  Future<void> get whenRestored => _restored.future;

  /// Completes as soon as the PREFS half of session restore is done — before
  /// the `findByPhone` network lookup [whenRestored] also waits on.
  ///
  /// The offline cache read needs a scope key and nothing else, and waiting for
  /// a network round-trip (up to 12 s on a dead link) to paint data that is
  /// already on disk defeats the entire point of caching it. Everything this
  /// completing guarantees is local: [isLoggedIn], [userRole] and
  /// [cacheScopeAdminId] are all set before it fires.
  final Completer<void> _prefsRestored = Completer<void>();
  Future<void> get whenPrefsRestored => _prefsRestored.future;

  /// Persisted admin row id, read back from prefs on cold start. Only ever used
  /// to scope the offline tour cache — never to authorize anything, because a
  /// prefs value proves nothing about the live Supabase session.
  String? _restoredAdminId;

  /// The admin id the offline tour cache is keyed by, or null when there is no
  /// admin session (an anonymous / customer viewer is NEVER cached). Prefers
  /// the live [currentAdmin] and falls back to the persisted id so an offline
  /// cold start can still find its own cache.
  String? get cacheScopeAdminId {
    if (userRole.value != UserRole.admin || !isLoggedIn.value) return null;
    final id = currentAdmin.value?.id ?? _restoredAdminId;
    return (id != null && id.isNotEmpty) ? id : null;
  }

  /// The admin id a cache WRITE may be keyed by: the live [currentAdmin] only,
  /// with no prefs fallback.
  ///
  /// The asymmetry with [cacheScopeAdminId] is deliberate, because
  /// `currentAdmin` is ALSO what `TourController._tourFilters` filters the tour
  /// query by. When the admin lookup timed out on a slow link but the lighter
  /// tour fetch still landed, that fetch ran UNFILTERED and came back with every
  /// PUBLIC tour rather than this admin's — and saving that under the admin's
  /// key would overwrite their roster on disk with a stranger's list, then paint
  /// it on the next offline start. A READ may fall back to prefs because the
  /// worst it can do is show the admin their own older graph, already labelled
  /// as saved data. A WRITE cannot, because it destroys the good copy.
  String? get writeCacheScopeAdminId {
    if (userRole.value != UserRole.admin || !isLoggedIn.value) return null;
    final id = currentAdmin.value?.id;
    return (id != null && id.isNotEmpty) ? id : null;
  }

  @override
  void onInit() {
    super.onInit();
    _restore();
  }

  Future<void> _restore() async {
    try {
      await _restoreSession();
    } finally {
      if (!_prefsRestored.isCompleted) _prefsRestored.complete();
      if (!_restored.isCompleted) _restored.complete();
    }
  }

  Future<void> _restoreSession() async {
    final prefs = await SharedPreferences.getInstance();
    final phone = prefs.getString(_keyPhone);
    final roleName = prefs.getString(_keyRole) ?? 'passenger';

    // We only ever restore an ADMIN session. For everyone else — a fresh
    // customer, a logged-out user, or stale prefs — make sure NO Supabase
    // auth session lingers. Otherwise the customer browse runs as the old
    // admin (`authenticated`) and RLS hides every other admin's PUBLIC
    // tours, so the customer sees "no tours". Such a session can survive a
    // failed/offline sign-out, or (on Android) an Auto-Backup restore after
    // an uninstall/reinstall — both reported in the field.
    final isPersistedAdmin = phone != null &&
        phone.isNotEmpty &&
        roleName == UserRole.admin.name;

    if (!isPersistedAdmin) {
      await prefs.remove(_keyPhone);
      await prefs.remove(_keyRole);
      await prefs.remove(_keyName);
      await prefs.remove(_keyAdminId);
      // No admin session to restore ⇒ no cached tour graph may exist. This is
      // the second of the two guards that make "the cache cannot outlive the
      // session" true: [logout] wipes on the way out, and this wipes on the way
      // in for any start that isn't a restored admin — a logout that never
      // reached this code, a prefs clear, an OS-restored install.
      await TourCacheStore.instance.clearAll();
      await _purgeStaleAuthSession();
      return;
    }

    final name = prefs.getString(_keyName) ?? '';

    userPhone.value = phone;
    phoneNumber.value = phone;
    userName.value = name;
    userRole.value = UserRole.values.firstWhere(
      (r) => r.name == roleName,
      orElse: () => UserRole.passenger,
    );
    _restoredAdminId = prefs.getString(_keyAdminId);
    isLoggedIn.value = true;

    // Everything the offline cache read needs is now in place; release it
    // before the network `findByPhone` below, which can take the full 12 s
    // timeout on a dead link.
    if (!_prefsRestored.isCompleted) _prefsRestored.complete();

    if (userRole.value == UserRole.admin && _client.auth.currentSession != null) {
      try {
        final admin = await adminAuth.findByPhone(phone);
        if (admin != null) {
          currentAdmin.value = admin;
          // Re-arm push on cold start for an already-logged-in admin.
          if (admin.pushEnabled) {
            // ignore: unawaited_futures
            PushService.instance.register();
          }
          if (Get.isRegistered<UserController>()) {
            // ignore: unawaited_futures
            Get.find<UserController>().ensureLoadedForCurrentAdmin();
          }
          if (Get.isRegistered<CustomerMemoryController>()) {
            // Same deferral as CustomerMemoryController.onInit — don't race
            // the tour cold-start wave on cellular.
            Future<void>.delayed(const Duration(milliseconds: 2200), () {
              if (!Get.isRegistered<CustomerMemoryController>()) return;
              Get.find<CustomerMemoryController>().load();
            });
          }
          // COLD START: TourController is lazyPut, so it usually is not
          // registered yet — [_reloadToursWhenReady] waits for the home shell
          // to mount it, then re-fetches with the confirmed admin owner scope.
          // (TourController also awaits [whenRestored] before its own first
          // load; this path covers login/role flips and a missed first paint.)
          _reloadTours();
        }
      } catch (_) {
        // Offline or transient — admin will hydrate on next online action.
      }
    }
  }

  /// Best-effort local sign-out so a non-admin device browses as `anon`.
  /// `SignOutScope.local` clears the persisted session without a network
  /// round-trip, so it still works offline.
  Future<void> _purgeStaleAuthSession() async {
    if (_client.auth.currentSession == null) return;
    try {
      await _client.auth.signOut(scope: SignOutScope.local);
    } catch (_) {
      // Best-effort — worst case the next online action re-scopes.
    }
  }

  /// Re-scope the tour list after a role change. Admins see only their own
  /// tours; customers/anon see all public tours. The tour controller is a
  /// fenix singleton whose `onInit` won't re-run on navigation, so an explicit
  /// refresh is required when the role flips (login / logout).
  ///
  /// On cold start [TourController] is still `lazyPut`-unregistered while
  /// session restore finishes — a plain `isRegistered` check was a silent
  /// no-op, so the re-fetch documented above never ran. Wait briefly for the
  /// home shell to mount the controller, then refresh.
  void _reloadTours() {
    // ignore: unawaited_futures
    _reloadToursWhenReady();
  }

  Future<void> _reloadToursWhenReady() async {
    for (var i = 0; i < 40; i++) {
      if (Get.isRegistered<TourController>()) {
        await Get.find<TourController>().refreshTours();
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  Future<void> _persistSession() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyPhone, userPhone.value);
    await prefs.setString(_keyRole, userRole.value.name);
    await prefs.setString(_keyName, userName.value);
    final adminId = currentAdmin.value?.id;
    if (adminId != null && adminId.isNotEmpty) {
      _restoredAdminId = adminId;
      await prefs.setString(_keyAdminId, adminId);
    }
  }

  /// Remembers the phone number across logout so a returning admin doesn't
  /// have to retype it — unlike [_persistSession]'s keys, this one survives
  /// [_clearSessionLocally].
  Future<void> persistLastPhone(String phone) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyLastPhone, phone);
  }

  /// Prep the login screen after a logout / cold anonymous start: prefill the
  /// last-used number so a returning admin only types the password, then
  /// check whether a biometric credential is on file for that number so the
  /// "Unlock with fingerprint" affordance can be shown.
  Future<void> prepareLoginScreen() async {
    final prefs = await SharedPreferences.getInstance();
    final last = prefs.getString(_keyLastPhone);
    if (last != null && last.isNotEmpty && phoneController.text.isEmpty) {
      phoneController.text = last;
      phoneNumber.value = last;
    }

    final phone = phoneController.text;
    if (phone.isNotEmpty && await biometric.isAvailable()) {
      canBiometricUnlock.value = await biometric.hasCredential(phone);
    } else {
      canBiometricUnlock.value = false;
    }
  }

  String get maskedPhone {
    final phone = phoneController.text;
    if (phone.length >= 10) {
      return '+91 ${phone.substring(0, 5)} ${phone.substring(5)}';
    }
    return '+91 $phone';
  }

  String get initials {
    final name = userName.value;
    if (name.isEmpty) return '?';
    final parts = name.trim().split(' ');
    if (parts.length >= 2) {
      return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
    }
    return name[0].toUpperCase();
  }

  /// Step 1 — phone lookup. Falls through to passenger session on no match.
  Future<void> submitPhone() async {
    passwordError.value = null;
    final phone = phoneController.text.trim();
    if (phone.length < 10) {
      AppSnackBar.error(tr('errors.phone_invalid'));
      return;
    }

    isLoading.value = true;
    try {
      final admin = await adminAuth.findByPhone(phone);
      if (admin != null) {
        pendingAdmin.value = admin;
        awaitingAdminPassword.value = true;
        passwordController.clear();
      } else {
        // Admin-only access: a number that isn't in the `admins` table cannot
        // log in. No password-less passenger session is created.
        AppSnackBar.error(
          tr('errors.number_not_registered'),
          title: tr('errors.access_denied'),
        );
      }
    } catch (e) {
      AppSnackBar.error(
        tr('errors.verify_phone', namedArgs: {'e': '$e'}),
        title: tr('errors.connection_error'),
      );
    } finally {
      isLoading.value = false;
    }
  }

  Future<void> sendOtp() => submitPhone();

  /// Step 2 — Supabase Auth sign-in.
  Future<void> verifyAdminPassword() async {
    passwordError.value = null;
    final pending = pendingAdmin.value;
    if (pending == null) {
      awaitingAdminPassword.value = false;
      return;
    }
    final password = passwordController.text;
    if (password.isEmpty) {
      AppSnackBar.error(tr('errors.enter_admin_password'));
      return;
    }

    isLoading.value = true;
    try {
      final admin = await adminAuth.signIn(
        phone: pending.phone,
        password: password,
      );
      await _completeLogin(admin, password: passwordController.text);
    } on AuthException catch (_) {
      // Wrong password (or unknown synthetic email) — surface inline on the
      // field, not as a toast, and never echo the synthetic email.
      passwordError.value = tr('login.password_incorrect');
    } catch (e) {
      AppSnackBar.error(
        tr('errors.sign_in', namedArgs: {'e': '$e'}),
        title: tr('errors.connection_error'),
      );
    } finally {
      isLoading.value = false;
    }
  }

  Future<void> verifyOtp() async {
    if (awaitingAdminPassword.value) {
      await verifyAdminPassword();
    } else {
      Get.offAllNamed('/');
    }
  }

  void cancelAdminPassword() {
    pendingAdmin.value = null;
    awaitingAdminPassword.value = false;
    passwordController.clear();
    passwordError.value = null;
  }

  /// Replays the stored admin credential after a passing biometric prompt.
  Future<void> unlockWithBiometric() async {
    if (isLoading.value) return;
    final phone = phoneController.text.trim();
    if (phone.isEmpty) return;
    final cred = await biometric.unlock(phone);
    if (cred == null) return; // cancelled / failed — stay on the manual path

    isLoading.value = true;
    try {
      final admin = await adminAuth.signIn(
        phone: cred.phone,
        password: cred.password,
      );
      await _completeLogin(admin, password: cred.password);
    } on AuthException catch (_) {
      // Stored password is stale (admin changed it server-side). Drop the
      // credential and fall back to manual entry. The password field isn't
      // necessarily mounted here (awaitingAdminPassword may still be false),
      // so surface this as a snackbar rather than the inline field error.
      await biometric.clear();
      canBiometricUnlock.value = false;
      AppSnackBar.error(tr('login.password_incorrect'));
    } catch (e) {
      AppSnackBar.error(
        tr('errors.sign_in', namedArgs: {'e': '$e'}),
        title: tr('errors.connection_error'),
      );
    } finally {
      isLoading.value = false;
    }
  }

  Future<void> _completeLogin(Admin admin, {required String password}) async {
    isLoggedIn.value = true;
    currentAdmin.value = admin;
    userPhone.value = admin.phone;
    phoneNumber.value = admin.phone;
    userRole.value = UserRole.admin;
    userName.value = admin.name;
    awaitingAdminPassword.value = false;
    pendingAdmin.value = null;
    passwordController.clear();
    await _persistSession();
    await persistLastPhone(admin.phone);
    // Commit the autofill context so the OS offers to save the number+password.
    // Must run while the login screen's AutofillGroup is still mounted, i.e.
    // BEFORE navigating away.
    try {
      TextInput.finishAutofillContext();
    } catch (_) {
      // Headless / test environments have no platform channel for this.
    }
    if (Get.isRegistered<UserController>()) {
      // ignore: unawaited_futures
      Get.find<UserController>().ensureLoadedForCurrentAdmin();
    }
    _reloadTours();
    // Register this device for push if the admin has it enabled. Fire-and-forget
    // (requests OS permission + stores the FCM token); never blocks navigation.
    if (admin.pushEnabled) {
      // ignore: unawaited_futures
      PushService.instance.register();
    }
    await _maybeOfferBiometricEnroll(admin.phone, password);
    Get.offAllNamed('/');
  }

  /// Offers to enroll biometric quick-unlock once, the first time an admin
  /// with no stored credential signs in on a device that supports it. Never
  /// nags again after the first offer, whatever the admin chooses.
  Future<void> _maybeOfferBiometricEnroll(String phone, String password) async {
    if (!await biometric.isAvailable()) return;
    if (await biometric.hasCredential(phone)) return;
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_keyBiometricOffered) ?? false) return;
    await prefs.setBool(_keyBiometricOffered, true);

    final enable = await Get.dialog<bool>(
      // Reuse a lightweight AlertDialog here to avoid a BuildContext
      // dependency — Get.dialog supplies its own overlay.
      AlertDialog(
        title: Text(tr('login.biometric_enroll_title')),
        content: Text(tr('login.biometric_enroll_message')),
        actions: [
          TextButton(
            onPressed: () => Get.back(result: false),
            child: Text(tr('app.action.cancel')),
          ),
          TextButton(
            onPressed: () => Get.back(result: true),
            child: Text(tr('login.biometric_enroll_confirm')),
          ),
        ],
      ),
    );
    if (enable == true) {
      await biometric.enroll(phone: phone, password: password);
    }
  }

  Future<void> updateUserName(String name) async {
    userName.value = name;
    await _persistSession();
  }

  /// Persists edited admin settings (from the Settings sub-screens) to the
  /// `admins` table, then mirrors the result into in-memory state so every
  /// `Obx` that reads `currentAdmin` / `userName` updates immediately.
  /// Throws on failure so the caller can surface an error and keep the
  /// unsaved edits on screen.
  Future<void> saveAdmin(Admin updated) async {
    final saved = await adminAuth.updateAdmin(updated);
    currentAdmin.value = saved;
    userName.value = saved.name;
    await _persistSession();
  }

  Future<void> logout() async {
    // Drop this device's push token BEFORE signing out — the unregister RPC is
    // scoped by auth.uid(), so it needs the live Supabase session.
    await PushService.instance.unregister();
    await adminAuth.signOut();
    await clearSessionLocally();
    Get.offAllNamed('/splash');
  }

  /// Clears the persisted prefs, the offline tour cache, and the in-memory
  /// session state. Used by [logout]; does not touch the Supabase session (the
  /// caller handles sign-out first).
  ///
  /// Public only so a test can exercise the real logout tail: [logout] itself
  /// reaches `PushService.instance`, whose `FirebaseMessaging.instance` field
  /// initializer throws with no Firebase app, so it cannot be driven from a
  /// plain unit test. Production callers use [logout].
  @visibleForTesting
  Future<void> clearSessionLocally() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyPhone);
    await prefs.remove(_keyRole);
    await prefs.remove(_keyName);
    await prefs.remove(_keyAdminId);
    _restoredAdminId = null;

    // IDENTITY DIES BEFORE THE DISK DOES — the order is load-bearing.
    //
    // `TourController` debounces its cache save ~1.2 s and resolves the scope
    // from this controller AFTER an await, so it can fire at any moment —
    // including while the wipe below is inside its recursive directory delete.
    // If the session still yields a scope there, that save queues its write
    // BEHIND the wipe and re-creates the ex-admin's roster on disk moments after
    // it was removed: the exact "stale tours survive logout" defect the previous
    // offline layer was deleted for.
    //
    // Clearing the session state FIRST makes `cacheScopeAdminId` null for
    // anything that resolves during the wipe, so a late save is refused rather
    // than ordered after it.
    isLoggedIn.value = false;
    currentProfile.value = null;
    currentAdmin.value = null;
    userRole.value = UserRole.passenger;
    userName.value = '';
    userPhone.value = '';

    // The offline tour graph dies with the session. Awaited, not
    // fire-and-forget: `_reloadTours` at the foot of this method re-scopes the
    // tour list as an anonymous viewer, and a wipe still in flight then could
    // race a save and leave the ex-admin's roster on disk.
    await TourCacheStore.instance.clearAll();

    phoneController.clear();
    passwordController.clear();
    awaitingAdminPassword.value = false;
    pendingAdmin.value = null;
    passwordError.value = null;
    if (Get.isRegistered<UserController>()) {
      Get.find<UserController>().reset();
    }
    // Back to an anonymous viewer — re-scope the tour list to all public tours.
    _reloadTours();
  }

  @override
  void onClose() {
    phoneController.dispose();
    passwordController.dispose();
    super.onClose();
  }
}
