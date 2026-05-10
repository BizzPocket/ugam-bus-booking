import 'dart:async';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/admin.dart';
import '../models/profile.dart';
import '../services/admin_auth_service.dart';
import '../utils/app_snackbar.dart';
import 'user_controller.dart';

/// Phone+password admin auth backed by the Appwrite `admins` collection.
/// Non-admin phones still drop straight through into a passenger session
/// (no auth) so first-time customers can browse without friction.
class AuthController extends GetxController {
  static const _keyPhone = 'auth_phone';
  static const _keyRole = 'auth_role';
  static const _keyName = 'auth_name';

  final phoneController = TextEditingController();
  final passwordController = TextEditingController();

  final isLoading = false.obs;
  final phoneNumber = ''.obs;

  /// True after a successful phone lookup that matched an admin record —
  /// the login screen swaps to the password field.
  final awaitingAdminPassword = false.obs;
  final Rxn<Admin> pendingAdmin = Rxn<Admin>();

  final isLoggedIn = false.obs;
  final userName = ''.obs;
  final userPhone = ''.obs;
  final userRole = UserRole.passenger.obs;
  final Rxn<Profile> currentProfile = Rxn<Profile>();
  final Rxn<Admin> currentAdmin = Rxn<Admin>();

  AdminAuthService get _adminAuth => AdminAuthService();

  /// Whether the current user is an admin (full dashboard access).
  bool get isAdmin => userRole.value == UserRole.admin;

  /// Whether the current user is a passenger (view-only booking status).
  bool get isPassenger => userRole.value == UserRole.passenger;

  @override
  void onInit() {
    super.onInit();
    _restoreSession();
  }

  Future<void> _restoreSession() async {
    final prefs = await SharedPreferences.getInstance();
    final phone = prefs.getString(_keyPhone);
    if (phone == null || phone.isEmpty) return;

    final roleName = prefs.getString(_keyRole) ?? 'passenger';
    final name = prefs.getString(_keyName) ?? '';

    userPhone.value = phone;
    phoneNumber.value = phone;
    userName.value = name;
    userRole.value = UserRole.values.firstWhere(
      (r) => r.name == roleName,
      orElse: () => UserRole.passenger,
    );
    isLoggedIn.value = true;

    if (userRole.value == UserRole.admin) {
      try {
        final admin = await _adminAuth.findByPhone(phone);
        if (admin != null) {
          currentAdmin.value = admin;
          if (Get.isRegistered<UserController>()) {
            // ignore: unawaited_futures
            Get.find<UserController>().ensureLoadedForCurrentAdmin();
          }
        }
      } catch (_) {
        // Offline or transient — admin id will hydrate on next online login.
      }
    }
  }

  Future<void> _persistSession() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyPhone, userPhone.value);
    await prefs.setString(_keyRole, userRole.value.name);
    await prefs.setString(_keyName, userName.value);
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

  // ── Login flow ───────────────────────────────────────────────

  /// Step 1 — submit phone number. Looks the number up in the admins
  /// collection. If it matches, transitions to the password step. If it
  /// doesn't, logs in immediately as a passenger.
  Future<void> submitPhone() async {
    final phone = phoneController.text.trim();
    if (phone.length < 10) {
      AppSnackBar.error('Please enter a valid 10-digit phone number');
      return;
    }

    isLoading.value = true;
    try {
      final admin = await _adminAuth.findByPhone(phone);
      if (admin != null) {
        pendingAdmin.value = admin;
        awaitingAdminPassword.value = true;
        passwordController.clear();
      } else {
        await _loginAsPassenger(phone);
      }
    } catch (e) {
      AppSnackBar.error(
        'Could not verify the phone number with Appwrite.\n$e',
        title: 'Connection error',
      );
    } finally {
      isLoading.value = false;
    }
  }

  /// Legacy entry point kept so existing buttons still work.
  Future<void> sendOtp() => submitPhone();

  /// Step 2 — verify the admin's password and log them in on success.
  Future<void> verifyAdminPassword() async {
    final admin = pendingAdmin.value;
    if (admin == null) {
      awaitingAdminPassword.value = false;
      return;
    }
    final password = passwordController.text;
    if (password.isEmpty) {
      AppSnackBar.error('Enter your admin password to continue');
      return;
    }

    isLoading.value = true;
    try {
      if (!_adminAuth.verifyPassword(admin, password)) {
        AppSnackBar.error('Incorrect password');
        return;
      }
      await _loginAsAdmin(admin);
    } finally {
      isLoading.value = false;
    }
  }

  /// Legacy entry point — old OTP flow no longer exists in production.
  Future<void> verifyOtp() async {
    if (awaitingAdminPassword.value) {
      await verifyAdminPassword();
    } else {
      Get.offAllNamed('/');
    }
  }

  /// Cancel the password step and return to phone entry.
  void cancelAdminPassword() {
    pendingAdmin.value = null;
    awaitingAdminPassword.value = false;
    passwordController.clear();
  }

  Future<void> _loginAsAdmin(Admin admin) async {
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
    if (Get.isRegistered<UserController>()) {
      // ignore: unawaited_futures
      Get.find<UserController>().ensureLoadedForCurrentAdmin();
    }
    Get.offAllNamed('/');
  }

  Future<void> _loginAsPassenger(String phone) async {
    isLoggedIn.value = true;
    userPhone.value = phone;
    phoneNumber.value = phone;
    userRole.value = UserRole.passenger;
    userName.value = '';
    await _persistSession();
    Get.offAllNamed('/');
  }

  Future<void> updateUserName(String name) async {
    userName.value = name;
    await _persistSession();
  }

  Future<void> logout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyPhone);
    await prefs.remove(_keyRole);
    await prefs.remove(_keyName);

    isLoggedIn.value = false;
    currentProfile.value = null;
    currentAdmin.value = null;
    userRole.value = UserRole.passenger;
    userName.value = '';
    userPhone.value = '';
    phoneController.clear();
    passwordController.clear();
    awaitingAdminPassword.value = false;
    pendingAdmin.value = null;
    if (Get.isRegistered<UserController>()) {
      Get.find<UserController>().reset();
    }
    Get.offAllNamed('/splash');
  }

  @override
  void onClose() {
    phoneController.dispose();
    passwordController.dispose();
    super.onClose();
  }
}
