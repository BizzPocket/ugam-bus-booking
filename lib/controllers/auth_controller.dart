import 'dart:async';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../config/appwrite_config.dart';
import '../models/profile.dart';
import '../utils/app_snackbar.dart';

/// Local-only auth controller.
/// No backend auth — admin phones are checked against [AppwriteConfig.adminPhones],
/// everyone else is treated as a passenger. Session is persisted to SharedPreferences.
class AuthController extends GetxController {
  static const _keyPhone = 'auth_phone';
  static const _keyRole = 'auth_role';
  static const _keyName = 'auth_name';

  final phoneController = TextEditingController();
  final otpControllers = List.generate(4, (_) => TextEditingController());
  final focusNodes = List.generate(4, (_) => FocusNode());

  final isLoading = false.obs;
  final phoneNumber = ''.obs;
  final isOtpSent = false.obs;
  final resendTimer = 42.obs;
  final isResendEnabled = false.obs;
  final isLoggedIn = false.obs;
  final userName = ''.obs;
  final userPhone = ''.obs;
  final userRole = UserRole.passenger.obs;
  final Rxn<Profile> currentProfile = Rxn<Profile>();

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

  String get otpValue => otpControllers.map((c) => c.text).join();

  String get initials {
    final name = userName.value;
    if (name.isEmpty) return '?';
    final parts = name.trim().split(' ');
    if (parts.length >= 2) {
      return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
    }
    return name[0].toUpperCase();
  }

  void startResendTimer() {
    resendTimer.value = 42;
    isResendEnabled.value = false;
    _countDown();
  }

  void _countDown() async {
    while (resendTimer.value > 0) {
      await Future.delayed(const Duration(seconds: 1));
      resendTimer.value--;
    }
    isResendEnabled.value = true;
  }

  String get timerDisplay {
    final mins = (resendTimer.value ~/ 60).toString().padLeft(2, '0');
    final secs = (resendTimer.value % 60).toString().padLeft(2, '0');
    return '$mins:$secs';
  }

  // ── Login ──────────────────────────────────────────────────

  Future<void> sendOtp() async {
    final phone = phoneController.text.trim();
    if (phone.length < 10) {
      AppSnackBar.error('Please enter a valid 10-digit phone number');
      return;
    }

    // ── Admin flow: no OTP, straight to admin dashboard ────────
    if (AppwriteConfig.isAdminPhone(phone)) {
      await _loginAsAdmin(phone);
      return;
    }

    // ── Passenger flow: no OTP, straight to passenger view ────
    await _loginAsPassenger(phone);
  }

  /// Admin enters without OTP — set phone, role, and go to admin dashboard.
  Future<void> _loginAsAdmin(String phone) async {
    isLoggedIn.value = true;
    userPhone.value = phone;
    phoneNumber.value = phone;
    userRole.value = UserRole.admin;
    userName.value = 'Admin';
    await _persistSession();
    Get.offAllNamed('/');
  }

  /// Passenger enters without OTP — just set phone and go to passenger view.
  Future<void> _loginAsPassenger(String phone) async {
    isLoggedIn.value = true;
    userPhone.value = phone;
    phoneNumber.value = phone;
    userRole.value = UserRole.passenger;
    userName.value = '';
    await _persistSession();
    Get.offAllNamed('/');
  }

  /// Kept for route compatibility. OTP flow is unused in production.
  Future<void> verifyOtp() async {
    Get.offAllNamed('/');
  }

  void resendOtp() {
    if (!isResendEnabled.value) return;
    for (final c in otpControllers) {
      c.clear();
    }
    sendOtp();
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
    userRole.value = UserRole.passenger;
    userName.value = '';
    userPhone.value = '';
    phoneController.clear();
    for (final c in otpControllers) {
      c.clear();
    }
    Get.offAllNamed('/splash');
  }

  @override
  void onClose() {
    phoneController.dispose();
    for (final c in otpControllers) {
      c.dispose();
    }
    for (final f in focusNodes) {
      f.dispose();
    }
    super.onClose();
  }
}
